import Foundation

/// 频道 / 音源 / 播放列表内容模型。
/// 字段对齐反编译 `source/cp/a.java` 中解析的 JSON 键：
/// title / cp_id / cp_type / picture / picture1 / picture2 / type / uri / artist / desc / album / lyrics
struct Channel: Codable, Identifiable, Equatable {
    var title: String
    /// 内容提供商 ID（如 xiaomi / kuwo / ximalaya…）
    var cpID: String?
    /// 内容提供商类型
    var cpType: String?
    /// 播放 URI（传入 UPnP SetAVTransportURI）
    var uri: String?
    /// 封面（多张取第一张）
    var pictures: [String] = []
    var artist: String?
    var desc: String?
    /// 类型：playlist/album/radio…
    var type: String?

    var id: String { "\(cpID ?? "")-\(title)-\(uri ?? "")" }

    var artworkURL: URL? {
        pictures.compactMap { URL(string: $0) }.first
    }
}

/// 闹钟模型（对齐 aidl AlarmList 的常用字段）
struct AlarmItem: Codable, Identifiable, Equatable {
    var id: Int = 0
    var enabled: Bool = true
    /// 24 小时制 HH:mm
    var time: String = "07:00"
    /// 重复：星期位掩码（1=周一 … 64=周日）
    var repeatMask: Int = 0
    var channelID: String?
    var soundName: String?

    var repeatText: String {
        guard repeatMask != 0 else { return "仅一次" }
        let days = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        var names: [String] = []
        for i in 0..<7 where (repeatMask >> i) & 1 == 1 { names.append(days[i]) }
        return names.count == 7 ? "每天" : names.joined(separator: " ")
    }
}

/// 音效模型（对齐 aidl SoundEffect）
struct SoundEffectItem: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var selected: Bool = false
}
