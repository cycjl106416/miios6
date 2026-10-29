import Foundation

/// 设备功能服务：闹钟 / 音效 / 收藏 / 播放列表管理。
/// 这些功能由音箱固件的自定义 UPnP 服务提供（Java 层经 ohNet JNI 动态调用，
/// 动作名在反编译中不可见）。本服务按小米音箱常见动作名实现，并通过
/// `actionOverrides` 提供校准入口——真机抓包后把实际动作名填进来即可用。
final class DeviceFeatureService {

    static let shared = DeviceFeatureService()

    /// 动作名校准表（服务类型 -> 动作名 -> 实际动作名）
    /// 例：deviceFeatureService.actionOverrides["AlarmService"]?["setAlarm"] = "SetAlarmX"
    var actionOverrides: [String: [String: String]] = [:]

    /// 自定义服务类型 URN（设备 device.xml 中解析，需真机确认）
    struct ServiceURN {
        static let alarm = "urn:schemas-upnp-org:service:X_UMI_Alarm:1"
        static let soundEffect = "urn:schemas-upnp-org:service:X_UMI_SoundEffect:1"
        static let favorite = "urn:schemas-upnp-org:service:X_UMI_Favorite:1"
        static let playlist = "urn:schemas-upnp-org:service:X_UMI_Playlist:1"
    }

    private let upnp = UPnPControlService.shared
    private var controlURLCache: [String: String] = [:]

    /// 注册设备 controlURL（由 DeviceManager 在连接时传入）
    func register(device: SoundDevice, controlURLs: [String: String]) {
        controlURLCache = controlURLs
    }

    private func controlURL(for service: String) -> String? {
        controlURLCache[service] ?? controlURLCache.values.first
    }

    private func actionName(_ defaultName: String, service: String) -> String {
        actionOverrides[service]?[defaultName] ?? defaultName
    }

    /// 发送设备功能动作（默认走自定义服务 URN；若设备把功能挂在标准服务上，
    /// 可把 service 换为标准 URN）
    func send(service: String, action: String, arguments: [String: String],
              device: SoundDevice) async throws -> [String: String] {
        guard let ctrl = controlURL(for: service) else {
            throw UPnPError.invalidURL
        }
        let realService: UPnPControlService.ServiceType
        switch service {
        case ServiceURN.alarm:
            realService = .custom(ServiceURN.alarm)
        case ServiceURN.soundEffect:
            realService = .custom(ServiceURN.soundEffect)
        case ServiceURN.favorite:
            realService = .custom(ServiceURN.favorite)
        case ServiceURN.playlist:
            realService = .custom(ServiceURN.playlist)
        default:
            realService = .custom(service)
        }
        return try await upnp.sendAction(device: device, controlURL: ctrl,
                                         serviceType: realService,
                                         action: actionName(action, service: service),
                                         arguments: arguments)
    }

    // MARK: - 闹钟

    func fetchAlarms(device: SoundDevice) async -> [AlarmItem] {
        guard let res = try? await send(service: ServiceURN.alarm,
                                        action: "GetAlarms",
                                        arguments: ["InstanceID": "0"],
                                        device: device) else { return [] }
        return parseAlarms(res)
    }

    func setAlarm(_ alarm: AlarmItem, device: SoundDevice) async -> Bool {
        let args: [String: String] = [
            "InstanceID": "0",
            "Enabled": alarm.enabled ? "1" : "0",
            "Time": alarm.time,
            "RepeatMask": "\(alarm.repeatMask)",
            "SoundURI": alarm.soundName ?? ""
        ]
        guard let res = try? await send(service: ServiceURN.alarm,
                                        action: "SetAlarm",
                                        arguments: args,
                                        device: device) else { return false }
        return res.values.contains("0") || res["code"] == "0"
    }

    func deleteAlarm(id: Int, device: SoundDevice) async -> Bool {
        guard let _ = try? await send(service: ServiceURN.alarm,
                                      action: "DeleteAlarm",
                                      arguments: ["InstanceID": "0", "AlarmID": "\(id)"],
                                      device: device) else { return false }
        return true
    }

