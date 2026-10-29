import Foundation

/// UPnP SOAP 控制服务。
/// 对应 Android 版音箱控制的 ohNet UPnP 栈（libohNet.so / libohNetJni.so）。
/// 控制动作通过 HTTP POST 到 device.xml 中 serviceList 声明的 controlURL，
/// 服务类型为标准 UPnP AVTransport / RenderingControl（小米音箱的 UmiSystem 设备
/// 在此基础上实现播放/音量控制）。若设备固件使用自定义 action 名，可在
/// `UPnPControlService.customActions` 中配置映射。
enum UPnPError: Error {
    case invalidURL
    case httpError(Int)
    case noResponse
}

final class UPnPControlService {

    static let shared = UPnPControlService()

    /// 服务类型：标准 UPnP 服务 + 设备自定义服务
    enum ServiceType {
        case avTransport
        case renderingControl
        case custom(String)

        var rawValue: String {
            switch self {
            case .avTransport: return "urn:schemas-upnp-org:service:AVTransport:1"
            case .renderingControl: return "urn:schemas-upnp-org:service:RenderingControl:1"
            case .custom(let urn): return urn
            }
        }
    }

    /// 播放命令（OpenHome 小米实现常见动作；可配置）
    enum Command: String {
        case play = "Play"
        case pause = "Pause"
        case stop = "Stop"
        case next = "Next"
        case previous = "Previous"
        case seek = "Seek"
        case setVolume = "SetVolume"
        case getVolume = "GetVolume"
        case setMute = "SetMute"
        case getMute = "GetMute"
        case getTransportInfo = "GetTransportInfo"
        case getPositionInfo = "GetPositionInfo"
        case getMediaInfo = "GetMediaInfo"
    }

    /// 自定义 action 名映射（如设备固件使用不同动作名，在此覆盖）
    var customActions: [Command: String] = [:]

    private let deviceHTTPPort = 9999

