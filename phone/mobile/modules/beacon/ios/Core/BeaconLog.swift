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
    public static let isEnabled = true

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
    public static func step<T>(_ name: String, _ body: () async throws -> T) async rethrows -> T {
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
