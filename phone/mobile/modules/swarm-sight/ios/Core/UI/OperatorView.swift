import SwiftUI
import SwarmCore

/// The whole operator interface: camera, guidance, and whatever the hub says.
///
/// The HUD proper — compass tape, banner, toast, floating markers, detection
/// boxes — is drawn from `frame.hud`, the same value sent to the operator
/// console, so phone and console show the same thing. What is phone-only sits
/// around it: the identity badge, the status pill, the mini-map, the seat picker.
///
/// Everything it draws comes from `OverlayModel` in SwarmCore, so the decisions
/// — which way to point, when an arrow is stale, when to stop showing a flash —
/// are all tested. This file only turns that data into pixels.
public struct OperatorView: View {
    let model: OperatorViewModel
    var showDebug: Bool
    var showMiniMap: Bool
    var onRequestLeave: (() -> Void)?
    var onRequestSettings: (() -> Void)?

    @State private var isPickingSeat = false

    public init(model: OperatorViewModel, showDebug: Bool = false, showMiniMap: Bool = true,
                onRequestLeave: (() -> Void)? = nil, onRequestSettings: (() -> Void)? = nil) {
        self.model = model
        self.showDebug = showDebug
        self.showMiniMap = showMiniMap
        self.onRequestLeave = onRequestLeave
        self.onRequestSettings = onRequestSettings
    }

    private var overlay: OverlayState { model.frame.overlay }
    private var captureSize: CGSize {
        CGSize(width: model.frame.captureWidth, height: model.frame.captureHeight)
    }

    public var body: some View {
        ZStack {
            // The thing the overlay overlays. Without it the operator is aiming
            // a camera they cannot see through.
            if let preview = model.preview {
                CameraPreviewView(source: preview)
            } else {
                ReplayBackdrop(isJoined: model.isJoined)
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
            // the console draws over the feed.
            HUDFrameLayerView(hud: model.frame.hud, captureSize: captureSize)

            chrome

            if let phase = overlay.phase, PhaseCardView.covers(phase), !isPickingSeat {
                PhaseCardView(phase: phase, alignment: overlay.alignment,
                              lookingFor: overlay.world?.lookingFor,
                              onPickSeat: { isPickingSeat = true })
            }

            if isPickingSeat, let room = overlay.room {
                SeatPickerView(room: room, world: overlay.world, current: overlay.roomPose,
                               onSeat: { model.setSeat(x: $0.x, y: $0.y) },
                               onConfirm: { await model.calibrateFacingStage() },
                               onResetOrigin: overlay.alignment == .marker ? { model.resetOrigin() } : nil,
                               onClose: { isPickingSeat = false })
            }

            // Last, and over everything: a flash the audience can see from the
            // back of the room is the point of the flash.
            if let flash = overlay.flash {
                FlashView(flash: flash)
            }
        }
        .animation(.easeOut(duration: 0.12), value: overlay.flash)
        .animation(.easeOut(duration: 0.2), value: overlay.phase)
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

    private var chrome: some View {
        VStack(spacing: Space.s) {
            // Compass first, full width, where the console draws it. Then what
            // the hub is telling this operator, then how the phone itself is doing.
            HUDStackView(hud: model.frame.hud)
            HStack(alignment: .top, spacing: Space.s) {
                IdentityBadge(index: overlay.index, colorHex: overlay.colorHex)
                OperatorStatusView(status: overlay.status,
                                   onTap: overlay.status.offersSeatPicker ? { isPickingSeat = true } : nil)
                if overlay.status.hint == nil { Spacer(minLength: 0) }
                if let onRequestSettings {
                    ChromeButton(symbol: "gearshape.fill", label: "Settings", action: onRequestSettings)
                }
                if let onRequestLeave {
                    ChromeButton(symbol: "xmark", label: "Leave", action: onRequestLeave)
                }
            }
            Spacer()
            HStack(alignment: .bottom) {
                if showMiniMap, let room = overlay.room {
                    MiniMapView(room: room, world: overlay.world, me: overlay.roomPose,
                                colorHex: overlay.colorHex, pings: overlay.pings)
                        // A fixed window that follows the operator, not the room's
                        // own aspect: the dot stays centred however far they walk.
                        .frame(width: 132, height: 150)
                        .onTapGesture { isPickingSeat = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Where everyone is")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.top, Space.s)
        .padding(.bottom, Space.l)
        .cameraChrome()
    }
}

/// A round glyph on blur: the shared shape for everything that floats over the
/// feed. Drawn at 30pt so it covers as little of the camera as possible, tapped
/// at 44 — the visual size and the hit target are not the same number, and a
/// 30pt tap target on a phone held at arm's length is a miss.
struct ChromeButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(TypeScale.chromeGlyph)
                .foregroundStyle(.hudInk)
                .frame(width: 30, height: 30)
                .background(Surface.hudChrome, in: Circle())
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// "#3" in the colour the dashboard draws this phone in, so an operator and the
/// person at the console can agree which phone they are talking about.
struct IdentityBadge: View {
    let index: Int?
    let colorHex: String?

    var body: some View {
        Text(index.map { "#\($0)" } ?? "#–")
            .font(TypeScale.identity)
            // The hub's colour for this phone, so the operator and the person
            // at the console can agree which phone they mean. Wire, not theme.
            .foregroundStyle(Color(hex: colorHex) ?? .hudInk)
            // Same insets as the status pill beside it, so the two capsules are
            // the same height however long the sentence in the pill gets.
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Surface.hudChrome, in: Capsule())
            .accessibilityLabel(index.map { "Phone \($0)" } ?? "Phone, no number yet")
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