    /// 从响应解析闹钟列表（兼容 XML 单值 / 逗号分隔 / JSON）
    private func parseAlarms(_ res: [String: String]) -> [AlarmItem] {
        var items: [AlarmItem] = []
        if let json = res["Result"] ?? res["result"], json.hasPrefix("{") || json.hasPrefix("[") {
            if let data = json.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for (i, d) in arr.enumerated() {
                    items.append(AlarmItem(id: d["id"] as? Int ?? i,
                                           enabled: (d["enabled"] as? Bool) ?? true,
                                           time: d["time"] as? String ?? "07:00",
                                           repeatMask: d["repeat"] as? Int ?? 0,
                                           channelID: d["channel"] as? String,
                                           soundName: d["sound"] as? String))
                }
            }
        } else if let csv = res["Alarms"] ?? res["alarms"], !csv.isEmpty {
            // 简化的分隔解析：time|enabled
            for (i, part) in csv.components(separatedBy: ",").enumerated() {
                items.append(AlarmItem(id: i, enabled: true, time: part))
            }
        }
        return items
    }

    // MARK: - 音效

    func fetchSoundEffects(device: SoundDevice) async -> [SoundEffectItem] {
        guard let res = try? await send(service: ServiceURN.soundEffect,
                                        action: "GetSoundEffects",
                                        arguments: ["InstanceID": "0"],
                                        device: device) else { return [] }
        // 标准音效列表（小米音箱常见），序号即设备音效 ID
        let names = ["标准", "人声", "低频增强", "高频增强", "清澈人声", "电影模式", "音乐模式", "自定义"]
        var items = names.enumerated().map { SoundEffectItem(id: $0, name: $1) }
        if let sel = res["CurrentSoundEffect"] ?? res["current"], let id = Int(sel), id < items.count {
            items[id].selected = true
        }
        return items
    }

    func setSoundEffect(id: Int, device: SoundDevice) async -> Bool {
        guard let _ = try? await send(service: ServiceURN.soundEffect,
                                      action: "SetSoundEffect",
                                      arguments: ["InstanceID": "0", "SoundEffectID": "\(id)"],
                                      device: device) else { return false }
        return true
    }

    // MARK: - 收藏与播放列表

    func fetchFavorites(device: SoundDevice) async -> [Channel] {
        guard let res = try? await send(service: ServiceURN.favorite,
                                        action: "GetFavorites",
                                        arguments: ["InstanceID": "0"],
                                        device: device) else { return [] }
        var items: [Channel] = []
        if let json = res["Result"] ?? res["result"], let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for d in arr {
                if let t = d["title"] as? String {
                    items.append(Channel(title: t, cpID: d["cp_id"] as? String,
                                         cpType: d["cp_type"] as? String,
                                         uri: d["uri"] as? String,
                                         artist: d["artist"] as? String))
                }
            }
        }
        return items
    }

    func addFavorite(_ channel: Channel, device: SoundDevice) async -> Bool {
        guard let _ = try? await send(service: ServiceURN.favorite,
                                      action: "AddToFavorites",
                                      arguments: ["InstanceID": "0", "Title": channel.title,
                                                  "URI": channel.uri ?? ""],
                                      device: device) else { return false }
        return true
    }

    func fetchPlaylists(device: SoundDevice) async -> [Channel] {
        guard let res = try? await send(service: ServiceURN.playlist,
                                        action: "GetPlaylists",
                                        arguments: ["InstanceID": "0"],
                                        device: device) else { return [] }
        var items: [Channel] = []
        if let json = res["Result"] ?? res["result"], let data = json.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for d in arr {
                if let t = d["title"] as? String {
                    items.append(Channel(title: t, cpID: d["cp_id"] as? String,
                                         uri: d["uri"] as? String))
                }
            }
        }
        return items
    }
}
