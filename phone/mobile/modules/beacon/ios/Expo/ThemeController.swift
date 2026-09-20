import UIKit

/// Light, always.
///
/// `app.json` pins `"userInterfaceStyle": "light"`, which writes
/// `UIUserInterfaceStyle = Light` into the plist. That alone is enough once the
/// window exists. This controller still paints every window at module create
/// and again as new ones appear, so the first frame is never the system dark
/// appearance while the root window is still coming up.
@MainActor
enum ThemeController {
    /// Safe to call before any window exists — `followNewWindows()` catches the
    /// ones that arrive later.
    static func applyLight() {
        applied = .light
        paint()
    }

    /// The module is created before the React root window is, so a single
    /// `apply` at launch would style nothing and the first frame would flash
    /// dark. Every window that becomes visible afterwards gets light too.
    static func followNewWindows() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main
        ) { _ in
            // `queue: .main` is the main *dispatch* queue, not Swift's
            // MainActor executor — `assumeIsolated` can trap here. Hop instead.
            Task { @MainActor in paint() }
        }
    }

    private static func paint() {
        guard let applied else { return }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = applied }
        }
    }

    private static var applied: UIUserInterfaceStyle?
    private static var observer: (any NSObjectProtocol)?
}
