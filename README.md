# 小米音箱 iOS 版（逆向重开发工程）

> 基于 Android 版「小米音响 v1.3.2 永不升级版」（`com.mi.umi.controlpoint`，APK 6.36MB）
> 反编译结果，在 Swift/UIKit 中重写的 iOS 16 兼容工程。
> **本工程与小米官方无关**，为个人逆向研究产物，仅用于已拥有设备的局域网控制。

## 一、协议移植依据（来自反编译）

| 模块 | Android 源（反编译） | iOS 实现 |
|---|---|---|
| 设备发现 | `DeviceDiscoveryHelper`：SSDP 组播 239.255.255.250:1900，ST=`urn:schemas-upnp-org:device:UmiSystem:1`；网段扫 `http://IP:9999/` | `DeviceDiscoveryService.swift` |
| 设备信息 | `http://IP:9999/<uuid>/Upnp/device.xml` | `DeviceDiscoveryService.fetchDeviceInfo`（XMLParser） |
| 日常控制 | ohNet UPnP 栈（libohNet.so / libohNetJni.so），SOAP POST 到 controlURL | `UPnPControlService.swift`（AVTransport / RenderingControl 标准动作） |
| 局域网协议 | `MiioLocalAPI` + `JNIBridge`（libmiio.so / libencryptor.so），UDP 54321 | `MiioLocalService.swift` + `MiioCrypto.swift`（Xiaomi IoT 公开协议：magic 0x2131、AES-128-CBC、key=MD5(token)、md5 校验） |
| 配网 | `b/b/b.java` 状态机：SSDP 发现 → `miIO.config_router` RPC（含 uid/gmt_offset） | `WifiConfigViewController.swift`（免账号：本地握手取 token） |
| 频道 / 播放列表 | `source/cp/a.java`：`http://soundbar.pandora.xiaomi.com/upgrade/default_playlist` + 音源常量表 | `ContentService.swift`（拉取并渲染） |
| 锁屏控件 | `LockScreenActivity` | `NowPlayingController.swift`（MPNowPlayingInfoCenter + MPRemoteCommandCenter） |
| 数据模型 | `data/aidl/*.java`（PlayState、PlayingAudioInfo、SoundDevice 等） | `Models/*.swift`（按协议语义重建） |

### 关键协议常量（已从 APK 提取）

```
SSDP 组播:    239.255.255.250:1900
设备 HTTP:    http://<ip>:9999/<uuid>/Upnp/device.xml
MiIO UDP:     54321
MiIO 握手:    FULL_TOKEN = 32×'f'，报文 = header(32B) + token(32B)
探活组播:     224.126.{m}.{n}:5007，内容 "miio"
配网 RPC:     {"id":<ts>,"method":"miIO.config_router","params":{"ssid":...,"passwd":...,"uid":...,"gmt_offset":...}}
M-SEARCH:     M-SEARCH * HTTP/1.1\r\nST: urn:schemas-upnp-org:device:UmiSystem:1\r\nMX: 1\r\nMAN: "ssdp:discover"\r\nHOST: 239.255.255.250:1900\r\n\r\n
```

## 二、工程结构

```
MiSound-iOS/
├── MiSound.xcodeproj/          # Xcode 工程（objectVersion 60，iOS 16.0 起）
└── MiSound/
    ├── App/                    # AppDelegate / SceneDelegate / Info.plist
    ├── Models/                 # SoundDevice、PlaybackState、ContentModels（频道/闹钟/音效）
    ├── Services/               # 协议层与业务编排
    │   ├── MiioCrypto.swift            # MiIO 报文加解密（AES-128-CBC + MD5）
    │   ├── MiioLocalService.swift      # MiIO UDP RPC / 握手 / token 获取
    │   ├── DeviceDiscoveryService.swift# SSDP 发现 / 网段扫描 / device.xml
    │   ├── UPnPControlService.swift    # SOAP 播放/音量/进度控制
    │   ├── ContentService.swift        # 频道列表（pandora 接口）+ 音源常量表
    │   ├── DeviceFeatureService.swift  # 闹钟/音效/收藏/播放列表（UPnP 自定义动作，可校准）
    │   ├── DeviceManager.swift         # 编排：发现/连接/轮询/控制
    │   └── NowPlayingController.swift  # 锁屏与控制中心
    ├── Views/                   # 播放控制条、设备单元格
    └── ViewControllers/         # 主页（频道）/ 设备 / 播放器 / 设置 / 配网 / 闹钟 / 音效
```

