import UIKit

/// 设备列表页：SSDP 搜索 / 网段扫描 / 连接设备
final class DeviceListViewController: UIViewController {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let manager = DeviceManager.shared
    private var isScanning = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设备"
        view.backgroundColor = .systemBackground

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(DeviceCell.self, forCellReuseIdentifier: DeviceCell.reuseID)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .search, target: self, action: #selector(scanTapped))

        NotificationCenter.default.addObserver(self, selector: #selector(devicesChanged),
                                               name: DeviceManager.NotificationName.devicesChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceConnected),
                                               name: DeviceManager.NotificationName.deviceConnected, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceConnectFailed(_:)),
                                               name: DeviceManager.NotificationName.deviceConnectFailed, object: nil)

        Task { await manager.discover(scanSubnet: false) }
    }

    @objc private func scanTapped() {
        guard !isScanning else { return }
        isScanning = true
        let spinner = UIActivityIndicatorView(style: .medium)
        let item = UIBarButtonItem(customView: spinner)
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = item

        Task { @MainActor in
            await manager.discover(scanSubnet: true)
            isScanning = false
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .search, target: self, action: #selector(scanTapped))
        }
    }

    @objc private func devicesChanged() {
        tableView.reloadData()
        // 扫描结束仍无设备：大概率是本地网络未授权（iOS 从不弹窗/从未允许）
        if manager.devices.isEmpty {
            let key = "MiSound.promptedLocalNetwork"
            if !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                promptLocalNetwork()
            }
        }
    }

    /// 空结果时的本地网络权限引导
    private func promptLocalNetwork() {
        let alert = UIAlertController(
            title: "未发现设备",
            message: "若从未弹出过「允许查找本地网络设备」的询问，请在 设置 → 隐私与安全性 → 本地网络 中确认「小米音箱」已开启。\n\n也可以删除 App 后重新安装，首次进入设备页会弹出授权询问，请点「允许」。\n\n同时确认手机与音箱连接的是同一个 Wi-Fi，且音箱已开机。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    @objc private func deviceConnected() {
        tableView.reloadData()
    }

    @objc private func deviceConnectFailed(_ note: Notification) {
        let message = (note.userInfo?["message"] as? String) ?? "连接失败"
        let alert = UIAlertController(title: "连接失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - UITableViewDataSource / Delegate

extension DeviceListViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? manager.devices.count : 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "已发现设备" : nil
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: DeviceCell.reuseID, for: indexPath) as! DeviceCell
            let device = manager.devices[indexPath.row]
            cell.configure(with: device, isCurrent: manager.currentDevice?.uuid == device.uuid)
            return cell
        }
        let cell = UITableViewCell(style: .default, reuseIdentifier: "add")
        cell.textLabel?.text = "手动添加设备（输入 IP）"
        cell.imageView?.image = UIImage(systemName: "plus.circle")
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let device = manager.devices[indexPath.row]
            manager.connect(device)
        } else {
            promptManualAdd()
        }
    }

    /// 手动添加：输入设备 IP
    private func promptManualAdd() {
        let alert = UIAlertController(title: "添加设备", message: "输入设备局域网 IP（如 192.168.1.8）", preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numbersAndPunctuation; $0.placeholder = "192.168.1.8" }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "添加", style: .default) { [weak self] _ in
            guard let ip = alert.textFields?.first?.text, !ip.isEmpty else { return }
            self?.connectManual(ip: ip)
        })
        present(alert, animated: true)
    }

    private func connectManual(ip: String) {
        let device = SoundDevice(uuid: "", locationUrl: "http://\(ip):9999/", ip: ip,
                                 model: "", firmwareVersion: "", type: "sound", capability: 0,
                                 ssid: nil, isConnected: true, miioDid: nil, miioToken: nil)
        manager.connect(device)
    }
}
