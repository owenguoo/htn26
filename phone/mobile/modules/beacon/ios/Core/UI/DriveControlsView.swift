import SwiftUI
import SwarmCore

/// Drag to look, hold the stick to walk — the Simulator's stand-in for actually
/// turning around in a room.
///
/// **Two views, not one, and that is the whole design.** The look layer has to
/// be *under* the operator chrome so the status pill, the seat picker, the
/// mini-map and the settings button keep their taps; a
/// full-screen `contentShape` over the top would eat every one of them. The
/// stick has to be *over* it so it is visible and so a thumb on the puck is not
/// competing with the chrome's layout. So `OperatorView` inserts
/// `DriveLookLayer` just above the backdrop and `DriveStickView` above `chrome`.
///
/// Neither view does any maths. Points of drag go straight into `DriveInput`;
/// the degrees-per-point, the clamps, the smoothing and the walk speeds all
/// live in `DriveMotionModel.Tuning`, where they are tested. Scaling here as
/// well would silently double the sensitivity and there would be two places to
/// look for it.
///
/// SIM-VERIFY: there is no `DEVICE-VERIFY` for this file and it must not join
/// `ArchitectureTests`' `deviceDependent` list — the drive source is gated to
/// `#if targetEnvironment(simulator)` and can never run on hardware, so there is
/// no hardware check to write. What a human has to check **in the Simulator**:
///
///  1. **The chrome still works while driving.** Tap the status pill (when it
///     offers the seat picker), tap the mini-map and tap the gear.
///     All four sit above `DriveLookLayer` in the `ZStack`, so SwiftUI
///     hit-tests them first and the drag never begins.
///  2. **A drag that *starts* on one of those does nothing.** That is accepted,
///     not a bug: SwiftUI will not re-route a touch to a lower view after a tap
///     gesture has claimed it, and pretending otherwise is a bug factory. Start
///     the drag over the middle of the screen.
///  3. **The compass tape and the HUD canvases do not block.** Both carry
///     `.allowsHitTesting(false)`, so a drag across the top strip turns.
///     A drag beginning exactly on the status pill's
///     capsule may not, per (2).
///  4. **The puck clears everything.** Centred at `(W − 72, H − 72)` it must
///     miss the 132 × 150 mini-map at the bottom-left and the settings control.
///     Check on the smallest device in the fleet as well as the largest.
///  5. **The stick keeps walking when the thumb stops moving**, and stops the
///     instant it is released. A stick that reset each frame would stall the
///     operator the moment they held still — `DrivePoseProvider` latches it on
///     purpose and `onEnded` below is the only thing that clears it.
///  6. **Double-tap levels the pitch** and a single tap does not.
///  7. **Directions.** Drag right ⇒ the compass tape moves so the heading
///     shrinks and the mini-map cone swings counter-clockwise. Drag up ⇒ look
///     down. Push the stick up ⇒ the dot walks the way the cone points.

/// The full-screen drag surface. Belongs **below** `chrome`.
struct DriveLookLayer: View {
    let model: OperatorViewModel

    /// `DragGesture` reports translation from where the finger went down, not
    /// since the last callback, so the previous value has to be kept to turn it
    /// into the per-event delta `DriveInput` wants.
    @State private var last: CGSize = .zero

    var body: some View {
        Color.clear
            // Without this a clear colour is not hit-testable at all.
            .contentShape(Rectangle())
            .gesture(
                // 1pt rather than 0: a zero-distance drag out-competes the
                // double tap, and one point of slop is a third of a degree.
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let dx = value.translation.width - last.width
                        let dy = value.translation.height - last.height
                        last = value.translation
                        // Drag is inverted relative to the model contract
                        // (right ⇒ +yaw, up ⇒ +pitch): grab-the-world feel.
                        // No other scaling: `Tuning` owns the sensitivity.
                        model.drive(DriveInput(yawPoints: Double(-dx), pitchPoints: Double(dy)))
                    }
                    .onEnded { _ in last = .zero }
            )
            // Snap the pitch back to level. Cheap, and worth a lot once someone
            // has flicked the camera at the ceiling.
            .onTapGesture(count: 2) { model.drive(DriveInput(levelPitch: true)) }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// The walk stick. Belongs **above** `chrome`, pinned bottom-trailing.
struct DriveStickView: View {
    let model: OperatorViewModel

    /// Points of travel before the stick registers, and the travel that means
    /// full speed. Remapped between the two so the first metre per second is
    /// not a cliff edge.
    private static let deadZone: CGFloat = 12
    private static let fullDeflection: CGFloat = 110
    /// The visible base. The stick reads beyond it — deflection is travel, not
    /// a position inside the circle — but the knob stays in.
    private static let base: CGFloat = 96
    private static let knob: CGFloat = 40
    /// Clear of the 132 × 150 mini-map at the bottom-left and of the settings
    /// control, per HANDOFF-S §7.
    private static let inset: CGFloat = 72

    @State private var offset: CGSize = .zero
    @State private var isHeld = false

    var body: some View {
        ZStack {
            Circle()
                .fill(Surface.hudChrome)
                .overlay(Circle().strokeBorder(MapInk.plateBorder, lineWidth: 1))
                .frame(width: Self.base, height: Self.base)
            Circle()
                .fill(.hudInk.opacity(isHeld ? 0.95 : 0.7))
                .frame(width: Self.knob, height: Self.knob)
                .offset(offset)
            Image(systemName: "figure.walk")
                .font(TypeScale.chromeGlyph)
                .foregroundStyle(.hudVoid.opacity(0.75))
                .offset(offset)
        }
        .frame(width: Self.base, height: Self.base)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isHeld = true
                    // Screen-up is forward, so the walk axis is the negated
                    // vertical translation.
                    let raw = CGSize(width: value.translation.width, height: -value.translation.height)
                    let travel = hypot(raw.width, raw.height)
                    guard travel > Self.deadZone else {
                        offset = .zero
                        model.drive(DriveInput(walk: .zero))
                        return
                    }
                    let span = Self.fullDeflection - Self.deadZone
                    let amount = min(1, (travel - Self.deadZone) / span)
                    let unit = CGSize(width: raw.width / travel, height: raw.height / travel)
                    // The knob shows direction and how hard, inside the base.
                    let visual = (Self.base - Self.knob) / 2
                    offset = CGSize(width: unit.width * amount * visual,
                                    height: -unit.height * amount * visual)
                    model.drive(DriveInput(walk: SIMD2(Double(unit.width * amount),
                                                       Double(unit.height * amount))))
                }
                .onEnded { _ in
                    isHeld = false
                    offset = .zero
                    // **The only thing that stops the operator.** The provider
                    // latches the stick deliberately — a finger resting on the
                    // puck emits no further gesture events, so a stick that
                    // reset each frame would stop them dead the moment they
                    // held still. Nothing else clears it.
                    model.drive(DriveInput(walk: .zero))
                }
        )
        .animation(.easeOut(duration: 0.12), value: isHeld)
        .padding(.trailing, Self.inset - Self.base / 2)
        .padding(.bottom, Self.inset - Self.base / 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .cameraChrome()
        .accessibilityLabel("Walk")
        .accessibilityHint("Drag to walk. Drag anywhere else on the screen to look around.")
    }
}
