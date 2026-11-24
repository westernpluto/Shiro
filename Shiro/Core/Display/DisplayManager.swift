import UIKit
import Combine

/// Tracks the external display (USB-C / AirPlay) and HDR capability, and
/// decides which surface hosts the live video.
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published private(set) var externalScene: UIWindowScene?
    @Published private(set) var externalName: String?
    @Published private(set) var externalSize: CGSize = .zero

    var hasExternalDisplay: Bool { externalScene != nil }

    /// True when the stream should be shown on the external display and the
    /// phone should act as a companion controller.
    var routesVideoExternally: Bool {
        hasExternalDisplay && AppSettings.shared.useExternalDisplay
    }

    var anyDisplaySupportsHDR: Bool {
        let screens = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }
        if screens.contains(where: { $0.potentialEDRHeadroom > 1.0 }) { return true }
        return false
    }

    var maxRefreshRate: Int {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.maximumFramesPerSecond }.max() ?? 60
    }

    func externalConnected(_ scene: UIWindowScene) {
        externalScene = scene
        externalSize = scene.screen.bounds.size
        externalName = "External display"
        ShiroLog.shared.info("External display connected: \(Int(scene.screen.nativeBounds.width))x\(Int(scene.screen.nativeBounds.height)) @\(scene.screen.maximumFramesPerSecond) Hz, EDR headroom \(scene.screen.potentialEDRHeadroom)")
    }

    func externalDisconnected(_ scene: UIWindowScene) {
        guard externalScene === scene else { return }
        externalScene = nil
        externalName = nil
        externalSize = .zero
        ShiroLog.shared.info("External display disconnected")
    }
}
