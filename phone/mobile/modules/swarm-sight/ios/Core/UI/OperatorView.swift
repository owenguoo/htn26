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

    @State private var isPickingSeat = false

    public init(model: OperatorViewModel, showDebug: Bool = false, showMiniMap: Bool = true,
                onRequestLeave: (() -> Void)? = nil) {
        self.model = model
        self.showDebug = showDebug
        self.showMiniMap = showMiniMap
        self.onRequestLeave = onRequestLeave
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
        .preferredColorScheme(.dark)
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
        VStack(spacing: 8) {
            // Compass first, full width, where the console draws it. Then what
            // the hub is telling this operator, then how the phone itself is doing.
            HUDStackView(hud: model.frame.hud)
            HStack(alignment: .top, spacing: 8) {
                IdentityBadge(index: overlay.index, colorHex: overlay.colorHex)
                OperatorStatusView(status: overlay.status,
                                   onTap: overlay.status.offersSeatPicker ? { isPickingSeat = true } : nil)
                if overlay.status.hint == nil { Spacer(minLength: 0) }
                if let onRequestLeave {
                    Button(action: onRequestLeave) {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .padding(9)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Leave")
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
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}

/// "#3" in the colour the dashboard draws this phone in, so an operator and the
/// person at the console can agree which phone they are talking about.
struct IdentityBadge: View {
    let index: Int?
    let colorHex: String?

    var body: some View {
        Text(index.map { "#\($0)" } ?? "#–")
            .font(.headline.monospacedDigit().weight(.heavy))
            .foregroundStyle(Color(hex: colorHex) ?? .white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Shown where the camera would be when there is no camera: the Simulator, or
/// before joining.
struct ReplayBackdrop: View {
    let isJoined: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16), .black],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                Image(systemName: isJoined ? "figure.walk.motion" : "camera")
                    .font(.system(size: 40))
                Text(isJoined ? "Replaying a recorded walk" : "Not joined")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}

extension Color {
    init?(hex: String?) {
        guard let rgb = HexColor.parse(hex) else { return nil }
        self.init(.sRGB, red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2), opacity: 1)
    }
}
