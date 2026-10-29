import Foundation
import Network

/// 设备发现服务。
/// 对齐 Android 版 `com.mi.umi.controlpoint.utils.DeviceDiscoveryHelper`：
/// 1. 历史设备：本地数据库（iOS 以 UserDefaults 持久化）
/// 2. SSDP M-SEARCH 组播 239.255.255.250:1900 搜索 `urn:schemas-upnp-org:device:UmiSystem:1`
/// 3. 网段逐 IP 扫描 `http://<ip>:9999/`（C 段 1...255，2s 超时）
/// 4. 拉取 `http://<ip>:9999/<uuid>/Upnp/device.xml` 解析设备信息
enum DiscoveryError: Error {
    case timeout
    case invalidResponse
}

final class DeviceDiscoveryService: NSObject, XMLParserDelegate {

    static let shared = DeviceDiscoveryService()

    /// 设备 XML 根：http://<ip>:9999/<uuid>/Upnp/device.xml
    private let deviceHTTPPort = 9999

    /// SSDP 组播地址与端口（抄自 Android 反编译）
    private static let ssdpAddress = "239.255.255.250"
    private static let ssdpPort: UInt16 = 1900
    private static let searchTarget = "urn:schemas-upnp-org:device:UmiSystem:1"

    // MARK: - SSDP M-SEARCH

    /// 发起 SSDP M-SEARCH 并收集响应（duration 秒内）。
    /// 采用 BSD socket 直接收发 UDP 组播：Network.framework 的 NWConnectionGroup
    /// 在 iOS SDK 没有 receiveMessage API，且拿不到对端 IP，故用 POSIX 实现
    /// （join 组播组 → bind 1900 → 重发 M-SEARCH → recvfrom 收集，附带来源 IP）。
    /// - Returns: [(locationURL, usn, ip)]
    func ssdpSearch(duration: TimeInterval = 2.0) async -> [(location: String, usn: String, ip: String)] {
        await withCheckedContinuation { (cont: CheckedContinuation<[(location: String, usn: String, ip: String)], Never>) in
            DispatchQueue.global().async {
                cont.resume(returning: Self.ssdpSearchSync(duration: duration))
            }
        }
    }

