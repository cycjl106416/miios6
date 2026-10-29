import UIKit

/// 设备列表单元格：图标 + 名称/型号 + IP + 连接状态
final class DeviceCell: UITableViewCell {

    static let reuseID = "DeviceCell"

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusDot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        iconView.image = UIImage(systemName: "hifispeaker.fill")
        iconView.tintColor = .systemOrange
        iconView.contentMode = .scaleAspectFit

        nameLabel.font = .systemFont(ofSize: 16, weight: .medium)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabel

        statusDot.layer.cornerRadius = 4
        statusDot.backgroundColor = .systemGray4

        [iconView, nameLabel, detailLabel, statusDot].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),

            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: statusDot.leadingAnchor, constant: -8),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),

            statusDot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8)
        ])
    }

    func configure(with device: SoundDevice, isCurrent: Bool) {
        nameLabel.text = device.displayName
        var detail = [device.model.isEmpty ? "" : device.model,
                      device.firmwareVersion.isEmpty ? "" : "固件 \(device.firmwareVersion)",
                      device.ip]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        if let ssid = device.ssid, !ssid.isEmpty { detail += " · \(ssid)" }
        detailLabel.text = detail

        statusDot.backgroundColor = device.isConnected ? .systemGreen : .systemGray3
        accessoryType = isCurrent ? .checkmark : .none
    }
}
