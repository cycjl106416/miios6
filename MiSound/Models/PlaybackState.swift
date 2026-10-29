import Foundation

/// 播放状态。
/// 语义对齐 UPnP AVTransport 的 GetTransportInfo / GetPositionInfo 响应，
/// 以及 Android 版 PlayState（位置/时长/状态/音轨信息）。
enum PlaybackStatus: String, Codable {
    case stopped = "STOPPED"
    case playing = "PLAYING"
    case paused = "PAUSED"
    case transitioning = "TRANSITIONING"
    case noMedia = "NO_MEDIA_PRESENT"
    case unknown = "UNKNOWN"

    var isActive: Bool { self == .playing || self == .paused || self == .transitioning }
}

/// 当前播放音轨信息（对应 PlayingAudioInfo + Audio 模型的关键字段）
struct TrackInfo: Codable, Equatable {
    /// 曲目标题
    var title: String?
    /// 歌手/艺人
    var artist: String?
    /// 专辑
    var album: String?
    /// 专辑封面 URL（若有）
    var artworkURL: URL?
    /// 音源类型（音乐/电台/频道等）
    var sourceType: String?
    /// 音源 URI（AVTransport 中的 current URI）
    var uri: String?
}

/// 播放进度（对应 UPnP GetPositionInfo 与 Android PlayingProgress）
struct PlaybackProgress: Codable, Equatable {
    /// 当前播放位置（秒）
    var positionSeconds: Double
    /// 总时长（秒），未知为 -1
    var durationSeconds: Double
    /// 是否有效
    var isValid: Bool { positionSeconds >= 0 && durationSeconds > 0 }
}

/// 一次完整播放快照，供 UI 与锁屏(NowPlaying) 使用
struct PlaybackSnapshot {
    var status: PlaybackStatus = .unknown
    var track: TrackInfo?
    var progress: PlaybackProgress?
    /// 音量 0...100（RenderingControl 返回值）
    var volume: Int = 50
    /// 是否静音
    var isMuted: Bool = false
    /// 是否支持 Seek
    var canSeek: Bool = false
    /// 是否支持 Next/Previous
    var canSkip: Bool = true
}
