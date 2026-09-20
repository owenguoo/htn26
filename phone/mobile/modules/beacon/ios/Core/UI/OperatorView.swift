import SwiftUI
import SwarmCore

/// The whole operator interface: camera, guidance, and whatever the hub says.
///
/// The HUD proper — compass tape, banner, toast, floating markers, detection
/// boxes — is drawn from `frame.hud`, the same value sent to the operator
/// console, so phone and console show the same thing. What is phone-only sits
/// around it: the status pill, the mini-map, the seat picker.
///
/// Everything it draws comes from `OverlayModel` in SwarmCore, so the decisions
/// — which way to point, when an arrow is stale, when to stop showing a flash —
/// are all tested. This file only turns that data into pixels.
public struct OperatorView: View {
    let model: OperatorViewModel
    var showDebug: Bool
    var showMiniMap: Bool
    var onRequestSettings: (() -> Void)?

    /// The full map, opened from the mini-map. While it is up the mini-map and
    /// the status pill stand down: a thumbnail of the map beside the map is the
    /// same picture twice, and the pill repeats what the card already says.
    @State private var isShowingMap = false

    /// Where the operator has parked the mini-map, as a displacement from its
    /// resting corner. `rest` is what a finished drag committed; `miniMapOffset`
    /// is that plus whatever the thumb is doing right now.
    @State private var miniMapOffset: CGSize = .zero
    @State private var miniMapRest: CGSize = .zero
    @State private var isDraggingMiniMap = false
    /// The mini-map's frame in `space`, and the screen it sits on. Together
    /// they give the genie its anchor — see `genieAnchor`.
    @State private var miniMapFrame: CGRect = .zero
    @State private var contentSize: CGSize = .zero

    /// The mini-map's own size, which the drag clamp and the genie anchor both
    /// have to agree with, so neither gets to write it down separately.
    private static let miniMapSize = CGSize(width: 132, height: 164)
    /// The layout area, named so the mini-map can be measured against it.
    private static let space = "operator"

    public init(model: OperatorViewModel, showDebug: Bool = false, showMiniMap: Bool = true,
                onRequestSettings: (() -> Void)? = nil) {
        self.model = model
        self.showDebug = showDebug
        self.showMiniMap = showMiniMap
        self.onRequestSettings = onRequestSettings
    }

    private var overlay: OverlayState { model.frame.overlay }

    /// A phase card is over the whole camera. It carries its own gear and its
    /// own words, so the status pill and the mini-map stand down underneath it
    /// rather than repeating them around the edges.
    private var phaseCardIsUp: Bool {
        guard !isShowingMap, let phase = overlay.phase else { return false }
        return PhaseCardText.covers(phase, alignment: overlay.alignment)
    }

    /// This phone has no lock and the operator is expected to do something
    /// about it — so the middle of the screen belongs to the viewfinder.
    ///
    /// Not while the map is up, and not in the lobby or after the search: in
    /// neither of those is anybody being asked to scan anything.
    private var isHuntingMarker: Bool {
        guard model.isJoined, !isShowingMap, overlay.alignment == .none else { return false }
        return overlay.phase != "lobby" && overlay.phase != "end"
    }

    /// Something is over the camera, so the chrome around the edges is noise
    /// rather than context.
    private var chromeIsHidden: Bool { isShowingMap || phaseCardIsUp }
    private var captureSize: CGSize {
        CGSize(width: model.frame.captureWidth, height: model.frame.captureHeight)
    }

