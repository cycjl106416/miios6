import Foundation
import Darwin
import Network

/// 设备管理器：编排发现、连接、状态轮询与播放控制。
/// 作为 UI 层的统一入口，通过 NotificationCenter 广播设备/播放状态变化。
/// 整体 @MainActor：所有状态与通知都在主线程操作，
/// 避免后台线程 post 通知导致 UI reloadData/布局在非主线程执行而崩溃
/// （真机崩溃：_AssertAutoLayoutOnAllowedThreadsOnly）。
@MainActor
final class DeviceManager {

    static let shared = DeviceManager()

    // MARK: 通知

    enum NotificationName {
        static let devicesChanged = Notification.Name("MiSound.devicesChanged")
        static let deviceConnected = Notification.Name("MiSound.deviceConnected")
        static let playbackUpdated = Notification.Name("MiSound.playbackUpdated")
        static let deviceConnectFailed = Notification.Name("MiSound.deviceConnectFailed")
    }

    // MARK: 状态

    /// 已发现的设备
    private(set) var devices: [SoundDevice] = []
    /// 当前选中设备
    private(set) var currentDevice: SoundDevice?
    /// 当前播放快照
    private(set) var snapshot = PlaybackSnapshot()

    /// 当前设备的 UPnP controlURL（从 device.xml 解析）
    var currentControlURLs: [String: String] = [:]

    private var pollTimer: Timer?
    private let discovery = DeviceDiscoveryService.shared
    private let upnp = UPnPControlService.shared
    private let miio = MiioLocalService.shared

    /// 是否正在轮询
    private(set) var isPolling = false

    /// 发现防重入锁（discover 可能被设备页 viewDidLoad 与扫描按钮并发触发）
    private let discoverLock = NSLock()
    private var discovering = false
    /// 轮询防堆积：上一次刷新未完成时跳过本轮（设备离线时避免 Task/URLSession 堆积）
    private var isRefreshing = false

    // MARK: 发现

    /// 触发 iOS 本地网络授权弹窗。
    /// 关键事实：iOS 16 上 UDP 组播（SSDP）不一定会触发权限弹窗，
    /// 最可靠的触发方式是向局域网发起单播 TCP/HTTP 请求。
    /// 在 discover 开始时对网关 IP 发一次短超时 GET：未授权时 iOS 弹出
    /// 「允许查找本地网络设备」询问；已授权后该请求正常返回，不影响流程。
    private func primeLocalNetwork() async {
        guard let local = Self.localIPAddress() else { return }
        let parts = local.split(separator: ".")
        guard parts.count == 4 else { return }
        let gw = "\(parts[0]).\(parts[1]).\(parts[2]).1"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2
        let session = URLSession(configuration: config)
        if let url = URL(string: "http://\(gw)/") {
            _ = try? await session.data(from: url)
        }
    }

    /// 综合发现：历史设备 + SSDP（两轮重试）+ 网段扫描
    func discover(scanSubnet: Bool = true) async {
        discoverLock.lock()
        if discovering { discoverLock.unlock(); return }
        discovering = true
        discoverLock.unlock()
        defer {
            discoverLock.lock()
            discovering = false
            discoverLock.unlock()
        }

        // 先触发本地网络授权弹窗（单播 HTTP 是 iOS 最可靠的触发方式）
        await primeLocalNetwork()

        var found = discovery.loadHistory()
        // SSDP 两轮重试：UDP 组播单轮易丢包，合并结果去重
        var seenLoc = Set<String>()
        var ssdpResults: [(location: String, usn: String, ip: String)] = []
        for _ in 0..<2 {
            for r in await discovery.ssdpSearch(duration: 1.5) where seenLoc.insert(r.location).inserted {
                ssdpResults.append(r)
            }
        }

        var ssdpDevices: [SoundDevice] = []
        for r in ssdpResults {
            // LOCATION: http://ip:9999/<uuid>/Upnp/device.xml
            if let info = try? await parseLocation(r.location) {
                ssdpDevices.append(info)
            }
        }

        if scanSubnet, let localIP = Self.localIPAddress() {
            let scanned = await discovery.scanSubnet(localIP: localIP)
            // 扫描仅确认存活，uuid 需通过 SSDP/历史补全；过滤已在 ssdp 中的
            for s in scanned where !ssdpDevices.contains(where: { $0.ip == s.ip }) {
                ssdpDevices.append(s)
            }
        }

        found.append(contentsOf: ssdpDevices.filter { d in
            !found.contains(where: { $0.ip == d.ip })
        })

        devices = found
        discovery.saveHistory(found)
        NotificationCenter.default.post(name: NotificationName.devicesChanged, object: nil)
    }

