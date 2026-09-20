import SwarmCore
import UIKit

/// Plays the `HapticCue`s `OverlayModel` raises — `locked`, `possible_match`,
/// `flash`, `ping`, `message`, `onTarget` — as system feedback.
///
/// **`UIFeedbackGenerator`, deliberately, and not `CHHapticEngine` again.**
/// The engine version of this file (`HapticPlayer`) was deleted during the
/// device bring-up for a specific reason: it installs `stoppedHandler` and
/// `resetHandler`, non-`Sendable` blocks that the system calls back on its own
/// internal queue, from a `@MainActor` type — the exact shape of the
/// `_dispatch_assert_queue_fail` trap that was halting the app at join.
/// `UIFeedbackGenerator` has none of that surface: no engine to start, no
/// handlers, no restart-after-interruption, nothing delivered off the main
/// thread. The cost is system feedback instead of authored patterns, which for
/// five cues that all mean "something just happened" is a good trade.
///
/// **If nothing is felt on a device that is otherwise working**, the first
/// thing to check is the phone, not this file: unlike Core Haptics, system
/// feedback obeys Settings › Sounds & Haptics. With the ringer switched to
/// silent and "Play Haptics in Silent Mode" off, every call here is a no-op and
/// the OS reports no error.
///
/// The cue names say what *happened*, not what it should feel like. Turning one
/// into the other is this file's whole job.
///
/// DEVICE-VERIFY: a human must confirm on hardware that each of the six cues
/// is felt and that they are told apart by feel — the Simulator has no Taptic
/// Engine and plays nothing, so no test here can see any of it. Also confirm a
/// run of pings does not run together into one buzz, that a sustained possible
/// match buzzes once and not again for ten seconds, and that turning off system
/// haptics in Settings silences them rather than breaking anything.
/// DEVICE_CHECKLIST.md item 12.
@MainActor
final class Haptics {
    /// Held between cues rather than allocated per firing. The Taptic Engine
    /// idles down, `prepare()` is what wakes it, and a generator created at the
    /// moment of use misses that window entirely — which on a cue that marks a
    /// moment, like the marker locking, is the difference between feedback and
    /// a late buzz.
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let notice = UINotificationFeedbackGenerator()
    private let selection = UISelectionFeedbackGenerator()

    init() {}

    /// Call when the operator screen appears. The first cue after a quiet
    /// minute is usually the lock landing, and that is the one that most needs
    /// to arrive on time.
    func prepare() {
        impact.prepare()
        heavy.prepare()
        light.prepare()
        notice.prepare()
        selection.prepare()
    }

    func play(_ cue: HapticCue) {
        let intensity = CGFloat(max(0, min(1, cue.intensity)))
        switch cue.pattern {
        case "locked", "possible_match":
            // Two successes: the marker landing, and the detector holding a
            // possible target long enough to be worth interrupting for.
            // `.success` is the system's word for both, and `OverlayModel`
            // already rate-limits the second one to once every ten seconds —
            // the cooldown belongs there, with the overlap test that earns it,
            // not in the thing that plays the buzz.
            notice.notificationOccurred(.success)
        case "flash":
            // The operator is being made visible to a whole room. Two heavy
            // taps, so it cannot be mistaken for a ping.
            heavy.impactOccurred(intensity: intensity)
            Task { @MainActor [heavy] in
                try? await Task.sleep(for: .milliseconds(110))
                heavy.impactOccurred(intensity: intensity)
            }
        case "ping":
            impact.impactOccurred(intensity: intensity)
        case "message":
            light.impactOccurred(intensity: intensity)
        case "pulse":
            // The beat under a pulsing screen. Which generator carries it is
            // the whole message: a hazard three metres off should be felt as a
            // tick, the same hazard at arm's length as a thump. One pattern,
            // three weights, chosen by how close the thing is.
            if intensity >= 0.8 { heavy.impactOccurred(intensity: intensity) }
            else if intensity >= 0.5 { impact.impactOccurred(intensity: intensity) }
            else { light.impactOccurred(intensity: intensity) }
        case "onTarget":
            // Landing on the target is a detent, not an event — the same feel
            // a picker gives when it clicks into a value.
            selection.selectionChanged()
        default:
            // "A client that does not know a name still plays something."
            light.impactOccurred(intensity: intensity)
        }
        prepare()
    }
}
