import SwiftUI
import SwarmCore

@main
struct SwarmSightApp: App {
    @State private var launch = LaunchState()

    var body: some Scene {
        WindowGroup {
            RootView(launch: launch)
                // The overlay is the whole interface: an operator holds the
                // phone up and sweeps. Nothing here should ever be read at arm's
                // length in a dark room.
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}

/// `venue.json` is loaded at runtime, so a failure to load it is a screen, not a
/// crash. Changing venue must need no rebuild, which means a mistyped venue file
/// has to be legible on the device in the lobby.
@Observable
final class LaunchState {
    enum Phase {
        case loading
        case ready(AppCoordinator)
        case failed(String)
    }

    private(set) var phase: Phase = .loading

    @MainActor
    func load(fallbackOrchestrator: URL) {
        do {
            let venue = try AppCoordinator.loadVenue()
            // The venue file wins: on the day the orchestrator's address is
            // whatever the laptop's turns out to be, and that must not mean a
            // rebuild.
            let orchestrator = venue.orchestratorURL
                .flatMap { URL(string: $0) }
                .flatMap { $0.scheme != nil ? $0 : nil }
                ?? fallbackOrchestrator
            phase = .ready(AppCoordinator(venue: venue, orchestrator: orchestrator))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
