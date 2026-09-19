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

    public init(_ buffer: CVPixelBuffer) {
        self.buffer = buffer
    }
}
