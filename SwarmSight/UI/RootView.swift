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

    private var resolvedURL: URL {
        URL(string: orchestratorURL) ?? URL(string: "ws://127.0.0.1:8765/device")!
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
