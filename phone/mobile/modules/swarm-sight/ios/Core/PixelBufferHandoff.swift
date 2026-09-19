import CoreVideo
import Foundation

/// Moves a `CVPixelBuffer` from the ARSession delegate queue to the encoder.
///
/// Swift cannot prove a `CVPixelBuffer` is safe to send, and in general it is
/// not: two threads locking the same base address at once is a data race. What
/// makes it safe here is exclusivity, which this type exists to name. The
/// delegate hands the buffer over and never looks at it again; the encoder is
/// the only reader; and only the buffer is passed, never the `ARFrame` that
/// vended it, because an `ARFrame` retained beyond its callback stalls the
/// session.
///
/// If a second reader ever appears, this wrapper is a lie and the buffer must be
/// copied instead.
public struct PixelBufferHandoff: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    /// `frame.timestamp` for *this* buffer, in the CACurrentMediaTime domain.
    ///
    /// The latency trace must be stamped from this rather than from the pose
    /// that triggered the capture. Buffers are staged at 60 Hz and tickets are
    /// issued at 10 Hz, so by the time an encode starts the staged buffer is
    /// usually a frame or three newer than the pose — up to 50 ms, against a
    /// 50 ms budget. Stamping from the pose made the client look slower than it
    /// is and hid where the time actually goes.
    public let deviceTimestamp: Double

    public init(_ buffer: CVPixelBuffer, deviceTimestamp: Double) {
        self.buffer = buffer
        self.deviceTimestamp = deviceTimestamp
    }
}
