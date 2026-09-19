import UIKit

/// System / Light / Dark, applied to every window.
///
/// The window, and not React Native's `Appearance.setColorScheme`: that one
/// only writes a JS-side string and never touches `UITraitCollection`, so
/// `PlatformColor`, every `@expo/ui` SwiftUI view and the whole operator screen
/// would keep the system appearance while `useColorScheme()` claimed otherwise.
/// `overrideUserInterfaceStyle` propagates the other way — UIKit re-resolves
/// every dynamic colour, and React Native's own trait observer forwards the
/// change back into JS, so the JS theme follows for free. One source of truth,
/// one direction.
///
/// The stored default is `dark`, not `system`: this app is held up in a dark
/// room, over a camera feed. `app.json` stays `"userInterfaceStyle": "automatic"`
/// so that light mode is *reachable* — pinning it to `"dark"` there writes
/// `UIUserInterfaceStyle = Dark` into the plist and locks the whole app.
@MainActor
enum ThemeController {
    nonisolated static let defaultsKey = "SwarmSightTheme"

    /// UserDefaults is thread-safe and this is read from `getConfig`, which
    /// Expo may call off the main thread.
    nonisolated static var stored: String {
        normalise(UserDefaults.standard.string(forKey: defaultsKey))
    }

    nonisolated static func store(_ theme: String) {
        UserDefaults.standard.set(normalise(theme), forKey: defaultsKey)
    }

    /// Unknown strings fall back rather than throwing: a JS typo should leave
    /// the app dark and usable, not unstyled.
    nonisolated static func normalise(_ theme: String?) -> String {
        switch theme {
        case "system", "light", "dark": theme ?? "dark"
        default: "dark"
        }
    }

    /// Applies whatever is stored. Safe to call before any window exists —
    /// `followNewWindows()` catches the ones that arrive later.
    static func applyStored() {
        apply(stored)
    }

    static func apply(_ theme: String) {
        let style = style(for: theme)
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }

    /// The module is created before the React root window is, so a single
    /// `apply` at launch would style nothing and the first frame would be the
    /// system appearance — a white flash on a dark-mode-by-default app. Every
    /// window that becomes visible afterwards gets the stored style too.
    static func followNewWindows() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main
        ) { _ in
            // Posted on the main queue, so the isolation is real. Re-styling
            // every window is cheaper than reading the notification's payload,
            // which is not `Sendable`.
            MainActor.assumeIsolated { applyStored() }
        }
    }

    private static var observer: (any NSObjectProtocol)?

    private static func style(for theme: String) -> UIUserInterfaceStyle {
        switch normalise(theme) {
        case "light": .light
        case "dark": .dark
        default: .unspecified
        }
    }
}
