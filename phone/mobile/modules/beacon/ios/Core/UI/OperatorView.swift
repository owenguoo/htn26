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

    @State private var isPickingSeat = false

    public init(model: OperatorViewModel, showDebug: Bool = false, showMiniMap: Bool = true,
                onRequestSettings: (() -> Void)? = nil) {
        self.model = model
        self.showDebug = showDebug
        self.showMiniMap = showMiniMap
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
            // the console draws over the feed.
            HUDFrameLayerView(hud: model.frame.hud, captureSize: captureSize)

            if let soundEdge = model.frame.hud.soundEdge {
                HUDSoundEdgeView(edge: soundEdge)
            }

            chrome

            // Over the chrome so a thumb on the puck is not competing with the
            // chrome's layout, and because the one control the operator has to
            // find should not be underneath anything.
            if model.isDrive, !isPickingSeat {
                DriveStickView(model: model)
            }

            // The glance-speed form of the elevation half of the banner. Only
            // ever present when the operator is already on target horizontally,
            // so it never appears beside a turn instruction.
            if let elevation = overlay.elevation, !isPickingSeat {
                ElevationCueView(cue: elevation)
            }

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
            // Healthy tracking should feel like the absence of a problem, not
            // a permanent green badge competing with the camera. Only surface
            // status when the operator can or must do something about it.
            ZStack(alignment: .top) {
                HStack(alignment: .top, spacing: Space.s) {
                    Spacer(minLength: 0)
                    if let onRequestSettings {
                        SettingsButton(action: onRequestSettings)
                    }
                }
                if overlay.status.level != .ok {
                    OperatorStatusView(status: overlay.status,
                                       onTap: overlay.status.offersSeatPicker ? { isPickingSeat = true } : nil)
                        // Keep long hint cards from covering the settings control.
                        .padding(.horizontal, 52)
                        .frame(maxWidth: .infinity, alignment: .top)
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
