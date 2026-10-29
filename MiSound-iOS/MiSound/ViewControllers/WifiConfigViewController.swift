import UIKit
import NetworkExtension

/// 配网向导。
/// 对应 Android 版 `com.mi.umi.controlpoint.b.b.b` 的配网状态机：
/// 1. 记录目标 WiFi（SSID/密码）
/// 2. 切到音箱热点（Android 自动切网；iOS 需在系统设置中手动连接热点）
/// 3. 从路由表取网关 IP（热点模式下网关即音箱）
/// 4. 本地握手取设备 token（`MiioLocalAPI.get_token`：32×'f' 全 token 发 hello，
///    设备直接返回真实 token——老版音箱固件无需小米账号即可配网，与 Android App 行为一致）
/// 5. 构造 `{"id":ts,"method":"miIO.config_router","params":{"ssid":..,"passwd":..,"uid":..,"gmt_offset":..}}`
///    通过 MiIO RPC（UDP 54321）发给音箱，code==0 即成功。
final class WifiConfigViewController: UITableViewController {

    private let ssidField = UITextField()
    private let passwordField = UITextField()
    private let uidField = UITextField()
    private let logLabel = UILabel()

    private var logText = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "配网"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close,
                                                           target: self, action: #selector(closeTapped))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.tableFooterView = makeFooterView()
    }

    private func makeFooterView() -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 220))
        logLabel.numberOfLines = 0
        logLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logLabel.textColor = .secondaryLabel
        logLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(logLabel)
        NSLayoutConstraint.activate([
            logLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            logLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            logLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            logLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        appendLog("请按提示逐步操作：\n① 填写音箱要连接的 WiFi 与密码；\n② 手机系统设置里切换到音箱的热点（音箱开机会广播 MiSound_XXXX 热点）；\n③ 回到本页点击「开始配网」。\n\n无需小米账号：本流程走老版固件的本地 token 握手（全 f 包），与安卓 App 免登录配网一致。")
        return container
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func appendLog(_ text: String) {
        logText += text + "\n"
        logLabel.text = logText
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "目标 WiFi（音箱将要连接的网络）" : nil
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 3 : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if indexPath.section == 1 {
            cell.textLabel?.text = "开始配网"
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.textColor = .systemBlue
            return cell
        }
        let field: UITextField
        switch indexPath.row {
        case 0:
            field = ssidField
            field.placeholder = "WiFi 名称 (SSID)"
        case 1:
            field = passwordField
            field.placeholder = "WiFi 密码"
            field.isSecureTextEntry = true
        default:
            field = uidField
            field.placeholder = "小米 UID（选填，一般留空即可）"
            field.keyboardType = .numberPad
        }
        field.frame = cell.contentView.bounds.insetBy(dx: 16, dy: 0)
        field.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cell.contentView.addSubview(field)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        startConfig()
    }

    // MARK: 配网流程

    private func startConfig() {
        guard let ssid = ssidField.text, !ssid.isEmpty else {
            appendLog("✗ 请填写目标 WiFi 名称")
            return
        }
        let password = passwordField.text ?? ""
        let uid = Int64(uidField.text ?? "") ?? 0
        let speakerIP = gatewayIP()
        appendLog("开始配网：SSID=\(ssid) uid=\(uid)")
        appendLog("音箱地址（热点网关）= \(speakerIP)")

        Task {
            // ① 本地握手取设备 token（老版固件：全 f 包直接返回真实 token，无需账号）
            appendLog("① 本地握手获取 token…")
            let token: String
            do {
                let (did, gotToken, _) = try await MiioLocalService.shared.getToken(ip: speakerIP)
                token = gotToken
                appendLog("✓ token 获取成功 did=\(did) token=\(token.prefix(6))…")
            } catch {
                appendLog("✗ 握手失败：\(error.localizedDescription)")
                appendLog("请确认手机已连接到音箱热点（MiSound_XXXX），再重试。")
                return
            }
            // ② 发送 miIO.config_router
            await sendConfigRouter(ssid: ssid, password: password, uid: uid, token: token, ip: speakerIP)
        }
    }

    /// 向音箱发送 miIO.config_router（目标地址：音箱热点网关 IP）
    private func sendConfigRouter(ssid: String, password: String, uid: Int64, token: String, ip: String) async {
        let gmtOffset = Int64(TimeZone.current.secondsFromGMT())
        let params: [String: Any] = [
            "ssid": ssid,
            "passwd": password,
            "uid": uid,
            "gmt_offset": gmtOffset
        ]
        appendLog("② 发送 miIO.config_router…")
        do {
            let resp = try await MiioLocalService.shared.rpc(ip: ip,
                                                             method: "miIO.config_router",
                                                             params: params,
                                                             token: token)
            appendLog("响应: \(resp)")
            if let result = resp["result"] as? [String: Any],
               let code = result["code"] as? Int, code == 0 {
                appendLog("✓ 配网成功！请将手机切回目标 WiFi，音箱会自动连上。")
            } else {
                appendLog("△ 设备已响应，请确认 code==0 表示成功。")
            }
        } catch {
            appendLog("✗ 配网失败：\(error.localizedDescription)")
        }
    }

    /// 获取音箱地址：当前网关 IP（热点模式下即音箱 IP），读路由表优先
    private func gatewayIP() -> String {
        if let gw = DeviceManager.gatewayIPAddress(), !gw.isEmpty, gw != "0.0.0.0" {
            return gw
        }
        // 兜底：按本机网段猜 .1（小米热点常见 192.168.31.1）
        if let local = DeviceManager.localIPAddress() {
            let parts = local.split(separator: ".")
            if parts.count == 4 {
                return "\(parts[0]).\(parts[1]).\(parts[2]).1"
            }
        }
        return "192.168.31.1"
    }
}
