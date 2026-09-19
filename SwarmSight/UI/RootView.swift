import SwiftUI
import SwarmCore

struct RootView: View {
    @Bindable var launch: LaunchState
    @AppStorage("orchestratorURL") private var orchestratorURL = "ws://192.168.1.10:8765/device"

    var body: some View {
        Group {
            switch launch.phase {
            case .loading:
                ProgressView("Loading venue…")
                    .task { launch.load(orchestrator: resolvedURL) }
            case .ready(let coordinator):
                OverlayView(coordinator: coordinator)
                    .task { await coordinator.start() }
            case .failed(let message):
                FailureView(message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    /// A mistyped orchestrator URL in the preference falls back to localhost
    /// rather than trapping. `URL(string:)` on a literal is the classic "this
    /// can never be nil" force unwrap, and it is still a crash on stage if
    /// somebody edits the literal.
    private var resolvedURL: URL {
        if let parsed = URL(string: orchestratorURL), parsed.scheme != nil {
            return parsed
        }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = 8765
        components.path = "/device"
        return components.url ?? URL(fileURLWithPath: "/")
    }
}

/// Failures are read by a person standing in a room with a phone, not by a
/// developer reading a console.
struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text("Cannot start")
                .font(.title2.bold())
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}
