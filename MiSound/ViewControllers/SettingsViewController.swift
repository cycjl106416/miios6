import UIKit

/// 设置页：设备信息 / 网络诊断 / 配网入口 / 关于。
/// 对应 Android 版 `mi_sound_main_app_setting_*` 系列页面。
final class SettingsViewController: UITableViewController {

    private enum Row {
        case currentDevice
        case miioInfo
        case networkDiagnosis
        case alarm
        case soundEffect
        case wifiConfig
        case about
    }

    private let rows: [(Row, String)] = [
        (.currentDevice, "当前设备"),
        (.networkDiagnosis, "网络诊断"),
        (.miioInfo, "MiIO 协议测试"),
        (.alarm, "闹钟"),
        (.soundEffect, "音效"),
        (.wifiConfig, "配网"),
        (.about, "关于")
    ]

    private let manager = DeviceManager.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "setting")
        let (row, title) = rows[indexPath.row]
        cell.textLabel?.text = title
        switch row {
        case .currentDevice:
            cell.detailTextLabel?.text = manager.currentDevice?.displayName ?? "未连接"
        case .about:
            cell.detailTextLabel?.text = "1.3.2 (300)"
        default:
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row].0 {
        case .currentDevice:
            tabBarController?.selectedIndex = 1
        case .networkDiagnosis:
            runNetworkDiagnosis()
        case .miioInfo:
            runMiioTest()
        case .alarm:
            navigationController?.pushViewController(AlarmViewController(), animated: true)
        case .soundEffect:
            navigationController?.pushViewController(SoundEffectViewController(), animated: true)
        case .wifiConfig:
            present(UINavigationController(rootViewController: WifiConfigViewController()), animated: true)
        case .about:
            showAbout()
        }
    }

    // MARK: 动作

    private func runNetworkDiagnosis() {
        guard let device = manager.currentDevice else {
            presentAlert(title: "网络诊断", message: "请先在「设备」页连接一台音箱。")
            return
        }
        let alert = UIAlertController(title: "网络诊断", message: "正在测试…", preferredStyle: .alert)
        present(alert, animated: true)
        Task {
            var lines = ["设备: \(device.displayName) (\(device.ip))"]
            // 1) 设备 HTTP 服务
            if let url = URL(string: "http://\(device.ip):9999/") {
                if let (_, resp) = try? await URLSession.shared.data(from: url),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    lines.append("HTTP :9999 ✓")
                } else {
                    lines.append("HTTP :9999 ✗")
                }
            }
            // 2) MiIO 握手
            do {
                let (did, token, _) = try await MiioLocalService.shared.getToken(ip: device.ip)
                lines.append("MiIO 握手 ✓ did=\(did) token=\(token.prefix(6))…")
            } catch {
                lines.append("MiIO 握手 ✗ \(error.localizedDescription)")
            }
            // 3) UPnP 控制
            let av = manager.currentControlURLs["urn:schemas-upnp-org:service:AVTransport:1"] ?? ""
            if !av.isEmpty {
                if let info = try? await UPnPControlService.shared.getTransportInfo(device, controlURL: av) {
                    lines.append("UPnP GetTransportInfo ✓ \(info["TransportState"] ?? "?")")
                } else {
                    lines.append("UPnP GetTransportInfo ✗")
                }
            } else {
                lines.append("UPnP controlURL 未解析（设备可能不支持标准服务）")
            }

            alert.title = "诊断完成"
            alert.message = lines.joined(separator: "\n")
            alert.addAction(UIAlertAction(title: "好", style: .default))
        }
    }

    private func runMiioTest() {
        guard manager.currentDevice != nil else {
            presentAlert(title: "MiIO 协议测试", message: "请先在「设备」页连接一台音箱。")
            return
        }
        let alert = UIAlertController(title: "MiIO 协议测试", message: "请求 miIO.info…", preferredStyle: .alert)
        present(alert, animated: true)
        Task {
            let result = await manager.miioInfo()
            if let result {
                let data = (try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "解析失败"
                alert.title = "miIO.info 成功"
                alert.message = String(data.prefix(1200))
                _ = data
            } else {
                alert.title = "miIO.info 失败"
                alert.message = "设备无响应。token 可能未授权（已绑定设备需从云端获取 token）。"
            }
            alert.addAction(UIAlertAction(title: "好", style: .default))
        }
    }

    private func showAbout() {
        presentAlert(title: "关于",
                     message: "小米音箱 iOS 版\n版本 1.3.2 (300)\n\n协议移植自 Android 版 com.mi.umi.controlpoint 反编译结果：\nUPnP(ohNet) + MiIO 局域网控制。\n\n注意：本工程为逆向重开发，与小米官方无关。")
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}