    /// 发送一条 SOAP 动作
    /// - Parameters:
    ///   - device: 目标设备
    ///   - controlURL: device.xml 中解析到的 controlURL（相对路径，如 /control/AVTransport）
    ///   - serviceType: 服务类型 URN
    ///   - action: 动作名（如 "Play"）
    ///   - arguments: 参数键值（XML 转义已处理）
    /// - Returns: 响应 XML 中所有元素的键值字典
    func sendAction(device: SoundDevice,
                    controlURL: String,
                    serviceType: ServiceType,
                    action: String,
                    arguments: [String: String] = [:],
                    timeout: TimeInterval = 4.0) async throws -> [String: String] {
        guard !device.ip.isEmpty else { throw UPnPError.invalidURL }

        let urlString: String
        if controlURL.hasPrefix("http://") {
            urlString = controlURL
        } else if controlURL.hasPrefix("/") {
            urlString = "http://\(device.ip):\(deviceHTTPPort)\(controlURL)"
        } else {
            urlString = "http://\(device.ip):\(deviceHTTPPort)/\(controlURL)"
        }
        guard let url = URL(string: urlString) else { throw UPnPError.invalidURL }

        var body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(serviceType.rawValue)">
        """
        for (key, value) in arguments {
            body += "      <\(key)>\(Self.escapeXML(value))</\(key)>\n"
        }
        body += """
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType.rawValue)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.setValue("3600", forHTTPHeaderField: "Content-Length")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = timeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UPnPError.noResponse }
        // UPnP 成功常见 200；部分设备返回 500 但带有效 Body（Fault 解析见下）
        let text = String(data: data, encoding: .utf8) ?? ""
        let parsed = Self.parseSOAPResponse(text)
        if http.statusCode >= 400 {
            // 尝试解析 UPnPError 的 errorCode
            if let fault = Self.parseFaultCode(text) {
                throw UPnPError.httpError(fault)
            }
            throw UPnPError.httpError(http.statusCode)
        }
        return parsed
    }

    // MARK: - 便捷封装（AVTransport）

    func play(_ device: SoundDevice, controlURL: String) async throws {
        _ = try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                                 action: actionName(.play, device: device),
                                 arguments: ["InstanceID": "0", "Speed": "1"])
    }

    func pause(_ device: SoundDevice, controlURL: String) async throws {
        _ = try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                                 action: actionName(.pause, device: device),
                                 arguments: ["InstanceID": "0"])
    }

    func stop(_ device: SoundDevice, controlURL: String) async throws {
        _ = try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                                 action: actionName(.stop, device: device),
                                 arguments: ["InstanceID": "0"])
    }

    func next(_ device: SoundDevice, controlURL: String) async throws {
        _ = try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                                 action: actionName(.next, device: device),
                                 arguments: ["InstanceID": "0"])
    }

    func previous(_ device: SoundDevice, controlURL: String) async throws {
        _ = try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                                 action: actionName(.previous, device: device),
                                 arguments: ["InstanceID": "0"])
    }

    /// Seek：Target 格式 "HH:MM:SS"
    func seek(_ device: SoundDevice, controlURL: String, to seconds: Int) async throws {
        let target = Self.timeString(seconds)
        _ = try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                                 action: actionName(.seek, device: device),
                                 arguments: ["InstanceID": "0", "Unit": "REL_TIME", "Target": target])
    }

    /// 播放指定 URI（SetAVTransportURI）
    func setURI(_ device: SoundDevice, controlURL: String, uri: String, metaData: String = "") async throws {
        _ = try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                                 action: "SetAVTransportURI",
                                 arguments: ["InstanceID": "0", "CurrentURI": uri, "CurrentURIMetaData": metaData])
    }

    func getTransportInfo(_ device: SoundDevice, controlURL: String) async throws -> [String: String] {
        try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                             action: actionName(.getTransportInfo, device: device),
                             arguments: ["InstanceID": "0"])
    }

    func getPositionInfo(_ device: SoundDevice, controlURL: String) async throws -> [String: String] {
        try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                             action: actionName(.getPositionInfo, device: device),
                             arguments: ["InstanceID": "0"])
    }

    func getMediaInfo(_ device: SoundDevice, controlURL: String) async throws -> [String: String] {
        try await sendAction(device: device, controlURL: controlURL, serviceType: .avTransport,
                             action: actionName(.getMediaInfo, device: device),
                             arguments: ["InstanceID": "0"])
    }

    // MARK: - 便捷封装（RenderingControl）

    func setVolume(_ device: SoundDevice, controlURL: String, volume: Int) async throws {
        _ = try await sendAction(device: device, controlURL: controlURL, serviceType: .renderingControl,
                                 action: actionName(.setVolume, device: device),
                                 arguments: ["InstanceID": "0", "Channel": "Master", "DesiredVolume": "\(max(0, min(100, volume)))"])
    }

    func getVolume(_ device: SoundDevice, controlURL: String) async throws -> Int {
        let res = try await sendAction(device: device, controlURL: controlURL, serviceType: .renderingControl,
                                       action: actionName(.getVolume, device: device),
                                       arguments: ["InstanceID": "0", "Channel": "Master"])
        if let v = res.values.first(where: { Int($0) != nil }), let i = Int(v) { return i }
        return 50
    }

    func setMute(_ device: SoundDevice, controlURL: String, muted: Bool) async throws {
        _ = try await sendAction(device: device, controlURL: controlURL, serviceType: .renderingControl,
                                 action: actionName(.setMute, device: device),
                                 arguments: ["InstanceID": "0", "Channel": "Master", "DesiredMute": muted ? "1" : "0"])
    }

    func getMute(_ device: SoundDevice, controlURL: String) async throws -> Bool {
        let res = try await sendAction(device: device, controlURL: controlURL, serviceType: .renderingControl,
                                       action: actionName(.getMute, device: device),
                                       arguments: ["InstanceID": "0", "Channel": "Master"])
        return res.values.contains { $0 == "1" || $0.lowercased() == "true" }
    }

    // MARK: - 内部工具

    private func actionName(_ command: Command, device: SoundDevice) -> String {
        customActions[command] ?? command.rawValue
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func timeString(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 解析 SOAP 响应：提取 Body 内所有非结构元素的文本值
    private static func parseSOAPResponse(_ xml: String) -> [String: String] {
        // 简单正则提取 <Tag>value</Tag>
        var result: [String: String] = [:]
        let pattern = "<([A-Za-z_][A-Za-z0-9_]*)>([^<]+)</\\1>"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = xml as NSString
            regex.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let m {
                    let tag = ns.substring(with: m.range(at: 1))
                    let value = ns.substring(with: m.range(at: 2))
                    result[tag] = value
                }
            }
        }
        return result
    }

    /// 尝试解析 UPnP Fault 的 errorCode
    private static func parseFaultCode(_ xml: String) -> Int? {
        guard let range = xml.range(of: "<errorCode>"),
              let end = xml.range(of: "</errorCode>", range: range.lowerBound..<xml.endIndex) else { return nil }
        let value = String(xml[range.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(value)
    }
}
