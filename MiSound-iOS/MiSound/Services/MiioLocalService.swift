import Foundation
import Network

/// MiIO 局域网 RPC 服务。
/// 对齐 Android 版 `com.xiaomi.miio.MiioLocalAPI` 的行为：
/// - UDP 54321（单播）
/// - 发送前若无时间戳缓存，先发 hello 包换取 did/stamp/token
/// - 单次请求超时 2s，失败重试 2 次
/// - get_token：用 32 个 'f' 的 FULL_TOKEN 发 hello，即可换取设备真实 token
///
/// 控制方法（method）依设备固件而定；本工程按小米音箱常用命令提供封装，
/// 具体命令表在 `UPnPControlService` 与 `MiioCommandCatalog` 中说明。
enum MiioLocalError: Error {
    case timeout
    case noResponse
    case decryptFailed(String)
    case invalidToken
}

/// 并发安全的布尔标记（替代被并发闭包捕获的 var，避免 Swift 并发检查报错）
private final class FlagBox {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    /// 若未标记则置为已标记并返回 true；已标记则返回 false
    func setTrueIfFalse() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _value { return false }
        _value = true
        return true
    }
}

actor MiioLocalService {

    static let shared = MiioLocalService()

    private let udpPort: UInt16 = 54321
    private let fullToken = "ffffffffffffffffffffffffffffffff"
    private let requestTimeout: TimeInterval = 2.0
    private let retryCount = 2

    /// did -> stamp 缓存（Android 对应 MiioTimestampCache）
    private var stampCache: [String: UInt32] = [:]

    // MARK: - 底层 UDP

    /// 发送数据并等待一条响应（异步）
    private func udpRequest(ip: String, send: Data, timeout: TimeInterval) async throws -> Data {
        let host = NWEndpoint.Host(ip)
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: udpPort)!, using: .udp)
        connection.start(queue: .global())

        let guardQueue = DispatchQueue(label: "miio.udp.guard")

        // 等待 ready（仅 resume 一次）
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var started = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guardQueue.sync { if !started { started = true; cont.resume() } }
                case .failed(let err):
                    guardQueue.sync { if !started { started = true; cont.resume(throwing: err) } }
                case .cancelled:
                    guardQueue.sync { if !started { started = true; cont.resume(throwing: MiioLocalError.noResponse) } }
                default: break
                }
            }
            // 兜底：连接长时间不就绪
            guardQueue.asyncAfter(deadline: .now() + timeout) {
                guardQueue.sync { if !started { started = true; cont.resume(throwing: MiioLocalError.timeout) } }
            }
        }

        let received = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var done = false
            func finish(_ r: Result<Data, Error>) {
                guardQueue.sync {
                    if !done { done = true; cont.resume(with: r) }
                }
            }
            connection.receiveMessage { data, _, _, error in
                if let d = data, !d.isEmpty {
                    finish(.success(d))
                } else if let e = error {
                    finish(.failure(e))
                } else {
                    finish(.failure(MiioLocalError.noResponse))
                }
            }
            connection.send(content: send, completion: .contentProcessed { error in
                if let e = error { finish(.failure(e)) }
            })
            // 超时兜底
            guardQueue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(MiioLocalError.timeout))
            }
        }

        connection.cancel()
        return received
    }

    // MARK: - 握手（hello）与时间戳缓存

    /// 发 hello 换取设备 did/stamp/token
    private func handshake(ip: String, tokenHex: String) async throws -> (did: UInt32, stamp: UInt32, token: String) {
        let hello = try MiioCrypto.craftHello(tokenHex: tokenHex)
        let response = try await udpRequest(ip: ip, send: hello, timeout: requestTimeout)
        // 握手响应报文头含 did/stamp；payload 为设备用真实 token 加密的信息（若返回则解密）
        let header = MiioCrypto.parseHeader(response)
        var token = tokenHex
        var body: String? = nil
        do {
            body = try MiioCrypto.decrypt(packet: response, tokenHex: tokenHex)
        } catch {
            // 部分设备握手响应不携带可解密 payload，忽略
        }
        if let b = body {
            // 形如 {"id":1,"result":...}，若含 token 字段则替换
            if let data = b.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let t = result["token"] as? String {
                token = t
            }
        }
        return (header.did, header.stamp, token)
    }

    /// 获取时间戳（缓存命中则直接使用）
    private func getStamp(ip: String, did: String, token: String) async throws -> UInt32 {
        if let cached = stampCache[did] { return cached }
        let hs = try await handshake(ip: ip, tokenHex: token)
        stampCache[did] = hs.stamp
        return hs.stamp
    }

    // MARK: - RPC

    /// 执行一条 MiIO RPC。
    /// - Parameters:
    ///   - ip: 设备 IP
    ///   - method: 方法名（如 "miIO.info"）
    ///   - params: 参数（JSON 可序列化对象；无参数可传空串 ""）
    ///   - token: 设备 token（32 位 hex）
    ///   - did: 设备 did（可传 0，握手后自动刷新）
    /// - Returns: 响应 JSON 字典
    func rpc(ip: String, method: String, params: Any, token: String, did: UInt32 = 0) async throws -> [String: Any] {
        var did = did
        var tokenHex = token

        // 首次调用时先握手，拿到真实 did 与 token
        if did == 0 {
            let hs = try await handshake(ip: ip, tokenHex: tokenHex)
            did = hs.did
            tokenHex = hs.token
            stampCache[String(did)] = hs.stamp
        }
        let stamp = try await getStamp(ip: ip, did: String(did), token: tokenHex)

        // 构造请求 JSON：{"id":<ts>,"method":"...","params":...}
        let id = UInt32(Date().timeIntervalSince1970)
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        let json = String(data: jsonData, encoding: .utf8) ?? ""

        let packet = try MiioCrypto.encrypt(json: json, did: did, stamp: stamp, tokenHex: tokenHex)

        var lastError: Error = MiioLocalError.noResponse
        for attempt in 0..<retryCount {
            do {
                let response = try await udpRequest(ip: ip, send: packet, timeout: requestTimeout)
                let plain = try MiioCrypto.decrypt(packet: response, tokenHex: tokenHex)
                if let data = plain.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // 更新 stamp
                    let header = MiioCrypto.parseHeader(response)
                    stampCache[String(did)] = header.stamp
                    return obj
                }
                return ["_raw": plain]
            } catch {
                lastError = error
                if attempt == retryCount - 1 { break }
            }
        }
        throw lastError
    }

    /// 获取设备 token（Android：get_token）。用 FULL_TOKEN 发 hello。
    /// - Returns: (did, token, stamp)
    func getToken(ip: String) async throws -> (did: UInt32, token: String, stamp: UInt32) {
        try await handshake(ip: ip, tokenHex: fullToken)
    }

    /// 局域网探测（Android：device_list_detect）。向指定广播地址发 hello，
    /// 收集所有响应设备。响应体即被加密的 did/stamp/token。
    func detectDevices(broadcastIP: String, duration: TimeInterval = 1.5) async throws -> [(ip: String, did: UInt32, token: String)] {
        let host = NWEndpoint.Host(broadcastIP)
        let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: udpPort)!, using: .udp)
        connection.start(queue: .global())

        let hello = try MiioCrypto.craftHello(tokenHex: fullToken)
        var results: [(ip: String, did: UInt32, token: String)] = []

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let done = FlagBox()
            var collected = 0
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: hello, completion: .contentProcessed { _ in
                        // 持续收直到超时
                        func collect() {
                            guard !done.value else { return }
                            connection.receiveMessage { data, context, _, error in
                                if let d = data, !d.isEmpty {
                                    if let endpoint = context?.remoteEndpoint {
                                        do {
                                            let plain = try MiioCrypto.decrypt(packet: d, tokenHex: self.fullToken)
                                            // 响应密文解密后为 {"did":...,"token":...} 或 header 直读
                                            let header = MiioCrypto.parseHeader(d)
                                            if let data = plain.data(using: .utf8),
                                               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                               let t = json["token"] as? String {
                                                results.append((endpoint.debugDescription.replacingOccurrences(of: "\(host):", with: ""),
                                                                header.did, t))
                                            }
                                        } catch {
                                            // 部分设备直接返回 hello（明文 header），token 从头部无法取，跳过
                                        }
                                    }
                                    collected += 1
                                    if collected > 64 { if done.setTrueIfFalse() { cont.resume() }; return }
                                    collect()
                                } else {
                                    if done.setTrueIfFalse() { cont.resume() }
                                }
                            }
                        }
                        collect()
                        DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
                            if done.setTrueIfFalse() { cont.resume() }
                        }
                    })
                }
            }
        }
        connection.cancel()
        return results
    }

    /// 清除时间戳缓存（切网/换设备后调用）
    func resetStampCache() {
        stampCache.removeAll()
    }
}