    public var body: some View {
        ZStack {
            // The thing the overlay overlays. Without it the operator is aiming
            // a camera they cannot see through.
            if let preview = model.preview {
                CameraPreviewView(source: preview)
            } else if model.isDrive {
                // The Simulator, driving. A room that turns with the heading,
                // so the HUD can be judged over something that moves the way
                // the operator moved rather than over a flat gradient.
                DriveBackdropView(room: overlay.room, pose: overlay.roomPose,
                                  candidate: overlay.candidate)
            } else {
                ReplayBackdrop(isJoined: model.isJoined)
            }

            // Under everything interactive, on purpose: the chrome above claims
            // its own taps first, so the status pill, the mini-map, the gear and
            // the gear keep working while a drag anywhere else turns the camera.
            if model.isDrive {
                DriveLookLayer(model: model)
            }
            // Everything from here to `chrome` is drawn over a live video frame.

            if showDebug {
                // Off unless asked for in Settings: a calibration check, not
                // something to look through while searching.
                // Where the venue thinks the markers are. If these outlines sit
                // on the printed markers and stay there as you walk, calibration
                // is good; if they slide off, that is the drift.
                MarkerOverlayView(projections: model.frame.markerProjections, captureSize: captureSize)
            }

            // Boxes and floating diamonds, in frame coordinates — the same ones
            // the console draws over the feed. Skip AR diamonds in drive mode:
            // they are projected with fixture camera intrinsics, while the
            // backdrop places people with `RoomCamera`, so the diamond lands
            // metres away from the person. Distance rides on the person label.
            HUDFrameLayerView(hud: model.frame.hud, captureSize: captureSize,
                              showAR: !model.isDrive)

            // Always mounted so appear/disappear can ease rather than pop.
            // Underneath the edge band and the chrome: the wash is the mood of
            // the screen, not a thing on top of it.
            HUDAmbientView(ambient: model.frame.hud.ambient)
            HUDSoundEdgeView(edge: model.frame.hud.soundEdge)

            chrome

            // Over the chrome so a thumb on the puck is not competing with the
            // chrome's layout, and because the one control the operator has to
            // find should not be underneath anything.
            if model.isDrive, !isShowingMap {
                DriveStickView(model: model)
            }

            // The glance-speed form of the elevation half of the banner. Only
            // ever present when the operator is already on target horizontally,
            // so it never appears beside a turn instruction.
            if let elevation = overlay.elevation, !isShowingMap {
                ElevationCueView(cue: elevation)
            }

            // Somewhere to aim. Keyed off *this phone having no lock* rather
            // than off the hub's calibrate phase, because the other time the
            // operator has to find a marker is after a recalibrate or a lost
            // origin mid-search — when the hub is still saying "search" and no
            // card comes up at all.
            if isHuntingMarker {
                MarkerReticleView()
            }

            if phaseCardIsUp, let phase = overlay.phase {
                // Calibrate is the one card that asks the operator to *use* the
                // camera it is sitting on top of. Centred, it covered the exact
                // part of the frame they were being told to aim at — so while
                // the reticle is up the words go to the bottom and the
                // viewfinder gets the middle. Lobby and end ask for nothing and
                // keep the middle.
                VStack(spacing: 0) {
                    if isHuntingMarker { Spacer(minLength: 0) }
                    PhaseCardView(phase: phase, lookingFor: overlay.world?.lookingFor,
                                  again: overlay.isRecalibrating)
                }
                .padding(.bottom, isHuntingMarker ? Space.xxl : 0)
            }

            if isShowingMap, let room = overlay.room {
                // Tap anywhere off the card to put it away. The card itself is
                // the only thing in this frame that takes a touch, so this is
                // what a tap "outside the map" lands on.
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showMap(false) }
                    .transition(.opacity)
                RoomMapView(room: room, world: overlay.world, me: overlay.roomPose,
                            pings: overlay.pings, onClose: { showMap(false) })
                    // Full-bleed so the genie's anchor, which is a fraction of
                    // the screen, is a fraction of *this* view too. Sized to the
                    // card alone, the same anchor would land somewhere else.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(GenieTransition(anchor: genieAnchor))
            }

            // Over the chrome but under the flash: the plate hides the HUD it
            // is standing in for, while the camera and its detection boxes go
            // on showing through the hole in it.
            if let card = model.frame.hud.takeover {
                TakeoverView(takeover: card,
                             bearingDegrees: overlay.arrow.map { Double($0.bearingRadians) * 180 / .pi },
                             chip: takeoverChip)
                    .transition(.opacity)
            }
            // Last, and over everything: a flash the audience can see from the
            // back of the room is the point of the flash.
            if let flash = overlay.flash {
                FlashView(flash: flash)
            }
        }
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
        .animation(.easeOut(duration: 0.12), value: overlay.flash)
        .animation(.easeOut(duration: 0.2), value: overlay.phase)
        // A lock is confirmed once, by the full-screen green flash
        // (`OverlayEngine.lockFlashText`). The calibrate card used to be held
        // open afterwards to say "Calibrated" a second time, which put the same
        // word on screen twice for one event; now the card simply leaves when
        // `covers` says the prompt has been answered.
        // No `.preferredColorScheme(.dark)` here. It used to pin the whole tree,
        // including the phase card and the seat picker — modal cards that have
        // no reason to ignore a light-mode operator. What actually has to stay
        // dark is the chrome over the camera, and that says so itself with
        // `.cameraChrome()`.
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { model.reportScreenSize(geometry.size) }
                .onChange(of: geometry.size) { _, size in model.reportScreenSize(size) }
                .onChange(of: model.isJoined) { _, _ in model.reportScreenSize(geometry.size) }
        }.ignoresSafeArea())
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }

    /// "SAM · 12 m" under the takeover's arrow: the name the card is already
    /// shouting, and how far there is to walk.
    private var takeoverChip: String? {
        guard let title = model.frame.hud.takeover?.title,
              let distance = overlay.arrow?.distance else { return nil }
        let name = title.replacingOccurrences(of: " found", with: "").uppercased()
        return String(format: "%@ · %.0f m", name, Double(distance))
    }

    private var chrome: some View {
        VStack(spacing: Space.s) {
            // Compass first, full width, where the console draws it. Then what
            // the hub is telling this operator, then how the phone itself is doing.
            HUDStackView(hud: model.frame.hud)
            // Healthy tracking should feel like the absence of a problem, not
            // a permanent green badge competing with the camera. Only surface
            // status when the operator can or must do something about it.
            ZStack(alignment: .top) {
                HStack(alignment: .top, spacing: Space.s) {
                    Spacer(minLength: 0)
                    // Stays up under a phase card: the card used to carry its
                    // own gear because it covered the screen, and now that the
                    // calibrate card stands aside for the viewfinder there is
                    // one gear, in the one place, for every state. Only the map
                    // takes it away, and the map is dismissed by tapping it.
                    if !isShowingMap, let onRequestSettings {
                        SettingsButton(action: onRequestSettings)
                            .transition(.opacity)
                    }
                }
                if overlay.status.level != .ok, !chromeIsHidden {
                    OperatorStatusView(status: overlay.status)
                        // Keep long hint cards from covering the chrome controls.
                        .padding(.horizontal, 52)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                if showMiniMap, !chromeIsHidden, let room = overlay.room {
                    miniMap(room: room)
                }
                Spacer(minLength: 0)
                // Opposite the map: the place you are, and the place you are
                // being sent. The mirror decides whether there is anything to
                // say here.
                if let objective = model.frame.hud.objective, !chromeIsHidden {
                    ObjectiveCardView(objective: objective)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.top, Space.s)
        .padding(.bottom, Space.l)
        .cameraChrome()
    }

    /// The corner map. It rests at the bottom-left, where the chrome puts it,
    /// and the operator can drag it anywhere else on the screen — a thumbnail
    /// pinned over the one part of the feed they are trying to look at is worse
    /// than no thumbnail, and which part that is depends on the room.
    private func miniMap(room: HubRoom) -> some View {
        MiniMapView(room: room, world: overlay.world, me: overlay.roomPose, pings: overlay.pings)
            // A fixed window that follows the operator, not the room's own
            // aspect: the dot stays centred however far they walk.
            .frame(width: Self.miniMapSize.width, height: Self.miniMapSize.height)
            // Picked up while the thumb is on it, so a drag is visibly a drag
            // and not a tap that failed to open the map.
            .scaleEffect(isDraggingMiniMap ? 1.04 : 1)
            .shadow(color: .black.opacity(isDraggingMiniMap ? 0.35 : 0), radius: 12, y: 6)
            .animation(Motion.lift, value: isDraggingMiniMap)
            .offset(miniMapOffset)
            // Measured after the offset, so this is where the thumbnail
            // actually is — which is where the genie has to go.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                // Not while the map is up: the thumbnail is on its way out and
                // its frame mid-transition is not a place to collapse into.
                if !isShowingMap { miniMapFrame = frame }
            }
            .onTapGesture { showMap(true) }
            .gesture(miniMapDrag)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Where everyone is")
            .accessibilityHint("Opens the full map. Drag to move it.")
            .transition(.opacity)
    }

    /// Drag to park the mini-map somewhere else.
    ///
    /// `minimumDistance` is what keeps the tap that opens the map: a thumb that
    /// does not travel six points is still a tap, and SwiftUI will not hand the
    /// touch back once a zero-distance drag has claimed it.
    private var miniMapDrag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                isDraggingMiniMap = true
                miniMapOffset = clampedMiniMapOffset(by: value.translation)
            }
            .onEnded { value in
                miniMapRest = clampedMiniMapOffset(by: value.translation)
                isDraggingMiniMap = false
                withAnimation(Motion.settle) { miniMapOffset = miniMapRest }
            }
    }

    /// The committed offset plus this drag, held inside the layout area so the
    /// thumbnail can never be pushed half off the screen.
    private func clampedMiniMapOffset(by translation: CGSize) -> CGSize {
        let proposed = CGSize(width: miniMapRest.width + translation.width,
                              height: miniMapRest.height + translation.height)
        guard contentSize.width > 0, contentSize.height > 0 else { return proposed }
        // It rests against the chrome's own padding, so travel right is
        // whatever is left of the width, and travel up is whatever is left of
        // the height. Down and left are already against the stop.
        let maxX = max(0, contentSize.width - Self.miniMapSize.width - Space.m * 2)
        let minY = -max(0, contentSize.height - Self.miniMapSize.height - Space.l - Space.s)
        return CGSize(width: min(max(0, proposed.width), maxX),
                      height: min(0, max(minY, proposed.height)))
    }

    /// The mini-map's centre as a fraction of the screen: where the map is
    /// pulled out of and sucked back into.
    private var genieAnchor: UnitPoint {
        guard contentSize.width > 0, contentSize.height > 0, miniMapFrame != .zero else {
            return .bottomLeading
        }
        return UnitPoint(x: min(1, max(0, miniMapFrame.midX / contentSize.width)),
                         y: min(1, max(0, miniMapFrame.midY / contentSize.height)))
    }

    private func showMap(_ showing: Bool) {
        withAnimation(Motion.genie) { isShowingMap = showing }
    }
}

