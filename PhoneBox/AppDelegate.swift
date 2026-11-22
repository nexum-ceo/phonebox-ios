import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var panel: PanelViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let panel = PanelViewController()
        window.rootViewController = panel
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window
        self.panel = panel
        // a pairing link that started the app (the camera app, the "Open in PhoneBox" button)
        if let url = connectionOptions.urlContexts.first?.url { DispatchQueue.main.async { panel.handlePairingURL(url) } }
    }

    /// Pairing without USB: phonebox://pair?v=1&... from the QR code's page.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { panel?.handlePairingURL(url) }
    }

    /// Also the QR code's own https link, when the camera app hands it over as a web link.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let url = userActivity.webpageURL { panel?.handlePairingURL(url) }
    }
}
