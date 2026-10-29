import UIKit

/// 主页：顶部设备信息 + 频道/音源列表 + 底部播放控制条。
/// 对应 Android 版 `MiSoundActivity`（mi_sound_main_app_main_page_v2）：
/// 频道列表（小米内容服务 pandora 接口）+ 常驻播放控制条。
final class MainPageViewController: UIViewController {

    private let manager = DeviceManager.shared
    private let controlBar = PlayerControlBar()

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    /// 频道/音源列表（pandora 接口拉取；不可达时回退静态音源入口）
    private var channels: [Channel] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "小米音箱"
        view.backgroundColor = .systemBackground

        // 设备名入口（点击跳转设备页）
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "设备", style: .plain, target: self, action: #selector(switchDeviceTapped))

        // 空态提示
        emptyLabel.text = "请先在「设备」页搜索并连接音箱"
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        controlBar.translatesAutoresizingMaskIntoConstraints = false

        [tableView, emptyLabel, controlBar].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),

            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            controlBar.topAnchor.constraint(equalTo: tableView.bottomAnchor),
            controlBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            controlBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            controlBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])

        // 控制条动作
        controlBar.onTogglePlay = { [weak self] in
            Task { await self?.manager.togglePlayPause() }
        }
        controlBar.onNext = { [weak self] in
            Task { await self?.manager.nextTrack() }
        }
        controlBar.onPrevious = { [weak self] in
            Task { await self?.manager.previousTrack() }
        }
        controlBar.onVolumeChange = { [weak self] value in
            Task { await self?.manager.setVolume(value) }
        }
        controlBar.onTapDetail = { [weak self] in
            self?.presentPlayer()
        }

        NotificationCenter.default.addObserver(self, selector: #selector(playbackUpdated),
                                               name: DeviceManager.NotificationName.playbackUpdated, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceConnected),
                                               name: DeviceManager.NotificationName.deviceConnected, object: nil)

        NowPlayingController.shared.register()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateDeviceTitle()
        controlBar.update(with: manager.snapshot)
        emptyLabel.isHidden = manager.currentDevice != nil
        tableView.isHidden = manager.currentDevice == nil
        manager.startPolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        manager.stopPolling()
    }

    @objc private func playbackUpdated() {
        controlBar.update(with: manager.snapshot)
        NowPlayingController.shared.update(with: manager.snapshot)
        tableView.reloadData()
    }

    @objc private func deviceConnected() {
        updateDeviceTitle()
        emptyLabel.isHidden = true
        tableView.isHidden = false
        loadChannels()
    }

    /// 拉取频道列表（小米内容服务 pandora 接口）
    private func loadChannels() {
        guard channels.isEmpty else { return }
        Task { @MainActor in
            let hw = manager.currentDevice?.model ?? ""
            let list = await ContentService.shared.fetchDefaultPlaylist(hw: hw)
            channels = list
            if list.isEmpty {
                // 接口不可达时展示本机音源入口（静态列表，来自反编译常量表）
                channels = ContentService.musicProviders.map { Channel(title: $0.name, cpID: nil, cpType: nil, uri: nil) }
                + ContentService.radioProviders.map { Channel(title: $0.name, cpID: nil, cpType: nil, uri: nil) }
            }
            tableView.reloadData()
        }
    }

    /// 播放频道：SetAVTransportURI + Play
    private func playChannel(_ channel: Channel) {
        guard let device = manager.currentDevice else { return }
        Task { @MainActor in
            if let uri = channel.uri, !uri.isEmpty, let ctrl = manager.avControlURL() {
                try? await UPnPControlService.shared.setURI(device, controlURL: ctrl, uri: uri)
                try? await UPnPControlService.shared.play(device, controlURL: ctrl)
            } else {
                // 无 URI（离线音源入口）：提示该音源需在设备端配置
                let alert = UIAlertController(title: channel.title, message: "该音源为设备端内容源，请在音箱上确认可用后重试。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                present(alert, animated: true)
            }
        }
    }

    @objc private func switchDeviceTapped() {
        tabBarController?.selectedIndex = 1
    }

    private func updateDeviceTitle() {
        if let device = manager.currentDevice {
            navigationItem.title = device.displayName
            navigationItem.leftBarButtonItem?.title = "设备 ▾"
        }
    }

    private func presentPlayer() {
        let player = PlayerViewController()
        player.modalPresentationStyle = .pageSheet
        present(player, animated: true)
    }
}

// MARK: - UITableViewDataSource / Delegate

extension MainPageViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "正在播放" : "频道 / 音源"
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? (manager.snapshot.status.isActive ? 1 : 0) : channels.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            let s = manager.snapshot
            config.text = s.track?.title ?? "未知曲目"
            config.secondaryText = (s.track?.artist ?? "") + (s.progress?.isValid == true ? " · \(Int(s.progress?.positionSeconds ?? 0))s/\(Int(s.progress?.durationSeconds ?? 0))s" : "")
            config.image = UIImage(systemName: "waveform")
        } else {
            let c = channels[indexPath.row]
            config.text = c.title
            config.secondaryText = [c.artist, c.desc].compactMap { $0 }.joined(separator: " · ")
            config.image = UIImage(systemName: "music.note.list")
        }
        cell.contentConfiguration = config
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        playChannel(channels[indexPath.row])
    }
}