    /// 解析 LOCATION URL 并拉取设备信息
    private func parseLocation(_ location: String) async -> SoundDevice? {
        guard let url = URL(string: location),
              let host = url.host else { return nil }
        let uuid = url.pathComponents.first(where: { $0 != "/" && !$0.isEmpty }) ?? ""
        guard let (device, controls) = await discovery.fetchDeviceInfo(ip: host, uuid: uuid) else { return nil }
        if currentDevice?.ip == host {
            currentControlURLs = controls
        }
        return device
    }

    // MARK: 连接

    /// 选中设备并开始轮询
    func connect(_ device: SoundDevice) {
        currentDevice = device
        // 若 uuid 缺失，尝试补拉 device.xml
        Task { @MainActor in
            var controls: [String: String] = [:]
            if device.uuid.isEmpty {
                if let (d, c) = await discovery.fetchDeviceInfo(ip: device.ip, uuid: "") {
                    var updated = d
                    updated.miioDid = device.miioDid
                    updated.miioToken = device.miioToken
                    currentDevice = updated
                    controls = c
                }
            } else {
                if let (_, c) = await discovery.fetchDeviceInfo(ip: device.ip, uuid: device.uuid) {
                    controls = c
                }
            }
            currentControlURLs = controls
            // 无法访问设备 HTTP 服务（:9999）：本地网络权限未授予 / 设备不在同一网段 / 设备离线
            if controls.isEmpty {
                stopPolling()
                NotificationCenter.default.post(name: NotificationName.deviceConnectFailed,
                                                object: nil,
                                                userInfo: ["message": "无法连接 \(device.displayName)（\(device.ip)）\n请检查：\n① 设置→隐私与安全性→本地网络 已授权\n② 手机与音箱在同一 Wi-Fi\n③ 音箱已开机在线"])
                return
            }
            // 注册设备功能服务（闹钟/音效/收藏/播放列表）
            if let dev = currentDevice {
                DeviceFeatureService.shared.register(device: dev, controlURLs: currentControlURLs)
            }
            startPolling()
            NotificationCenter.default.post(name: NotificationName.deviceConnected, object: nil)
        }
    }

    // MARK: 轮询

