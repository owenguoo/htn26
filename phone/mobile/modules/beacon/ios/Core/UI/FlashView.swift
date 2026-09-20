import SwiftUI
import SwarmCore

/// A colour over the whole screen for a moment, with a word on it: the marker
/// locking, or anything else the hub chooses to flash.
///
/// **It is deliberately not opaque.** It used to be a flat fill at full alpha,
/// which is unbeatable at getting attention and actively dangerous at getting
/// anyone anywhere: the operator is holding this phone up in front of their
/// face, in a crowded room, and for the whole time it was up they could not see
/// the floor. So the colour lives at the edges and clears the middle — a
/// vignette, strong enough to read across a room, transparent enough to walk
/// through.
///
/// **It fades in and it fades out, and it does nothing else.** It used to
/// contract upward as it left, which was right when the flash was the
/// announcement of a find: it read as the alert *becoming* the badge at the top
/// of the screen, which is where that message carries on. The find announcement
/// is `TakeoverView`'s job now, and this is left with the moments that have no
/// badge to become — a marker locking is finished when it is finished. Sliding
/// it toward a corner where nothing is waiting made a completed thing look like
/// it had gone somewhere.
struct FlashView: View {
    let flash: FlashCue

    /// Symmetric, and slower than a transition would give on its own. A flash
    /// that snaps in reads as a glitch; one that eases in and out reads as the
    /// app answering.
    static let fadeIn: Double = 0.25
    static let fadeOut: Double = 0.35

    @State private var shown = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                vignette(in: geometry.size)
                if let text = flash.text {
                    Text(text)
                        .font(TypeScale.alert(40))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(.hudInk)
                        // The text sits on clear camera, not on a wash of
                        // colour, so it carries its own contrast with it.
                        .shadow(color: .hudVoid.opacity(0.85), radius: 8)
                        .shadow(color: .hudVoid.opacity(0.5), radius: 2)
                        .padding(Space.xxl)
                }
            }
        }
        .opacity(shown ? 1 : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { withAnimation(.easeInOut(duration: Self.fadeIn)) { shown = true } }
    }

    /// Colour at the bezel, clear camera in the middle. The radii are in the
    /// smaller screen dimension so a landscape frame does not lose the clear
    /// centre entirely.
    private func vignette(in size: CGSize) -> some View {
        let reach = max(size.width, size.height)
        return RadialGradient(
            colors: [color.opacity(0), color.opacity(0.15), color.opacity(0.36), color.opacity(0.6)],
            center: .center,
            startRadius: min(size.width, size.height) * 0.18,
            endRadius: reach * 0.78)
    }

    private var color: Color {
        Color(.sRGB, red: Double(flash.red), green: Double(flash.green),
              blue: Double(flash.blue), opacity: 1)
    }
}
