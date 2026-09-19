import SwiftUI
import SwarmCore

/// The plain-Swift shell: a join form and the operator view. The Expo app in
/// `mobile/` hosts the same `OperatorView` and replaces this shell; until that
/// is at parity this target is how the client gets onto a phone.
@main
struct BeaconApp: App {
    var body: some Scene {
        WindowGroup {
            // No `.preferredColorScheme(.dark)`. The operator screen is dark
            // because it is drawn over a camera feed and says so itself, with
            // `.cameraChrome()`; pinning the whole window also pinned the join
            // form, which is an ordinary iOS form and should follow the phone.
            // Status bar likewise: hidden over the camera, present over a form.
            RootView()
        }
    }
}
