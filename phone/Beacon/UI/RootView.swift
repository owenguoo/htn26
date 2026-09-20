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
                OperatorView(model: model)
            } else {
                joinForm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No `.background(.black)`: the `Form` brings `systemGroupedBackground`,
        // and the operator view brings its own camera-black.
        .statusBarHidden(model.isJoined)
        .onAppear {
            model.attach()
            if hub.isEmpty { hub = PhoneIdentity.lastHubURL.isEmpty ? venueHub : PhoneIdentity.lastHubURL }
            // `simctl launch … -BeaconJoin <link>`: iOS puts a confirmation
            // in front of `simctl openurl` that nothing headless can tap.
            if let link = UserDefaults.standard.string(forKey: "BeaconJoin"),
               let url = URL(string: link), !model.isJoined {
                open(url)
            }
        }
        .onOpenURL { open($0) }
    }

    private func open(_ url: URL) {
        // beacon://join?hub=… from the dashboard QR prefills the form.
        guard HubURL.derive(url.absoluteString) != nil else { return }
        hub = url.absoluteString
        // Two test hooks join without a tap. `&drive=1` is the interactive one:
        // drag to look, stick to walk, a synthetic room behind the HUD.
        // `&replay=1` replays a recorded walk and means exactly what it always
        // did, so existing `-BeaconJoin` recipes are untouched.
        // `&markers=0` strips sightings for the seat fallback, on both.
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func flag(_ name: String) -> Bool { items.contains { $0.name == name && $0.value == "1" } }
        let source: PoseSourceKind? = flag("drive") ? .drive : flag("replay") ? .replay : nil
        guard let source else { return }
        let markers = !items.contains { $0.name == "markers" && $0.value == "0" }
        // `configure` drops `.drive` off-simulator, so a link that reaches a
        // real phone joins with ARKit rather than a joystick.
        SwarmRuntime.shared.configure(RuntimeOptions(poseSource: source, replayMarkers: markers))
        if name.isEmpty { name = "sim" }
        join()
    }

    /// `venue.json` is the day-of authority for where the hub is.
    private var venueHub: String {
        (try? ModuleResources.loadVenue())?.hubURL ?? ""
    }

    private var joinForm: some View {
        NavigationStack {
            Form {
                Section("Hub") {
                    TextField("http://10.0.0.5:8000/", text: $hub)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                    TextField("Your name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                }
                if let error {
                    // Failures are read by a person standing in a room with a
                    // phone, not by a developer reading a console. Red, not
                    // yellow: yellow was chosen against a black background and
                    // is unreadable on white.
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.ssProblem)
                            // An address someone will want to retype or copy.
                            .textSelection(.enabled)
                    }
                }
                Section {
                    Button {
                        join()
                    } label: {
                        HStack {
                            Spacer()
                            if isJoining { ProgressView() } else { Text("Join") }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .disabled(isJoining || HubURL.derive(hub) == nil)
                } footer: {
                }
            }
            .navigationTitle("Beacon")
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
