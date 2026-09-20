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

    /// Eases the wash in and out rather than snapping between situations.
    @State private var shown = false
    @State private var pulseDim = false

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
        .opacity(opacity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { sync(to: ambient) }
        .onChange(of: ambient?.kind) { _, _ in sync(to: ambient) }
        .onChange(of: ambient?.color) { _, _ in sync(to: ambient) }
    }

    private var opacity: Double {
        guard shown, let ambient else { return 0 }
        guard ambient.kind == "find" || ambient.kind == "hazard" else { return 1 }
        return pulseDim ? 0.55 : 1
    }

    private func sync(to ambient: HubHUDMirror.Ambient?) {
        guard let ambient else {
            withAnimation(.easeInOut(duration: 0.45)) { shown = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.35)) { shown = true }
        pulseDim = false
        guard ambient.kind == "find" || ambient.kind == "hazard" else { return }
        // A hazard breathes faster than a walk: it is about the next two steps.
        // The find period matches `HUDSoundEdgeView`'s 0.9 s exactly — while
        // walking to somebody off to one side both are up at once, and two red
        // pulses on slightly different clocks beat against each other.
        let period = ambient.kind == "hazard" ? 0.55 : 0.9
        withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
            pulseDim = true
        }
    }
}
