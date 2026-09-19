import SwiftUI
import SwarmCore

/// The whole operator interface: camera, guidance, and whatever the hub says.
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

    public init(model: OperatorViewModel, showDebug: Bool = true, showMiniMap: Bool = true,
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
                // Where the venue thinks the markers are. If these outlines sit
                // on the printed markers and stay there as you walk, calibration
                // is good; if they slide off, that is the drift.
                MarkerOverlayView(projections: model.frame.markerProjections, captureSize: captureSize)
            }

            if let detections = overlay.detections {
                DetectionBoxesView(boxes: detections.boxes, captureSize: captureSize)
            }
            PingMarkersView(pings: overlay.pings, captureSize: captureSize)

            if let arrow = overlay.arrow {
                // A scrim, so white chevrons stay legible over a bright room.
                Color.black.opacity(0.25).ignoresSafeArea().allowsHitTesting(false)
                ArrowView(arrow: arrow)
            }

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
                               onClose: { isPickingSeat = false })
            }

            // Last, and over everything: a flash the audience can see from the
            // back of the room is the point of the flash.
            if let flash = overlay.flash {
                FlashView(flash: flash)
            }
        }
        .animation(.easeOut(duration: 0.12), value: overlay.flash)
        .animation(.easeOut(duration: 0.08), value: overlay.arrow)
        .animation(.easeOut(duration: 0.2), value: overlay.toast)
        .animation(.easeOut(duration: 0.2), value: overlay.phase)
        .preferredColorScheme(.dark)
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
    }

    private var chrome: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IdentityBadge(index: overlay.index, colorHex: overlay.colorHex)
                Spacer(minLength: 0)
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
            if showDebug {
                // Its own row: the pill is fixed-size by design, and sharing a
                // row pushed the badge and the leave button off the screen.
                StatusPillView(pill: overlay.pill)
            }
            if let banner = overlay.banner {
                GuideBannerView(banner: banner)
            }
            if overlay.alignment == .none, overlay.phase.map(PhaseCardView.covers) != true {
                AlignmentHintView(onPickSeat: { isPickingSeat = true })
            }
            Spacer()
            HStack(alignment: .bottom) {
                if showMiniMap, let room = overlay.room {
                    MiniMapView(room: room, world: overlay.world, me: overlay.roomPose,
                                colorHex: overlay.colorHex, pings: overlay.pings)
                        .frame(width: 132, height: 132 * room.depth / max(1, room.width))
                        .onTapGesture { isPickingSeat = true }
                }
                Spacer(minLength: 0)
            }
            if let toast = overlay.toast {
                ToastView(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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

struct AlignmentHintView: View {
    let onPickSeat: () -> Void

    var body: some View {
        Button(action: onPickSeat) {
            Label("Point at a marker, or tap to set your spot", systemImage: "scope")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.orange.opacity(0.9), in: Capsule())
                .foregroundStyle(.black)
        }
    }
}

extension Color {
    init?(hex: String?) {
        guard let rgb = HexColor.parse(hex) else { return nil }
        self.init(.sRGB, red: Double(rgb.0), green: Double(rgb.1), blue: Double(rgb.2), opacity: 1)
    }
}
