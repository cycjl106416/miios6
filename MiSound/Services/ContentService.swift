import Foundation

/// 小米音箱内容服务（频道 / 播放列表 / 音源）。
/// 对齐反编译 `com.mi.umi.controlpoint.source.cp.a`：
/// - 默认播放列表（频道）：`http://soundbar.pandora.xiaomi.com/upgrade/default_playlist?pt=..&t=mobile&hw=..`
/// - 音源服务：小米音乐 / 酷我 / 虾米 / 库客 / 贝瓦 + 蜻蜓 / 考拉 / 凤凰 / 荔枝 / 喜马拉雅
/// 注意：2017 年后部分内容源（虾米/贝瓦/凤凰等）已下线，接口返回可能为空。
final class ContentService {

    static let shared = ContentService()

    /// 内容服务根地址（反编译常量）
    private let pandoraHost = "http://soundbar.pandora.xiaomi.com"

    /// 共享 URLSession（仅做内容拉取，复用连接）
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    /// 音源服务列表（名称 + 服务主机，对齐反编译常量表）
    struct ContentProvider {
        let name: String
        let host: String
    }

    static let musicProviders: [ContentProvider] = [
        ContentProvider(name: "小米音乐", host: "soundbar.pandora.xiaomi.com"),
        ContentProvider(name: "酷我音乐", host: "www.kuwo.cn"),
        ContentProvider(name: "虾米音乐", host: "spark.api.xiami.com"),
        ContentProvider(name: "库客音乐", host: "api.kuke.com"),
        ContentProvider(name: "贝瓦儿歌", host: "app.beva.com"),
    ]

    static let radioProviders: [ContentProvider] = [
        ContentProvider(name: "蜻蜓FM", host: "api.open.qingting.fm"),
        ContentProvider(name: "考拉FM", host: "open.kaolafm.com"),
        ContentProvider(name: "凤凰FM", host: "fm.ifeng.com"),
        ContentProvider(name: "荔枝FM", host: "open.lizhi.fm"),
        ContentProvider(name: "喜马拉雅", host: "api.ximalaya.com"),
    ]

    /// 拉取默认播放列表（频道列表）
    /// - Parameters:
    ///   - pt: 播放列表类型（Android 端由设备能力决定，默认 0）
    ///   - hw: 硬件型号（如 S601 / S602），用于服务端匹配内容
    func fetchDefaultPlaylist(pt: Int = 0, hw: String) async -> [Channel] {
        let urlString = "\(pandoraHost)/upgrade/default_playlist?pt=\(pt)&t=mobile&hw=\(hw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hw)"
        guard let url = URL(string: urlString) else { return [] }
        guard let (data, resp) = try? await Self.sharedSession.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        guard let json = try? JSONSerialization.jsonObject(with: data),
              let list = Self.extractList(from: json) else { return [] }
        return list.compactMap { Self.channel(from: $0) }
    }

    /// 从响应中提取内容数组（兼容 {list:[...]} / {data:[...]} / 顶层数组）
    private static func extractList(from json: Any) -> [[String: Any]]? {
        if let arr = json as? [[String: Any]] { return arr }
        if let dict = json as? [String: Any] {
            for key in ["list", "data", "result", "playlist", "items"] {
                if let arr = dict[key] as? [[String: Any]] { return arr }
            }
        }
        return nil
    }

    /// 单条内容解析（字段对齐反编译：title/cp_id/cp_type/picture/uri/artist/desc/type）
    private static func channel(from dict: [String: Any]) -> Channel? {
        guard let title = dict["title"] as? String, !title.isEmpty else { return nil }
        var pictures: [String] = []
        for key in ["picture", "picture1", "picture2"] {
            if let p = dict[key] as? String, !p.isEmpty { pictures.append(p) }
        }
        return Channel(title: title,
                       cpID: dict["cp_id"] as? String,
                       cpType: dict["cp_type"] as? String,
                       uri: dict["uri"] as? String ?? dict["url"] as? String,
                       pictures: pictures,
                       artist: dict["artist"] as? String,
                       desc: dict["desc"] as? String,
                       type: dict["type"] as? String)
    }
}
