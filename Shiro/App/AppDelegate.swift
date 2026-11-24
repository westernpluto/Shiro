import UIKit
import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // chiaki-ng's libcurl uses OpenSSL, which has no access to the iOS trust
        // store; point it at the bundled Mozilla CA bundle (used for PSN only).
        if let ca = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            setenv("SSL_CERT_FILE", ca, 1)
            setenv("CURL_CA_BUNDLE", ca, 1)
        }
        signal(SIGPIPE, SIG_IGN)
        ShiroLog.shared.info("Shiro \(Bundle.main.versionString) on iOS \(UIDevice.current.systemVersion)")
        ChiakiLib.initialize()
        _ = InputManager.shared
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
            config.delegateClass = ExternalDisplaySceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

/// Drives a second, non-interactive window on an external display. While a
/// stream is running the video moves here (full screen, HDR when the display
/// supports it) and the iPhone becomes a touchpad / controller companion.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let host = UIHostingController(rootView: ExternalDisplayView()
            .environmentObject(AppModel.shared)
            .environmentObject(AppSettings.shared)
            .environmentObject(DisplayManager.shared))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        DisplayManager.shared.externalConnected(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let ws = scene as? UIWindowScene { DisplayManager.shared.externalDisconnected(ws) }
        window = nil
    }
}