    func startPolling(interval: TimeInterval = 2.0) {
        stopPolling()
        isPolling = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refreshPlayback() }
        }
        pollTimer?.fire()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        isPolling = false
    }

    /// 刷新播放状态（UPnP 优先，失败回退 MiIO）
    @MainActor
    func refreshPlayback() async {
        guard !isRefreshing else { return }   // 上一轮未完成则跳过，防止离线时堆积
        isRefreshing = true
        defer { isRefreshing = false }
        guard let device = currentDevice else { return }
        let avControl = currentControlURLs["urn:schemas-upnp-org:service:AVTransport:1"]
            ?? currentControlURLs.values.first ?? ""

        var newSnapshot = PlaybackSnapshot()

        // 1) 传输状态
        if !avControl.isEmpty, let info = try? await upnp.getTransportInfo(device, controlURL: avControl) {
            if let state = info["TransportState"] {
                newSnapshot.status = PlaybackStatus(rawValue: state.uppercased()) ?? .unknown
            }
        }
        // 2) 位置信息（曲目/进度）
        if !avControl.isEmpty, let pos = try? await upnp.getPositionInfo(device, controlURL: avControl) {
            newSnapshot.track = TrackInfo(title: pos["TrackTitle"],
                                          artist: pos["Artist"],
                                          album: pos["Album"],
                                          uri: pos["TrackURI"])
            newSnapshot.progress = PlaybackProgress(positionSeconds: Self.parseTime(pos["RelTime"]) ?? 0,
                                                   durationSeconds: Self.parseTime(pos["TrackDuration"]) ?? -1)
        }
        // 3) 音量
        let rcControl = currentControlURLs["urn:schemas-upnp-org:service:RenderingControl:1"] ?? ""
        if !rcControl.isEmpty, let vol = try? await upnp.getVolume(device, controlURL: rcControl) {
            newSnapshot.volume = vol
        }

        snapshot = newSnapshot
        NotificationCenter.default.post(name: NotificationName.playbackUpdated, object: nil)
    }

    // MARK: 控制动作

    func play() async {
        guard let device = currentDevice, let ctrl = avControlURL() else { return }
        try? await upnp.play(device, controlURL: ctrl)
    }

    func pause() async {
        guard let device = currentDevice, let ctrl = avControlURL() else { return }
        try? await upnp.pause(device, controlURL: ctrl)
    }

    func togglePlayPause() async {
        if snapshot.status == .playing {
            await pause()
        } else {
            await play()
        }
    }

    func nextTrack() async {
        guard let device = currentDevice, let ctrl = avControlURL() else { return }
        try? await upnp.next(device, controlURL: ctrl)
    }

    func previousTrack() async {
        guard let device = currentDevice, let ctrl = avControlURL() else { return }
        try? await upnp.previous(device, controlURL: ctrl)
    }

    func seek(to seconds: Int) async {
        guard let device = currentDevice, let ctrl = avControlURL() else { return }
        try? await upnp.seek(device, controlURL: ctrl, to: seconds)
    }

    func setVolume(_ value: Int) async {
        guard let device = currentDevice, let ctrl = rcControlURL() else { return }
        try? await upnp.setVolume(device, controlURL: ctrl, volume: value)
        snapshot.volume = max(0, min(100, value))
        NotificationCenter.default.post(name: NotificationName.playbackUpdated, object: nil)
    }

    /// 通过 MiIO RPC 查询设备信息（验证 miio 通道连通性）
    func miioInfo() async -> [String: Any]? {
        guard let device = currentDevice else { return nil }
        let token = device.miioToken ?? "ffffffffffffffffffffffffffffffff"
        return try? await miio.rpc(ip: device.ip, method: "miIO.info", params: "", token: token)
    }

    // MARK: 内部

    /// 当前 AVTransport controlURL（供播放频道等外部调用）
    func avControlURL() -> String? {
        let c = currentControlURLs["urn:schemas-upnp-org:service:AVTransport:1"]
        return c?.isEmpty == false ? c : currentControlURLs.values.first
    }

    private func rcControlURL() -> String? {
        currentControlURLs["urn:schemas-upnp-org:service:RenderingControl:1"]
    }

    /// 解析 UPnP 时间格式 HH:MM:SS（或秒数）
    static func parseTime(_ value: String?) -> Double? {
        guard let v = value, !v.isEmpty else { return nil }
        let parts = v.split(separator: ":")
        if parts.count == 3,
           let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
            return h * 3600 + m * 60 + s
        }
        return Double(v)
    }

    /// 获取本机局域网 IP（用于网段扫描）
    static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            let interface = ptr?.pointee
            let addrFamily = interface?.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: (interface?.ifa_name)!)
                if name == "en0" || name == "en1" || name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface?.ifa_addr, socklen_t((interface?.ifa_addr.pointee.sa_len)!),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    if let ip = String(cString: hostname, encoding: .utf8), !ip.isEmpty, ip != "0.0.0.0" {
                        address = ip
                        break
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return address
    }

    /// 获取默认网关 IP（配网场景：手机连上音箱热点后，网关即音箱 IP）。
    /// 通过 NWPathMonitor 的 path.gateways 读取默认路由网关（iOS 13+ 官方 API），
    /// 与 Android 的 getDhcpInfo().gateway 等价。
    static func gatewayIPAddress() async -> String? {
        let monitor = NWPathMonitor()
        // 一次性标记：保证续体只 resume 一次（class 引用可安全跨 @Sendable 闭包捕获）
        let flag = OneShotFlag()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            monitor.pathUpdateHandler = { path in
                guard flag.fire() else { return }
                let gw = Self.ipString(from: path.gateways.first)
                monitor.cancel()
                cont.resume(returning: gw)
            }
            monitor.start(queue: .global())
            // 兜底：3 秒无网关信息返回 nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                guard flag.fire() else { return }
                monitor.cancel()
                cont.resume(returning: nil)
            }
        }
    }

    /// 从 NWEndpoint 提取 IP 字符串（纯函数，不接触任何隔离状态，供非隔离回调使用）
    private nonisolated static func ipString(from endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _)? = endpoint else { return nil }
        switch host {
        case .ipv4(let addr): return "\(addr)"
        case .ipv6(let addr): return "\(addr)"
        default: return nil
        }
    }
}

/// 一次性标记（线程安全）：用于并发回调中保证只执行一次
private final class OneShotFlag {
    private let lock = NSLock()
    private var fired = false
    /// 若未触发则置为已触发并返回 true；已触发返回 false
    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
