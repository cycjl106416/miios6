import UIKit
import MediaPlayer

/// 锁屏 / 控制中心播放控件。
/// 对应 Android 版 `LockScreenActivity`（锁屏媒体控件）在 iOS 上的实现：
/// 通过 MPNowPlayingInfoCenter 展示曲目与进度，并通过 MPRemoteCommandCenter
/// 响应锁屏/耳机/控制中心的播放控制。
final class NowPlayingController {

    static let shared = NowPlayingController()

    private var registered = false

    func register() {
        guard !registered else { return }
        registered = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { await DeviceManager.shared.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { await DeviceManager.shared.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { await DeviceManager.shared.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { await DeviceManager.shared.nextTrack() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { await DeviceManager.shared.previousTrack() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                Task { await DeviceManager.shared.seek(to: Int(e.positionTime)) }
            }
            return .success
        }
    }

    /// 用最新播放快照刷新锁屏信息
    func update(with snapshot: PlaybackSnapshot) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.track?.title ?? "小米音箱",
            MPMediaItemPropertyArtist: snapshot.track?.artist ?? snapshot.track?.album ?? "",
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.status == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.progress?.positionSeconds ?? 0
        ]
        if let duration = snapshot.progress?.durationSeconds, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        MPRemoteCommandCenter.shared().playCommand.isEnabled = true
        MPRemoteCommandCenter.shared().pauseCommand.isEnabled = true
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = snapshot.canSkip
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = snapshot.canSkip
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = snapshot.canSeek
    }
}
