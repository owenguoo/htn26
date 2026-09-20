import SwiftUI
import SwarmCore

struct RootView: View {
    @State private var model = OperatorViewModel()
    @State private var hub = ""
    @State private var name = PhoneIdentity.name
    @State private var error: String?
    @State private var isJoining = false
    /// The gear in the camera chrome opens this. The Expo shell pushes its own
    /// `/settings` route instead; this target had no way in at all, which left
    /// the operator with no recalibrate, no toggles and no way out but the
    /// app switcher.
    @State private var isShowingSettings = false
    @State private var showDebug = false
    @State private var showMiniMap = true

    /// The operator screen is worth showing.
    ///
    /// **Not `model.isJoined`.** The runtime publishes the session *before* it
    /// starts ARKit and hands the preview its scene view — `SwarmRuntime.join`
    /// only returns once all of that is done — so switching on `isJoined` put a
    /// black "waiting for the camera…" screen in between the join spinner and
    /// the camera. One tap, three pictures. `isJoining` is only false once the
    /// join task has finished, so the form and its spinner hold the screen
    /// until there is a camera to hand it to. A session that arrives some other
    /// way (a deep link, a re-join) has no join task and shows immediately.
    private var showsOperator: Bool { model.isJoined && !isJoining }

    var body: some View {
        Group {
            if showsOperator {
                OperatorView(model: model, showDebug: showDebug, showMiniMap: showMiniMap,
                             onRequestSettings: { isShowingSettings = true })
                    .transition(.opacity)
            } else {
                joinForm
                    .transition(.opacity)
            }
        }
        // One continuous hand-over rather than a hard swap: the form and the
        // camera are very different pictures, and cutting between them read as
        // another loading step.
        .animation(.easeInOut(duration: 0.25), value: showsOperator)
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheet(model: model, showDebug: $showDebug, showMiniMap: $showMiniMap,
                          onLeave: leave)
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
                        HStack(spacing: Space.s) {
                            Spacer()
                            if isJoining {
                                // **`.small`, explicitly.** A `ProgressView` in
                                // this label inherits the button's `.large`
                                // control size and comes out twice the height
                                // of the words next to it.
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            // **One `Text` whose string changes**, not two
                            // views swapping places. Swapped, they are two
                            // identities, and the ambient animation cross-fades
                            // them — "Join" and "Joining…" printed over each
                            // other with the spinner on top.
                            Text(isJoining ? "Joining…" : "Join")
                                .font(TypeScale.action)
                                // Said outright, because a *disabled* prominent
                                // button greys its own label — which is what
                                // turned "Joining…" into small grey text on
                                // blue. This button is neither disabled nor
                                // re-tinted while it works (`join()` guards
                                // instead), and the label is as white as
                                // "Join" was.
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        // Belt and braces: whatever animation is running
                        // outside, the label never dissolves into itself.
                        .transaction { $0.animation = nil }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    // One tint, joining or not. Greying it while the hub call
                    // was in flight was meant to read as "busy", but grey is
                    // this app's colour for *unavailable*, and the one moment
                    // an operator is watching this screen to see whether
                    // anything is happening is the moment it went flat. The
                    // spinner and "Joining…" already say it is working.
                    .tint(Color.accentColor)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    // Only for an address that cannot be joined. Disabling it
                    // while joining as well is what handed the label to the
                    // system's disabled styling; `join()` ignores a second tap.
                    .disabled(HubURL.derive(hub) == nil)
                } footer: {
                }
            }
            .navigationTitle("Beacon")
        }
    }

    private func join() {
        guard !isJoining else { return }
        isJoining = true
        error = nil
        Task {
            do {
                // Returns with the socket up, ARKit running and the preview
                // attached — everything the operator screen needs to open on a
                // picture rather than on a placeholder.
                try await SwarmRuntime.shared.join(hub: hub, name: name)
            } catch {
                self.error = error.localizedDescription
            }
            isJoining = false
        }
    }

    private func leave() {
        isShowingSettings = false
        Task { await SwarmRuntime.shared.leave() }
    }
}
