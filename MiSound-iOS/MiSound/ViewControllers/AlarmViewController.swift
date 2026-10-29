import UIKit

/// 闹钟设置页：列出 / 新增 / 开关 / 删除闹钟。
/// 对应 Android 版 `mi_sound_main_app_setting_alarm_clock*` 系列页面。
/// 协议动作名（GetAlarms/SetAlarm/DeleteAlarm）可在 `DeviceFeatureService.actionOverrides` 校准。
final class AlarmViewController: UITableViewController {

    private var alarms: [AlarmItem] = []
    private let featureService = DeviceFeatureService.shared
    private let manager = DeviceManager.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "闹钟"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add,
                                                            target: self, action: #selector(addAlarm))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        reloadAlarms()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadAlarms()
    }

    private func reloadAlarms() {
        guard let device = manager.currentDevice else { return }
        Task {
            let list = await featureService.fetchAlarms(device: device)
            alarms = list
            tableView.reloadData()
        }
    }

    @objc private func addAlarm() {
        guard manager.currentDevice != nil else {
            presentSimpleAlert("请先连接音箱")
            return
        }
        let alert = UIAlertController(title: "新增闹钟", message: "选择时间", preferredStyle: .alert)
        let picker = UIDatePicker()
        picker.datePickerMode = .time
        picker.preferredDatePickerStyle = .wheels
        picker.locale = Locale(identifier: "zh_CN")
        alert.view.addSubview(picker)
        // 布局
        picker.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 8),
            picker.trailingAnchor.constraint(equalTo: alert.view.trailingAnchor, constant: -8),
            picker.topAnchor.constraint(equalTo: alert.view.topAnchor, constant: 48),
            picker.heightAnchor.constraint(equalToConstant: 160)
        ])
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"
            let time = fmt.string(from: picker.date)
            self?.saveAlarm(AlarmItem(id: 0, enabled: true, time: time, repeatMask: 127))
        })
        present(alert, animated: true)
    }

    private func saveAlarm(_ alarm: AlarmItem) {
        guard let device = manager.currentDevice else { return }
        Task {
            let ok = await featureService.setAlarm(alarm, device: device)
            if !ok { presentSimpleAlert("发送失败（动作名可能需校准）") }
            reloadAlarms()
        }
    }

    private func deleteAlarm(_ alarm: AlarmItem) {
        guard let device = manager.currentDevice else { return }
        Task {
            _ = await featureService.deleteAlarm(id: alarm.id, device: device)
            reloadAlarms()
        }
    }

    private func presentSimpleAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }

    // MARK: Table

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(alarms.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if alarms.isEmpty {
            cell.textLabel?.text = "暂无闹钟（点击右上角 + 新增）"
            cell.textLabel?.textColor = .secondaryLabel
            cell.accessoryView = nil
            return cell
        }
        let alarm = alarms[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = alarm.time
        config.secondaryText = alarm.repeatText
        cell.contentConfiguration = config

        let sw = UISwitch()
        sw.isOn = alarm.enabled
        sw.tag = indexPath.row
        sw.addTarget(self, action: #selector(toggleAlarm(_:)), for: .valueChanged)
        cell.accessoryView = sw
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !alarms.isEmpty
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, !alarms.isEmpty else { return }
        deleteAlarm(alarms[indexPath.row])
    }

    @objc private func toggleAlarm(_ sender: UISwitch) {
        guard sender.tag < alarms.count else { return }
        var alarm = alarms[sender.tag]
        alarm.enabled = sender.isOn
        saveAlarm(alarm)
    }
}