/// Settings is a real SwiftUI control, not a hand-built circle with a tap
/// gesture. The app's iOS 26 deployment target guarantees the glass treatment.
struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button("Settings", systemImage: "gearshape", action: action)
            .labelStyle(.iconOnly)
            .font(TypeScale.inlineSymbol)
            .controlSize(.large)
            .buttonBorderShape(.circle)
            .buttonStyle(.glass)
            .tint(.hudInk)
            .accessibilityLabel("Settings")
    }
}

/// Shown where the camera would be when there is no camera: the Simulator, or
/// before joining.
struct ReplayBackdrop: View {
    let isJoined: Bool

    /// Scales with the operator's text size, unlike the fixed 40pt it replaces.
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 40

    var body: some View {
        ZStack {
            // It stands *in place of* the camera, so it has to be as dark as
            // the feed it replaces — otherwise the HUD's contrast is one thing
            // in the Simulator and another on a device.
            LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16), .hudVoid],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: Space.s) {
                Image(systemName: isJoined ? "figure.walk.motion" : "camera")
                    .font(.system(size: symbolSize))
                Text(isJoined ? "Replaying a recorded walk" : "Not joined")
                    .font(TypeScale.footnote)
            }
            .foregroundStyle(.hudInkSecondary)
        }
        .cameraChrome()
        .ignoresSafeArea()
    }
}

extension Color {
    init?(hex: String?) {
        guard let rgb = HexColor.parse(hex) else { return nil }
        self.init(.sRGB, red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2), opacity: 1)
    }
}
