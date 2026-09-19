import SwiftUI
import SwarmCore

/// The plain-Swift shell: a join form and the operator view. The Expo app in
/// `mobile/` hosts the same `OperatorView` and replaces this shell; until that
/// is at parity this target is how the client gets onto a phone.
@main
struct SwarmSightApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // The overlay is the whole interface: an operator holds the
                // phone up and sweeps. Nothing here should ever be read at arm's
                // length in a dark room.
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
