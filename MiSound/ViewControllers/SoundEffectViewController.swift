import UIKit

/// 音效选择页：列出音效并切换。
/// 对应 Android 版 `mi_sound_main_app_setting_option_select_sound_effect.xml`。
/// 协议动作名（GetSoundEffects/SetSoundEffect）可在 `DeviceFeatureService.actionOverrides` 校准。
final class SoundEffectViewController: UITableViewController {

    private var effects: [SoundEffectItem] = []
    private let featureService = DeviceFeatureService.shared
    private let manager = DeviceManager.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "音效"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        reloadEffects()
    }

    private func reloadEffects() {
        guard let device = manager.currentDevice else { return }
        Task { @MainActor in
            let list = await featureService.fetchSoundEffects(device: device)
            effects = list
            tableView.reloadData()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        effects.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let item = effects[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = item.name
        cell.contentConfiguration = config
        cell.accessoryType = item.selected ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let device = manager.currentDevice else { return }
        let item = effects[indexPath.row]
        Task { @MainActor in
            let ok = await featureService.setSoundEffect(id: item.id, device: device)
            if ok {
                for i in effects.indices { effects[i].selected = (i == indexPath.row) }
                tableView.reloadData()
            } else {
                let alert = UIAlertController(title: nil, message: "切换失败（动作名可能需校准）", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                present(alert, animated: true)
            }
        }
    }
}
