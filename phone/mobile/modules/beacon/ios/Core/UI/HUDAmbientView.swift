import SwiftUI
import SwarmCore

/// The standing colour of the situation, held over the whole screen.
///
/// This is the half of the alert that does not go away. The hub's flash is an
/// event — "You found them!" — and events end; being one of the people walking
/// to a casualty, and then standing over them, lasts minutes. For all of those
/// minutes the screen says red without being asked again, and it stops saying
/// it when the hub says the situation is over, not on a timer.
///
/// **Translucent by contract.** The colour lives at the bezel and the middle
/// stays clear camera. The operator is holding this phone up in front of their
/// face and walking through a crowded room the whole time it is on; a wash they
/// cannot see through would be a wash they have to lower the phone to escape,
/// which defeats every other thing on this screen.
///
/// **It does not flash.** It used to breathe, faster the closer the thing got,
/// which is the obvious way to say "urgent" and the wrong one here: the whole
/// design of this wash is that an operator can see through it while they walk,
/// and a surface changing brightness twice a second is harder to see past than
/// the same surface held still. Urgency that costs visibility is not urgency,
/// it is interference. The rhythm lives in the haptics instead, where it costs
/// nothing to look at — same tempo, same weight, same `Ambient` behind both.
///
/// Intensity still rises as the thing gets nearer. A closer hazard is a deeper
/// amber and a harder buzz; it is simply never a blinking one.
struct HUDAmbientView: View {
    let ambient: HubHUDMirror.Ambient?
    /// The beat, felt and not seen. The wash itself holds steady — a screen
    /// that flashes is harder to see past than a solid one, and somebody
    /// walking toward a casualty is trying to see past it the whole time — so
    /// the rhythm moved into the hand, where it costs no visibility at all.
    var onPulse: @MainActor (Double, String) -> Void = { _, _ in }

    /// Eases the wash in and out rather than snapping between situations.
    @State private var shown = false

    var body: some View {
        GeometryReader { geometry in
            if let ambient {
                let color = Color(hex: ambient.color) ?? .red
                let peak = ambient.intensity * 0.62
                RadialGradient(
                    colors: [color.opacity(0), color.opacity(peak * 0.22),
                             color.opacity(peak * 0.55), color.opacity(peak)],
                    center: .center,
                    startRadius: min(geometry.size.width, geometry.size.height) * 0.2,
                    endRadius: max(geometry.size.width, geometry.size.height) * 0.8)
            }
        }
        .opacity(shown ? 1 : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: ambient == nil) { _, gone in
            withAnimation(.easeInOut(duration: gone ? 0.45 : 0.35)) { shown = !gone }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.35)) { shown = ambient != nil } }
        // Re-keyed whenever the rhythm changes, so closing on something picks up
        // the new tempo instead of finishing the old beat first.
        .task(id: ambient?.pulseMs.rounded()) { await beat() }
    }

    /// The haptic heartbeat. Its tempo and its weight both come from the same
    /// `Ambient` the colour does, so what the hand feels and what the screen
    /// says are one description of one situation.
    @MainActor
    private func beat() async {
        guard let period = ambient?.pulseMs, period > 0 else { return }
        while !Task.isCancelled {
            onPulse(ambient?.intensity ?? 0.6, ambient?.kind ?? "find")
            try? await Task.sleep(for: .milliseconds(Int(period)))
        }
    }
}