    private static func ssdpSearchSync(duration: TimeInterval) -> [(location: String, usn: String, ip: String)] {
        var results: [(location: String, usn: String, ip: String)] = []
        var seen = Set<String>()

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))

        // 加入组播组 239.255.255.250
        var mreq = ip_mreq()
        mreq.imr_multiaddr.s_addr = ssdpAddress.withCString { inet_addr($0) }
        mreq.imr_interface.s_addr = INADDR_ANY
        setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

        // 接收超时 200ms（recvfrom 超时返回 -1，避免阻塞卡死）
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // bind 1900 端口
        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = ssdpPort.bigEndian
        bindAddr.sin_addr.s_addr = INADDR_ANY
        let bindOK = withUnsafePointer(to: &bindAddr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                bind(fd, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { return [] }

        // M-SEARCH 报文（原文抄自 Android 反编译 b/b/b.java）
        let search = "M-SEARCH * HTTP/1.1\r\nST: urn:schemas-upnp-org:device:UmiSystem:1\r\nMX: 1\r\nMAN: \"ssdp:discover\"\r\nHOST: 239.255.255.250:1900\r\n\r\n"
        let sendData = Array(search.utf8)
        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = ssdpPort.bigEndian
        dst.sin_addr.s_addr = ssdpAddress.withCString { inet_addr($0) }

        func sendSearch() {
            _ = sendData.withUnsafeBufferPointer { buf -> Int in
                withUnsafePointer(to: &dst) { dp -> Int in
                    dp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int in
                        // sendto 返回 ssize_t（Int）
                        sendto(fd, buf.baseAddress, sendData.count, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        // 发送阶段：连发 3 次，间隔 300ms（提高命中率）
        sendSearch()
        Thread.sleep(forTimeInterval: 0.3)
        sendSearch()
        Thread.sleep(forTimeInterval: 0.3)
        sendSearch()

        // 接收阶段：duration 秒内持续收包并解析
        var recvBuf = [UInt8](repeating: 0, count: 65536)
        let receiveDeadline = Date().addingTimeInterval(duration)
        while Date() < receiveDeadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = recvBuf.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &from) { fp -> Int in
                    fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp -> Int in
                        recvfrom(fd, raw.baseAddress, recvBuf.count, 0, sp, &fromLen)
                    }
                }
            }
            if n <= 0 { continue }   // 超时/无数据
            guard let text = String(bytes: recvBuf[0..<n], encoding: .utf8) else { continue }
            let ip = Self.ipString(from: from)
            let parsed = Self.parseSSDPResponse(text, ip: ip)
            for item in parsed where seen.insert(item.location).inserted {
                results.append(item)
            }
        }
        return results
    }

    /// 从 sockaddr_in 提取点分十进制 IP（网络序转主机序）
    private static func ipString(from addr: sockaddr_in) -> String {
        let a = addr.sin_addr.s_addr.bigEndian
        return "\(a >> 24).\((a >> 16) & 0xFF).\((a >> 8) & 0xFF).\(a & 0xFF)"
    }

    /// 解析 SSDP 响应文本，提取 LOCATION / USN / 来源 IP
    private static func parseSSDPResponse(_ text: String, ip: String) -> [(location: String, usn: String, ip: String)] {
        var location = ""
        var usn = ""
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                location = line.dropFirst("location:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if lower.hasPrefix("usn:") {
                usn = line.dropFirst("usn:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !location.isEmpty else { return [] }
        return [(location, usn, ip)]
    }

    // MARK: - 网段扫描

    /// 扫描本地网段的 9999 端口（C 段 1...255），返回在线设备基础信息
    /// - Parameters:
    ///   - localIP: 本机 IP（如 192.168.1.5），用于推导网段
    func scanSubnet(localIP: String, timeout: TimeInterval = 1.0) async -> [SoundDevice] {
        let parts = localIP.split(separator: ".")
        guard parts.count == 4, let third = Int(parts[2]) else { return [] }
        var devices: [SoundDevice] = []
        // 并行扫描（限制并发 32）
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 32
        let lock = NSLock()
        let semaphore = DispatchSemaphore(value: 0)
        var pending = 0

        for i in 1...255 {
            let ip = "\(parts[0]).\(parts[1]).\(third).\(i)"
            pending += 1
            queue.addOperation {
                Task {
                    let alive = await self.probeDevice(ip: ip, timeout: timeout)
                    if let d = alive {
                        lock.lock(); devices.append(d); lock.unlock()
                    }
                    semaphore.signal()
                }
            }
        }
        // 等待全部完成（或超时 20s）
        for _ in 0..<pending {
            _ = semaphore.wait(timeout: .now() + 30)
        }
        return devices
    }

    /// 探测单台设备：GET http://ip:9999/<uuid>/Upnp/device.xml（2s 超时）
    func probeDevice(ip: String, timeout: TimeInterval = 2.0) async -> SoundDevice? {
        // 先探测根路径是否存活
        guard let root = URL(string: "http://\(ip):\(deviceHTTPPort)/") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        guard let (_, rootResp) = try? await session.data(from: root),
              let http = rootResp as? HTTPURLResponse, http.statusCode == 200 else { return nil }

        // 尝试常见 UUID 路径：设备 discover 时通过 LOCATION 给出；此处退化为常见路径
        // （Android 实际通过 SSDP/数据库拿 uuid，此处先扫描根，再由调用方补全 uuid）
        return SoundDevice(uuid: "", locationUrl: "", ip: ip, model: "",
                           firmwareVersion: "", type: "", capability: 0,
                           ssid: nil, isConnected: true, miioDid: nil, miioToken: nil)
    }

    // MARK: - device.xml 解析

    private var currentElement = ""
    private var currentText = ""
    private var parsedDevice: (udn: String, friendlyName: String, model: String, firmware: String, type: String) = ("", "", "", "", "")
    private var controlURLs: [String: String] = [:]   // serviceType -> controlURL

    /// 拉取并解析 device.xml
    func fetchDeviceInfo(ip: String, uuid: String, timeout: TimeInterval = 2.0) async -> (device: SoundDevice, controlURLs: [String: String])? {
        let urlString = "http://\(ip):\(deviceHTTPPort)/\(uuid)/Upnp/device.xml"
        guard let url = URL(string: urlString) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)
        guard let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        parsedDevice = ("", "", "", "", "")
        controlURLs = [:]
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        let device = SoundDevice(uuid: parsedDevice.udn,
                                 locationUrl: urlString,
                                 ip: ip,
                                 model: parsedDevice.model,
                                 firmwareVersion: parsedDevice.firmware,
                                 type: parsedDevice.type,
                                 capability: 0,
                                 ssid: nil,
                                 isConnected: true,
                                 friendlyName: parsedDevice.friendlyName)
        return (device, controlURLs)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "UDN": parsedDevice.udn = value.replacingOccurrences(of: "uuid:", with: "")
        case "friendlyName": parsedDevice.friendlyName = value
        case "modelName": parsedDevice.model = value
        case "firmwareVersion": parsedDevice.firmware = value
        case "deviceType":
            if parsedDevice.type.isEmpty { parsedDevice.type = value }
        case "controlURL":
            // 记录当前 service 的 controlURL（需与 serviceType 配对；简化实现：先记录最近 serviceType）
            controlURLs["_last"] = value
        case "serviceType":
            if let last = controlURLs["_last"] {
                controlURLs[value] = last
            }
        default: break
        }
    }

    // MARK: - 历史设备持久化

    private let historyKey = "MiSound.historyDevices"

    func saveHistory(_ devices: [SoundDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    func loadHistory() -> [SoundDevice] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let devices = try? JSONDecoder().decode([SoundDevice].self, from: data) else { return [] }
        return devices
    }
}
