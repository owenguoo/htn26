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
    @State private var isScanning = false
    @State private var showMiniMap = true
    @FocusState private var focus: JoinField?

    private enum JoinField { case name, hub }

    /// The name, and the hidden copy that measures it — one font, so the rule
    /// under the name cannot drift from the name. It was 52pt bold, which made
    /// the operator's name the loudest thing in the app; a large title in
    /// semibold still leads the page without shouting it, and follows the
    /// text-size setting, which a fixed 52 did not.
    private static let nameFont = Font.largeTitle.weight(.semibold)

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
                OperatorView(model: model, showMiniMap: showMiniMap,
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
        .sheet(isPresented: $isScanning) {
            QRScannerView { hub = $0 }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsSheet(model: model, showMiniMap: $showMiniMap, onLeave: leave)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No `.background(.black)`: the join screen brings the console's `--bg`,
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

    /// The first screen of the same product as the operator console, so it is
    /// drawn in the console's colours — `--bg`, `--fg`, `--accent` — on a
    /// phone's shapes: one large line, one soft card, one pill.
    ///
    /// Not a `Form`. A grouped form is the right container for settings, and
    /// made this screen look like Settings. There are two things to say here —
    /// who you are and which hub — and one thing to do.
    private var joinForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.xs) {
                // The console's own mark (`web/beacon_logo.png`, copied into
                // the asset catalog), at the size its header draws it.
                Image("BeaconLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    // The splash lands its cube on this one, by measurement.
                    .splashTarget()
                    .accessibilityHidden(true)
                Text("beacon")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(ConsoleInk.fg)
            }
            .padding(.top, Space.l)

            Spacer(minLength: Space.xxl)

            // Not monospaced. The mono face belongs to the things that are
            // literally machine text on this page — the hub address — and using
            // it for a label made an ordinary English word look like a field
            // name in a config file.
            Text("Joining as")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ConsoleInk.fg3)
            // The name *is* the headline, and the headline is the field: there
            // is no second place to go and edit it. **No `.textContentType`**,
            // here or on the hub — a content type puts the field in the
            // system's AutoFill group, and focusing it makes the keyboard
            // round-trip to the AutoFill services before it accepts a
            // keystroke.
            //
            // Which is only true if it *looks* like a field. A large line
            // reads as a title, and nobody taps a title: so it sits on a rule,
            // the way a line you write on does.
            //
            // The rule is as long as the name, not the screen. A full-width
            // rule under a short name underlines the emptiness beside it; one
            // that ends where the name ends belongs to the name. It is drawn
            // under a hidden copy of the text, because a `TextField` is as wide
            // as it is offered and only a `Text` knows how wide its words are.
            // With no name yet it measures the prompt instead — the rule is
            // then exactly the blank that "Your name" is asking to be filled.
            ZStack(alignment: .leading) {
                Text(name.isEmpty ? "Your name" : name)
                    .font(Self.nameFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .hidden()
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(focus == .name ? ConsoleInk.fg : ConsoleInk.line2)
                            .frame(height: 1.5)
                            .offset(y: Space.xs)
                    }
                    .accessibilityHidden(true)
                TextField("", text: $name, prompt: Text("Your name").foregroundStyle(ConsoleInk.line2))
                    .font(Self.nameFont)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(ConsoleInk.fg)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focus, equals: .name)
            }
            .padding(.top, Space.xs)
            .padding(.bottom, Space.s)
            .animation(Motion.lift, value: focus)
            .animation(Motion.settle, value: name)

            hubCard
                .padding(.top, Space.xxl)

            if let error {
                // Failures are read by a person standing in a room with a
                // phone, not by a developer reading a console.
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeScale.footnote)
                    .foregroundStyle(ConsoleInk.red)
                    // An address someone will want to retype or copy.
                    .textSelection(.enabled)
                    .padding(.top, Space.m)
                    .padding(.horizontal, Space.xs)
            }

            Spacer(minLength: Space.xxl)
            Spacer(minLength: 0)

            joinButton
                .padding(.bottom, Space.l)
        }
        .padding(.horizontal, Space.xl + Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            // `#mapWrap`'s own wash, so the page has the console map's light
            // in it rather than being a flat fill.
            RadialGradient(colors: [MapInk.backdropCentre, ConsoleInk.bg, ConsoleInk.bg1],
                           center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 620)
                .ignoresSafeArea()
                .onTapGesture { focus = nil }
        }
        .tint(ConsoleInk.accent)
    }

    /// The address, and the two ways to put one in it.
    ///
    /// It used to lead with a radio-tower glyph in a circle, which took the
    /// first forty points of the row to say "this row is about the hub" — a
    /// thing the word Hub, directly beside it, was already saying. The row is
    /// now the label, the field, and the one action that is not typing.
    private var hubCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Link")
                .font(TypeScale.hint)
                .foregroundStyle(ConsoleInk.fg3)
            // In a well of its own. Loose on the card it was a line of grey
            // type that happened to be editable; inset, bordered and with a
            // clear button, it is the shape every text field on the phone has.
            HStack(spacing: Space.s) {
                TextField("", text: $hub,
                          prompt: Text("http://10.0.0.5:8000/").foregroundStyle(ConsoleInk.line2))
                    .font(.callout.monospaced())
                    .foregroundStyle(ConsoleInk.fg)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.join)
                    .onSubmit(join)
                    .focused($focus, equals: .hub)
                if focus == .hub, !hub.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { hub = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(ConsoleInk.line2)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Space.m)
            .frame(minHeight: HitTarget.minimum)
            .background(ConsoleInk.bg1, in: Radius.rect(Radius.card))
            .overlay(Radius.rect(Radius.card)
                // Ink, not the accent, while the cursor is in it: green is
                // this app's colour for the search and the people on it, and a
                // text field being typed in is neither.
                .stroke(focus == .hub ? ConsoleInk.fg2 : ConsoleInk.line,
                        lineWidth: focus == .hub ? 1.5 : 1))
            // The whole well focuses the field, not just the glyphs in it.
            .contentShape(Radius.rect(Radius.card))
            .onTapGesture { focus = .hub }
            .animation(Motion.lift, value: focus)
            // The console has had a Join QR button all along and the phone had
            // no way to read it, so the address got typed on a phone keyboard
            // in a dark room with the search waiting. Full width, because it is
            // the way this field is meant to be filled and typing is the
            // fallback.
            Button {
                focus = nil
                isScanning = true
            } label: {
                Label("Scan the QR code", systemImage: "qrcode.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.plain)
            .foregroundStyle(ConsoleInk.accent)
            .background(ConsoleInk.bg2, in: Radius.rect(Radius.card))
            .padding(.top, Space.xs)
        }
        .padding(Space.l)
        .background(ConsoleInk.surface, in: Radius.rect(Radius.sheet))
        .overlay(Radius.rect(Radius.sheet).stroke(ConsoleInk.line, lineWidth: 1))
    }

    private var joinButton: some View {
        Button(action: join) {
            HStack(spacing: Space.s) {
                if isJoining {
                    ProgressView()
                        .controlSize(.small)
                        .tint(ConsoleInk.bg)
                }
                // **One `Text` whose string changes**, not two views swapping
                // places. Swapped, they are two identities, and the ambient
                // animation cross-fades them — "Join" and "Joining…" printed
                // over each other with the spinner on top.
                Text(isJoining ? "Joining…" : "Join search")
                    .font(.headline)
            }
            // Whatever animation is running outside, the label never
            // dissolves into itself.
            .transaction { $0.animation = nil }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
        }
        .buttonStyle(JoinPillStyle())
        // Only for an address that cannot be joined. Not while joining:
        // `join()` ignores a second tap, and a pill that went grey at the one
        // moment the operator is watching it reads as the app giving up.
        .disabled(HubURL.derive(hub) == nil)
    }

    private func join() {
        guard !isJoining else { return }
        focus = nil
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

/// The one primary action: the console's `--fg` as a full-width pill, with the
/// small give under the thumb that a flat fill otherwise lacks.
private struct JoinPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ConsoleInk.bg)
            // A hairline, not a drop shadow. The console is a flat surface and
            // the phone's first screen is drawn in its colours; a pill floating
            // above the page was the one thing on it pretending to have depth.
            .background(ConsoleInk.fg.opacity(isEnabled ? 1 : 0.28),
                        in: Radius.rect(Radius.pill))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.lift, value: configuration.isPressed)
    }
}
