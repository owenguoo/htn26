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
/// Pulsing is reserved for *go*. Once somebody has arrived, a screen still
/// throbbing at them is nagging about a decision they have already made, so the
/// `with` state holds steady and dimmer — the same red, because the emergency
/// did not end when they got there.
struct HUDAmbientView: View {
    let ambient: HubHUDMirror.Ambient?
    /// Fired on the bright edge of every beat, with the ambient's own
    /// intensity. The light and the buzz come off the same loop on purpose:
    /// two clocks would drift, and a screen flashing out of time with the hand
    /// is worse than either on its own.
    var onPulse: @MainActor (Double) -> Void = { _ in }

    /// Eases the wash in and out rather than snapping between situations.
    @State private var shown = false
    @State private var dim = false

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
        .opacity(shown ? (dim ? 0.5 : 1) : 0)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: ambient == nil) { _, gone in
            withAnimation(.easeInOut(duration: gone ? 0.45 : 0.35)) { shown = !gone }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.35)) { shown = ambient != nil } }
        // Re-keyed whenever the rhythm changes, so closing on something restarts
        // the loop at the new tempo instead of finishing the old beat first.
        .task(id: ambient?.pulseMs.rounded()) { await beat() }
    }

    /// One heartbeat: a quick brighten with the buzz, then a slower decay. Not
    /// `repeatForever`, because that animates without ever handing control back,
    /// and the haptic has to land on the same edge as the light.
    @MainActor
    private func beat() async {
        guard let period = ambient?.pulseMs, period > 0 else {
            withAnimation(.easeInOut(duration: 0.3)) { dim = false }
            return
        }
        let rise = period * 0.3, fall = period * 0.7
        while !Task.isCancelled {
            onPulse(ambient?.intensity ?? 0.6)
            withAnimation(.easeOut(duration: rise / 1000)) { dim = false }
            try? await Task.sleep(for: .milliseconds(Int(rise)))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: fall / 1000)) { dim = true }
            try? await Task.sleep(for: .milliseconds(Int(fall)))
        }
    }
}
