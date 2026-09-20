import SwiftUI
import SwarmCore

/// The loudest thing this app can say: somebody has been found, or you have
/// reached them. Red means go to a person, green means stay with them — the
/// same two words the rest of the HUD uses.
///
/// **It is deliberately not opaque.** It used to be a flat fill at full alpha,
/// which is unbeatable at getting attention and actively dangerous at getting
/// anyone anywhere: the operator is holding this phone up in front of their
/// face, in a crowded room, and for the whole 2.5 seconds it was up they could
/// not see the floor. So the colour lives at the edges and clears the middle —
/// a vignette, strong enough to read across a room, transparent enough to walk
/// through.
///
/// Then it gets out of the way properly. Rather than fading on the spot, it
/// contracts upward into the banner at the top of the screen, which is where
/// the same message continues to live for as long as it matters ("Person 2 ·
/// 24 m · 40° right"). The movement is the explanation: the alert did not
/// vanish, it became the thing at the top.
///
/// What it leaves behind is `HUDAmbientView`, which holds the same colour over
/// the screen for as long as the situation lasts. This is only the
/// announcement; the state underneath it does not end when the announcement
/// does. The two stack for the second the flash is up — that peak is the
/// point — which is why the vignette here is gentler than it looks.
struct FlashView: View {
    let flash: FlashCue

    /// The alert holds its full size for this long, then contracts.
    private static let holdSeconds: Double = 0.9
    private static let collapseSeconds: Double = 0.45

    @State private var collapsed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                vignette(in: geometry.size)
                if let text = flash.text {
                    Text(text)
                        // Fixed, not a text style. The flash is read across a
                        // room at a glance; Dynamic Type shrinking it would
                        // defeat the point, and `minimumScaleFactor` already
                        // handles long text.
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(.hudInk)
                        // The text sits on clear camera, not on a wash of
                        // colour, so it carries its own contrast with it.
                        .shadow(color: .hudVoid.opacity(0.85), radius: 8)
                        .shadow(color: .hudVoid.opacity(0.5), radius: 2)
                        .padding(Space.xxl)
                        .frame(maxHeight: .infinity, alignment: collapsed ? .top : .center)
                }
            }
        }
        // Contracting toward the top is what makes it read as *moving into* the
        // banner rather than simply ending.
        .scaleEffect(collapsed ? 0.22 : 1, anchor: .top)
        .opacity(collapsed ? 0 : 1)
        .ignoresSafeArea()
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: flash.text) {
            collapsed = false
            try? await Task.sleep(for: .seconds(Self.holdSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: Self.collapseSeconds)) { collapsed = true }
        }
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
