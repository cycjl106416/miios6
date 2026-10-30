import Foundation

/// 音箱设备模型。
/// 对应 Android 版 `com.mi.umi.controlpoint.data.aidl.SoundDevice`（字段语义按协议层解析结果整理）：
/// a=已连接, b=uuid, c=LOCATION(device.xml 地址), e=型号(model), f=固件版本,
/// g=类型(sound/tv), h=能力位域(capability, bit i = 1<<i), k=IP, j=SSID
struct SoundDevice: Identifiable, Codable, Equatable {
    /// 设备唯一标识（SSDP USN 中的 uuid，形如 uuid:xxxx-xxxx...）
    let uuid: String
    /// device.xml 地址：http://<ip>:9999/<uuid>/Upnp/device.xml
    var locationUrl: String
    /// 局域网 IP
    var ip: String
    /// 型号（如 S601/S602/S1201）
    var model: String
    /// 固件版本
    var firmwareVersion: String
    /// 类型："sound" 音箱 / "tv"
    var type: String
    /// 能力位域（bit i = 1<<i，0 音量、1 播放、2 列表等）
    var capability: Int
    /// 当前所连 WiFi SSID
    var ssid: String?
    /// 是否已连接/可用
    var isConnected: Bool
    /// MiIO 局域网协议所需：设备 did（device id）
    var miioDid: String?
    /// MiIO 设备 token（32 位十六进制小写）。可从云端获取或局域网探测获取。
    var miioToken: String?
    /// 是否支持 UPnP 控制（device.xml 是否声明了控制服务）
    var supportsUPnP: Bool = true

    /// device.xml 中 <friendlyName>（若解析到）
    var friendlyName: String?

    var id: String { uuid }

    /// 能力判断：是否支持指定 bit
    func hasCapability(_ bit: Int) -> Bool {
        (capability >> bit) & 1 == 1
    }

    /// 展示名：优先 friendlyName，其次型号
    var displayName: String {
        friendlyName ?? (model.isEmpty ? "小米音箱" : model)
    }
}
