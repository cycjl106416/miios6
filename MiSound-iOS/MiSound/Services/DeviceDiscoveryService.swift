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
    private let ssdpAddress = "239.255.255.250"
    private let ssdpPort: UInt16 = 1900
    private let searchTarget = "urn:schemas-upnp-org:device:UmiSystem:1"

    // MARK: - SSDP M-SEARCH

    /// 发起 SSDP M-SEARCH 并收集响应（duration 秒内）
    /// - Returns: [(locationURL, usn, ip)]
    func ssdpSearch(duration: TimeInterval = 2.0) async -> [(location: String, usn: String, ip: String)] {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ssdpAddress),
                                           port: NWEndpoint.Port(rawValue: ssdpPort)!)
        let group = try? NWMulticastGroup(for: [endpoint])
        guard let group, let multicast = NWConnectionGroup(with: group, using: .udp) else { return [] }

        // M-SEARCH 报文（原文抄自 Android 反编译 b/b/b.java）
        let search = """
        M-SEARCH * HTTP/1.1\r
        ST: \(searchTarget)\r
        MX: 1\r
        MAN: "ssdp:discover"\r
        HOST: \(ssdpAddress):\(ssdpPort)\r
        \r
        """
        var results: [(location: String, usn: String, ip: String)] = []

        multicast.stateUpdateHandler = { _ in }
        multicast.start(queue: DispatchQueue.global())
        // 接收响应
        var stop = false
        multicast.receiveMessage { content, context, _, _ in
            guard !stop, let data = content, let text = String(data: data, encoding: .utf8) else { return }
            let parsed = Self.parseSSDPResponse(text, remote: context?.remoteEndpoint)
            if !parsed.isEmpty {
                results.append(contentsOf: parsed)
            }
            if !stop {
                multicast.receiveMessage { content, context, _, _ in
                    guard !stop, let data = content, let text = String(data: data, encoding: .utf8) else { return }
                    results.append(contentsOf: Self.parseSSDPResponse(text, remote: context?.remoteEndpoint))
                }
            }
        }
        // 发送 M-SEARCH（对 UDP 组播反复发送几次，提高命中率）
        for _ in 0..<3 {
            let completion: NWConnectionGroup.SendCompletion = .contentProcessed { _ in }
            multicast.send(content: search.data(using: .utf8), completion: completion)
            Thread.sleep(forTimeInterval: 0.4)
        }
        Thread.sleep(forTimeInterval: duration)
        stop = true
        multicast.cancel()
        // 去重
        var seen = Set<String>()
        return results.filter { seen.insert($0.location).inserted }
    }

    /// 解析 SSDP 响应文本，提取 LOCATION / USN / 来源 IP
    private static func parseSSDPResponse(_ text: String, remote: NWEndpoint?) -> [(location: String, usn: String, ip: String)] {
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
        let ip = Self.extractIP(from: remote) ?? ""
        return [(location, usn, ip)]
    }

    private static func extractIP(from endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        if case .ipv4(let addr) = host { return "\(addr)" }
        return host.debugDescription
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
