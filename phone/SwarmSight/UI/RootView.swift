import SwiftUI
import SwarmCore

struct RootView: View {
    @State private var model = OperatorViewModel()
    @State private var hub = ""
    @State private var name = PhoneIdentity.name
    @State private var error: String?
    @State private var isJoining = false

    var body: some View {
        Group {
            if model.isJoined {
                OperatorView(model: model, onRequestLeave: { Task { await SwarmRuntime.shared.leave() } })
            } else {
                joinForm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .onAppear {
            model.attach()
            if hub.isEmpty { hub = PhoneIdentity.lastHubURL.isEmpty ? venueHub : PhoneIdentity.lastHubURL }
            // `simctl launch … -SwarmSightJoin <link>`: iOS puts a confirmation
            // in front of `simctl openurl` that nothing headless can tap.
            if let link = UserDefaults.standard.string(forKey: "SwarmSightJoin"),
               let url = URL(string: link), !model.isJoined {
                open(url)
            }
        }
        .onOpenURL { open($0) }
    }

    private func open(_ url: URL) {
        // swarmsight://join?hub=… from the dashboard QR prefills the form.
        guard HubURL.derive(url.absoluteString) != nil else { return }
        hub = url.absoluteString
        // `&replay=1` is the test hook: replay a recorded walk instead of ARKit
        // and join without a tap. `&markers=0` strips sightings, for the seat
        // fallback.
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.contains(where: { $0.name == "replay" && $0.value == "1" }) else { return }
        let markers = !items.contains { $0.name == "markers" && $0.value == "0" }
        SwarmRuntime.shared.configure(RuntimeOptions(poseSource: .replay, replayMarkers: markers))
        if name.isEmpty { name = "sim" }
        join()
    }

    /// `venue.json` is the day-of authority for where the hub is.
    private var venueHub: String {
        (try? ModuleResources.loadVenue())?.hubURL ?? ""
    }

    private var joinForm: some View {
        Form {
            Section("Hub") {
                TextField("http://10.0.0.5:8000/", text: $hub)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Your name", text: $name)
            }
            if let error {
                // Failures are read by a person standing in a room with a phone,
                // not by a developer reading a console.
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
            }
            Section {
                Button(isJoining ? "Joining…" : "Join") { join() }
                    .disabled(isJoining || HubURL.derive(hub) == nil)
            } footer: {
                Text("The address on the dashboard's QR code. Phone ID \(PhoneIdentity.phoneId.prefix(8)).")
            }
        }
    }

    private func join() {
        isJoining = true
        error = nil
        Task {
            do {
                try await SwarmRuntime.shared.join(hub: hub, name: name)
            } catch {
                self.error = error.localizedDescription
            }
            isJoining = false
        }
    }
}
