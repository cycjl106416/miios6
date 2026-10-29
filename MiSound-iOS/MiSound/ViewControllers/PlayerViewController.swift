import UIKit

/// 全屏播放器页（pageSheet 呈现）。
/// 对应 Android 版 `mi_sound_main_app_player_v2.xml`：封面区、曲名、
/// 进度条（可拖拽 Seek）、上一首/播放暂停/下一首、音量控制。
final class PlayerViewController: UIViewController {

    private let manager = DeviceManager.shared

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let progressSlider = UISlider()
    private let positionLabel = UILabel()
    private let durationLabel = UILabel()
    private let prevButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let volumeSlider = UISlider()
    private let volumeLabel = UILabel()
    private var isSeeking = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "正在播放"

        setupUI()
        refresh()

        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: DeviceManager.NotificationName.playbackUpdated, object: nil)
    }

    private func setupUI() {
        artworkView.image = UIImage(systemName: "music.note")
        artworkView.tintColor = .systemOrange
        artworkView.contentMode = .scaleAspectFit
        artworkView.backgroundColor = .secondarySystemBackground
        artworkView.layer.cornerRadius = 12

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        subtitleLabel.font = .systemFont(ofSize: 15)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center

        progressSlider.minimumValue = 0
        progressSlider.maximumValue = 1
        progressSlider.addTarget(self, action: #selector(progressChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(progressEditingStart), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(progressEditingEnd), for: [.touchUpInside, .touchUpOutside])

        positionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        positionLabel.textColor = .secondaryLabel
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        durationLabel.textColor = .secondaryLabel
        durationLabel.textAlignment = .right

        prevButton.setImage(UIImage(systemName: "backward.fill"), for: .normal)
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        nextButton.setImage(UIImage(systemName: "forward.fill"), for: .normal)
        prevButton.tintColor = .label
        playButton.tintColor = .label
        nextButton.tintColor = .label
        prevButton.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        volumeSlider.minimumValue = 0
        volumeSlider.maximumValue = 100
        volumeSlider.addTarget(self, action: #selector(volumeChanged), for: .valueChanged)
        volumeLabel.text = "音量"
        volumeLabel.font = .systemFont(ofSize: 13)
        volumeLabel.textColor = .secondaryLabel

        // 进度时间行
        let progressRow = UIStackView(arrangedSubviews: [positionLabel, durationLabel])
        progressRow.axis = .horizontal
        progressRow.distribution = .fillEqually

        // 控制按钮行
        let controlsRow = UIStackView(arrangedSubviews: [prevButton, playButton, nextButton])
        controlsRow.axis = .horizontal
        controlsRow.distribution = .equalSpacing

        let volumeRow = UIStackView(arrangedSubviews: [volumeLabel, volumeSlider])
        volumeRow.axis = .horizontal
        volumeRow.spacing = 8
        volumeRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [artworkView, titleLabel, subtitleLabel,
                                                   progressSlider, progressRow, controlsRow, volumeRow])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            artworkView.heightAnchor.constraint(equalToConstant: 200),
            artworkView.widthAnchor.constraint(equalToConstant: 200),
            artworkView.centerXAnchor.constraint(equalTo: stack.centerXAnchor),

            prevButton.widthAnchor.constraint(equalToConstant: 56),
            playButton.widthAnchor.constraint(equalToConstant: 64),
            nextButton.widthAnchor.constraint(equalToConstant: 56),
            controlsRow.heightAnchor.constraint(equalToConstant: 56),

            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])
    }

    @objc private func refresh() {
        let s = manager.snapshot
        titleLabel.text = s.track?.title ?? "未知曲目"
        subtitleLabel.text = s.track?.artist ?? s.status.rawValue

        let icon = s.status == .playing ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: icon), for: .normal)

        if let p = s.progress, p.isValid {
            progressSlider.value = Float(p.positionSeconds / p.durationSeconds)
            positionLabel.text = Self.formatTime(p.positionSeconds)
            durationLabel.text = Self.formatTime(p.durationSeconds)
            progressSlider.isEnabled = true
        } else {
            progressSlider.value = 0
            positionLabel.text = "--:--"
            durationLabel.text = "--:--"
            progressSlider.isEnabled = false
        }
        volumeSlider.value = Float(s.volume)
    }

    private static func formatTime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: 动作

    @objc private func playTapped() { Task { await manager.togglePlayPause() } }
    @objc private func nextTapped() { Task { await manager.nextTrack() } }
    @objc private func prevTapped() { Task { await manager.previousTrack() } }

    @objc private func progressEditingStart() { isSeeking = true }

    @objc private func progressEditingEnd() {
        guard isSeeking, let p = manager.snapshot.progress, p.isValid else { return }
        let target = Int(progressSlider.value * Float(p.durationSeconds))
        Task { await manager.seek(to: target) }
        isSeeking = false
    }

    @objc private func progressChanged() {
        guard let p = manager.snapshot.progress, p.isValid else { return }
        positionLabel.text = Self.formatTime(Double(progressSlider.value) * p.durationSeconds)
    }

    @objc private func volumeChanged() {
        Task { await manager.setVolume(Int(volumeSlider.value)) }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
