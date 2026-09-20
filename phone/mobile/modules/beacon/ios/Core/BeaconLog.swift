import Foundation
import QuartzCore

/// Startup tracing for the device path.
///
/// This exists for one reason: the client's bring-up — ARKit, the audio session,
/// the socket — has been halting on device. A stack alone does not say which of
/// our steps was in flight, so every line here records **which queue and thread
/// it is on** as well as what it is doing. Read the last `[beacon]` line before
/// the trap: that is the step that was running, and on a queue-assertion trap
/// the label on it is half the answer.
///
/// `NSLog` rather than `print` or `os.Logger`: `print` writes to stdout, which
/// does not reliably reach Xcode's console from a device, and `Logger` redacts
/// interpolated values unless every one is marked `privacy: .public`. `NSLog`
/// reaches both Xcode and Console.app with no ceremony. (This file briefly did
/// all three at once, which is why every line appeared in triplicate.) Set
/// `isEnabled = false` to silence it.
public enum BeaconLog {
    // A `var`, because CLAUDE.md tells you to set it false to silence this and
    // a `let` makes that not compile. Seeded from the argument domain so a run
    // can quiet it without a rebuild: `-BeaconLog NO` in the scheme's launch
    // arguments. Defaults to on — the device path is still being brought up.
    //
    // `nonisolated(unsafe)` rather than an actor or a lock, and deliberately.
    // Swift 6 is right that this is mutable global state read from every thread
    // in the app, but the alternatives all cost more than the thing is worth:
    // isolating it to an actor would make `log` async and it is called from
    // ARKit's 60 Hz delegate and from CoreAudio's render thread, and a lock
    // would put a serialising point in the one place whose entire job is to
    // stay out of the way of the bring-up it is tracing. What is actually
    // shared is one word-sized Bool, written at most twice in a process —
    // once by this initialiser, once by a developer silencing the trace — and
    // read the rest of the time. A racing read sees the old value and prints
    // one extra line.
    public nonisolated(unsafe) static var isEnabled: Bool = {
        guard UserDefaults.standard.object(forKey: "BeaconLog") != nil else { return true }
        return UserDefaults.standard.bool(forKey: "BeaconLog")
    }()

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        // `dispatch_queue_get_label(nil)` is the current queue's label:
        // "com.apple.main-thread" on the main queue, the cooperative pool's
        // label on a Swift concurrency thread, "" on a bare pthread.
        let queue = String(cString: __dispatch_queue_get_label(nil))
        let thread = Thread.isMainThread ? "main" : "bg"
        let stamp = String(format: "%8.3f", CACurrentMediaTime())
        NSLog("%@", "[beacon] \(stamp) [\(thread)|\(queue)] \(message())")
    }

    /// For a step that can hang: logs before and after, so a missing "done"
    /// line localises the halt to one call.
    ///
    /// **It runs on its caller's actor** (`isolation: #isolation`), and that is
    /// not a detail. Every step this wraps is a piece of someone's bring-up
    /// written in place — `ARKitPoseProvider.start` reaching for its own
    /// `configuration`, `SwarmRuntime` reaching for the session it just built —
    /// so the closures capture actor-isolated state by construction. Without
    /// the isolated parameter this is a `nonisolated async` function, the
    /// closure has to cross an isolation boundary to reach it, and Swift 6
    /// rejects sending a task-isolated closure ("Sending value of non-Sendable
    /// type '() async throws -> …' risks causing data races"). Inheriting the
    /// caller's isolation means nothing crosses a boundary at all: no
    /// `@Sendable` requirement on the body, and no hop inserted in the middle
    /// of a join this exists to time.
    public static func step<T>(_ name: String,
                               isolation: isolated (any Actor)? = #isolation,
                               _ body: () async throws -> T) async rethrows -> T {
        log("→ \(name)")
        do {
            let value = try await body()
            log("✓ \(name)")
            return value
        } catch {
            // `String(describing:)` rather than interpolating the existential:
            // interpolating an `any Error` goes through a protocol-conformance
            // lookup, and a conformance lookup is exactly what is currently
            // crashing on this device.
            log("✗ \(name): \(String(describing: error))")
            throw error
        }
    }
}
