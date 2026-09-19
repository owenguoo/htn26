import CoreHaptics
import Foundation
import SwarmCore

/// A sharp transient on command — the thing the web client could never do.
///
// DEVICE-VERIFY: the Simulator has no haptic engine, so none of this has run. A
// human must confirm a haptic command produces a sharp transient you can feel,
// and that backgrounding and returning does not kill the engine permanently.
// DEVICE_CHECKLIST.md item 12.
@MainActor
public final class HapticPlayer {
    private var engine: CHHapticEngine?
    public private(set) var isAvailable = false

    public init() {}

    public func prepare() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            isAvailable = false
            return
        }
        do {
            let engine = try CHHapticEngine()
            // The engine stops on interruption and on app backgrounding. Without
            // these it silently never fires again, which on stage looks exactly
            // like the feature not existing.
            engine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.restart() }
            }
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.restart() }
            }
            try engine.start()
            self.engine = engine
            isAvailable = true
        } catch {
            isAvailable = false
        }
    }

    private func restart() {
        do {
            try engine?.start()
        } catch {
            isAvailable = false
        }
    }

    public func play(_ cue: HapticCue) {
        guard let engine, isAvailable else { return }
        let events: [CHHapticEvent]
        switch cue.pattern {
        // The hub has no haptic command; these names are the local events
        // `OverlayModel` raises. A ping is the one that must not be missed.
        case "double", "ping":
            events = [transient(at: 0, intensity: cue.intensity),
                      transient(at: 0.12, intensity: cue.intensity)]
        case "continuous", "flash":
            events = [CHHapticEvent(eventType: .hapticContinuous,
                                    parameters: [
                                        .init(parameterID: .hapticIntensity, value: cue.intensity),
                                        .init(parameterID: .hapticSharpness, value: 0.5),
                                    ],
                                    relativeTime: 0, duration: 0.4)]
        default:
            events = [transient(at: 0, intensity: cue.intensity)]
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // A failed haptic is never worth interrupting the demo for.
        }
    }

    private func transient(at time: TimeInterval, intensity: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient,
                      parameters: [
                          .init(parameterID: .hapticIntensity, value: intensity),
                          .init(parameterID: .hapticSharpness, value: 1.0),
                      ],
                      relativeTime: time)
    }
}
