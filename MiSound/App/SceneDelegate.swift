import UIKit

/// 场景代理：纯代码构建根视图控制器（无 Storyboard）
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootTabController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // 回到前台时刷新设备列表
        Task {
            await DeviceManager.shared.discover(scanSubnet: false)
        }
    }
}

/// 根 Tab 控制器（对应 Android 版主界面三大入口：主页 / 设备 / 设置）
final class RootTabController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let mainPage = UINavigationController(rootViewController: MainPageViewController())
        mainPage.tabBarItem = UITabBarItem(title: "主页",
                                           image: UIImage(systemName: "house"),
                                           selectedImage: UIImage(systemName: "house.fill"))

        let devices = UINavigationController(rootViewController: DeviceListViewController())
        devices.tabBarItem = UITabBarItem(title: "设备",
                                          image: UIImage(systemName: "hifispeaker"),
                                          selectedImage: UIImage(systemName: "hifispeaker.fill"))

        let settings = UINavigationController(rootViewController: SettingsViewController())
        settings.tabBarItem = UITabBarItem(title: "设置",
                                           image: UIImage(systemName: "gearshape"),
                                           selectedImage: UIImage(systemName: "gearshape.fill"))

        viewControllers = [mainPage, devices, settings]
    }
}