## 三、直接生成 IPA（巨魔 TrollStore 免签名安装，Windows 可用）

**不用 Mac、不用终端、不用开发者账号**。工程已内置 GitHub Actions 自动编译脚本
（`.github/workflows/build-ipa.yml`），用 GitHub 官方的免费云端 Mac 编译出**未签名 IPA**。

操作步骤（全程网页操作）：

1. 打开 https://github.com 注册/登录（免费）。
2. 点右上角 `+` → **New repository**，仓库名随便（如 `misound-ios`），选 **Public**（公共仓库才免费），
   不要勾选任何初始化选项（不要 README / .gitignore），点 **Create repository**。
3. 进入仓库后点 **uploading an existing file**（或直接拖拽上传），把 `MiSound-iOS` 文件夹里
   **所有内容**上传（MiSound.xcodeproj 整个文件夹、MiSound 整个文件夹、.github 整个文件夹、
   README.md），点 **Commit changes**。
   > `.github` 是隐藏文件夹：网页上传时直接拖入即可，GitHub 会自动识别。
4. 上传完成自动触发编译。打开仓库的 **Actions** 标签页，能看到 `Build IPA (TrollStore / 未签名)`
   正在运行（约 3~5 分钟）。
5. 运行完成后点击该次运行 → 底部 **Artifacts** → 下载 `MiSound-TrollStore-ipa`（zip，内含
   `MiSound-TrollStore.ipa`）。
6. 把 IPA 传到手机（AirDrop / 网盘 / 数据线），用 **巨魔 TrollStore** 打开安装即可。
   未签名 + arm64 架构，TrollStore 可直接安装运行。

> 想重新触发编译：仓库 Actions 页 → 左侧选中该 workflow → 右侧 **Run workflow** 按钮。
> 之后修改了源码再 push，也会自动重新编译。

### 本地编译（需要 Mac，可选）

如果之后有 Mac，也可本地编译：

1. 安装 **Xcode 15+**（App Store 免费）。
2. 双击 `MiSound.xcodeproj` 打开。
3. 在 **Signing & Capabilities** 中选择你的 Apple 开发团队（免费 Apple ID 账号即可用于真机调试；若要发布/长期签名需要 Apple Developer Program，$99/年）。
4. 连接一台 iOS 16+ 设备，选择设备后 ⌘R 运行。
5. 首次运行会弹「允许本地网络访问」授权，请允许。

> 未登录 Apple 开发者账号时，Xcode 会因签名失败报错——本地调试需选择免费开发团队；
> 若只需要巨魔安装，请用上方「三、直接生成 IPA」的云编译方案，无需任何签名。

## 四、使用说明

1. **设备页**：点击右上角搜索图标 → SSDP 搜索 + 局域网扫描，找到你的小米音箱后点击连接。
2. **主页**：连接成功后自动拉取频道列表（小米内容服务 pandora 接口，含各音源入口）并开始轮询播放状态；点击频道直接播放；底部控制条可播放/暂停/切歌/调音量；点击曲名打开全屏播放器（可拖拽进度 Seek）。
3. **锁屏**：应用在前台或后台运行时，锁屏与控制中心会出现播放控件。
4. **设置 → 闹钟**：新增 / 开关 / 删除闹钟（协议动作名见「六」第 3 条）。
5. **设置 → 音效**：切换音效模式（协议动作名见「六」第 3 条）。
6. **设置 → 网络诊断**：一键验证 HTTP/MiIO/UPnP 三条通道。
7. **设置 → 配网**：无需小米账号，按向导为音箱配置新 WiFi（本地握手取 token）。

