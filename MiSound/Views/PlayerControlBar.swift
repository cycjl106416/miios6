import UIKit

/// 底部播放控制条：上一首 / 播放暂停 / 下一首 + 曲名 + 进度 + 音量
final class PlayerControlBar: UIView {

    var onTogglePlay: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onTapDetail: (() -> Void)?
    var onVolumeChange: ((Int) -> Void)?

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let prevButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let volumeSlider = UISlider()
    private let progressView = UIProgressView(progressViewStyle: .default)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.numberOfLines = 1
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1

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

        let tap = UITapGestureRecognizer(target: self, action: #selector(detailTapped))
        titleLabel.isUserInteractionEnabled = true
        titleLabel.addGestureRecognizer(tap)

        [titleLabel, subtitleLabel, prevButton, playButton, nextButton,
         volumeSlider, progressView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            titleLabel.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            prevButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 18),
            prevButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            prevButton.widthAnchor.constraint(equalToConstant: 40),
            prevButton.heightAnchor.constraint(equalToConstant: 40),

            playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 48),
            playButton.heightAnchor.constraint(equalToConstant: 48),

            nextButton.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            nextButton.widthAnchor.constraint(equalToConstant: 40),
            nextButton.heightAnchor.constraint(equalToConstant: 40),

            volumeSlider.centerYAnchor.constraint(equalTo: prevButton.centerYAnchor),
            volumeSlider.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 8),
            volumeSlider.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -8),

            bottomAnchor.constraint(equalTo: volumeSlider.bottomAnchor, constant: 10)
        ])
    }

    // MARK: 更新

    func update(with snapshot: PlaybackSnapshot) {
        if let track = snapshot.track, let title = track.title, !title.isEmpty {
            titleLabel.text = title
            var sub = track.artist ?? ""
            if let album = track.album, !album.isEmpty {
                sub += sub.isEmpty ? album : " · \(album)"
            }
            subtitleLabel.text = sub.isEmpty ? "\(snapshot.status.rawValue)" : sub
        } else {
            titleLabel.text = snapshot.status.isActive ? "正在播放" : "未在播放"
            subtitleLabel.text = snapshot.status.rawValue
        }

        let icon = snapshot.status == .playing ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: icon), for: .normal)

        if let progress = snapshot.progress, progress.isValid {
            progressView.progress = Float(min(1, max(0, progress.positionSeconds / progress.durationSeconds)))
        } else {
            progressView.progress = 0
        }

        if Int(volumeSlider.value) != snapshot.volume {
            volumeSlider.value = Float(snapshot.volume)
        }
    }

    // MARK: 动作

    @objc private func playTapped() { onTogglePlay?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func prevTapped() { onPrevious?() }
    @objc private func detailTapped() { onTapDetail?() }
    @objc private func volumeChanged() { onVolumeChange?(Int(volumeSlider.value)) }
}