## 五、功能支持矩阵

| 功能 | 状态 | 说明 |
|---|---|---|
| 设备发现（SSDP + 扫描） | ✅ 已实现 | |
| 播放 / 暂停 / 上一首 / 下一首 | ✅ 已实现 | UPnP AVTransport |
| 音量控制 / 静音 | ✅ 已实现 | UPnP RenderingControl |
| 播放进度轮询 / Seek | ✅ 已实现 | |
| 锁屏播放控件 | ✅ 已实现 | |
| 配网（config_router） | ✅ 已实现（免账号） | 本地握手取 token，见「六」第 2 条 |
| 频道列表 | ✅ 已实现 | 拉取 pandora 云端接口（`ContentService`），点击即播放；接口不可达时回退展示音源入口 |
| 闹钟 | ✅ 已实现（UI + 协议层） | 新增/开关/删除；UPnP 动作名需真机校准（见「六」第 3 条） |
| 音效 | ✅ 已实现（UI + 协议层） | 切换音效；UPnP 动作名需真机校准（见「六」第 3 条） |
| 播放列表 / 收藏 | 🔧 协议层已封装 | `DeviceFeatureService` 已提供 Get/Add 动作封装，UI 待动作名确认后接入 |
| 语音 | 🔧 待实现 | 语音识别在设备固件侧，原版 App 的语音页为状态展示；iOS 暂未提供语音入口 |

## 六、已知限制（务必阅读）

1. **APK 无法直接转 IPA**：Android 原生组件（Activity、广播、悬浮窗、WiFi 切换 API）
   在 iOS 上无对应物，本工程是按逆向协议**重新开发**的 iOS 原生 App。
   Windows 上无 iOS 编译工具，但可用工程自带的 GitHub Actions 云编译产出未签名 IPA（见「三」）。
2. **设备 token 获取（无需小米账号）**：老版音箱固件（本 App 对应年代）支持本地握手取
   token——用 32×'f' 全 token 发 hello 包，设备直接返回真实 token（`MiioLocalService.getToken`，
   与安卓 App 免登录配网行为一致）。配网与日常控制均走此路径，不需要米家账号。
   > 若个别设备固件已加固、拒绝全 f 握手（新固件才出现），可改为从米家 App 或抓包
   > 获取 token 填入配网页（页面仍保留 UID 选填项）。
3. **控制动作名校准**：闹钟/音效/收藏/播放列表由音箱固件的自定义 UPnP 服务提供（Java 层经
   ohNet JNI 动态构造，反编译不可见）。本工程按小米音箱常见动作名实现
   （GetAlarms/SetAlarm/DeleteAlarm、GetSoundEffects/SetSoundEffect、GetFavorites/AddToFavorites、
   GetPlaylists），并通过 `DeviceFeatureService.actionOverrides` 提供校准入口：用 Wireshark 抓取
   原版 App 的 SOAP 请求后，把实际动作名/服务 URN 填入即可，无需改 UI。
4. **配网操作**：iOS 无法像 Android 那样自动切换 WiFi，连接音箱热点需用户手动在
   系统设置中操作（配网页内有步骤提示）；App 自动从路由表定位音箱（热点网关）并
   完成握手与 `miIO.config_router` 下发。
5. **内容源可用性**：部分音源（虾米/贝瓦/凤凰等）已停止服务或接口变更，频道接口
   返回可能为空——App 会回退展示音源入口列表，不影响本机控制功能。

## 七、验证方式

- 本工程在 Windows 环境下编写，未在 Xcode 中实机编译（Windows 无法运行 Xcode）。
- 建议在 Mac 上打开后先 ⌘B 编译，按 Xcode 报错逐个修复（预期无逻辑性错误，
  可能的告警来自 Apple 签名/开发者账号配置）。
- 真机调试时先在「设置 → 网络诊断」确认三条协议通道均 ✓，再使用播放控制。

---
*工程生成日期：2026-10-22。源码反编译产物见同级目录「小米音响-反编译源码」。*
