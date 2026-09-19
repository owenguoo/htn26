import CoreImage
import CoreVideo
import Foundation
import Metal
import SwarmCore
import UIKit

/// `CVPixelBuffer` (YCbCr biplanar) → JPEG.
///
/// Two things matter here and both are easy to get wrong:
///
/// - **One `CIContext`, reused.** Allocating one per frame drops you to about
///   3 fps. It is created once and held for the life of the app.
/// - **A serial background queue with drop-if-busy.** The queue policy lives in
///   `FrameEncodePipeline` in SwarmCore, where it is tested; this class only
///   does pixels.
///
/// `frame.capturedImage` is `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`.
/// CoreImage handles the conversion, but only if the buffer is handed over
/// before the frame is released — so the caller copies or retains the pixel
/// buffer itself, never the `ARFrame`.
///
// DEVICE-VERIFY: a human must measure, on hardware, the achieved frame rate and
// mean encode time at 640, 960 and 1280 px, and pick a resolution from those
// numbers rather than from this comment; and confirm the drop count under load
// is non-zero but well below the submit count. DEVICE_CHECKLIST.md item 9.
public final class CoreImageFrameEncoder: FrameEncoding, @unchecked Sendable {
    private let context: CIContext
    private let queue = DispatchQueue(label: "swarmsight.encode", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: PixelBufferHandoff?

    public init() {
        // Colour management off: it buys nothing for a JPEG a detector will run
        // over, and costs milliseconds a frame.
        //
        // Backed by Metal explicitly. `useSoftwareRenderer: false` alone does
        // not guarantee a GPU context, and the YCbCr conversion plus downscale
        // is exactly the work a GPU does for free and a CPU does slowly — this
        // is the single biggest term in the capture-to-encode budget.
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options.merging([.useSoftwareRenderer: false]) { a, _ in a })
        }
    }

    /// The device timestamp of the buffer the last `encode` consumed, so the
    /// caller can stamp the trace from the frame that was actually encoded.
    public private(set) var lastEncodedTimestamp: Double = 0

    /// Hands the encoder the buffer for the next `encode` call. Called from the
    /// ARSession delegate queue; the buffer is retained here and the `ARFrame`
    /// is not.
    public func stage(_ pixelBuffer: PixelBufferHandoff) {
        lock.lock()
        // Latest wins. A buffer that has been sitting here while an encode ran
        // describes a moment that has passed.
        pending = pixelBuffer
        lock.unlock()
    }

    private func takePending() -> PixelBufferHandoff? {
        lock.lock()
        defer {
            pending = nil
            lock.unlock()
        }
        return pending
    }

    public func encode(_ request: FrameEncodeRequest) async throws -> EncodedFrame {
        guard let handoff = takePending() else { throw EncodeError.noStagedFrame }
        lastEncodedTimestamp = handoff.deviceTimestamp
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [context] in
                do {
                    continuation.resume(returning: try Self.encode(handoff.buffer,
                                                                   request: request,
                                                                   context: context))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func encode(_ pixelBuffer: CVPixelBuffer,
                               request: FrameEncodeRequest,
                               context: CIContext) throws -> EncodedFrame {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let captureWidth = Int(image.extent.width)
        let captureHeight = Int(image.extent.height)
        let factor = request.configuration.scaleFactor(forCaptureWidth: captureWidth,
                                                       height: captureHeight)
        let scaled = factor < 1
            ? image.transformed(by: CGAffineTransform(scaleX: CGFloat(factor), y: CGFloat(factor)))
            : image

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw EncodeError.noColorSpace
        }
        guard let data = context.jpegRepresentation(
            of: scaled,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                        request.configuration.quality])
        else {
            throw EncodeError.jpegFailed
        }

        let size = request.configuration.outputSize(forCaptureWidth: captureWidth, height: captureHeight)
        // The intrinsics must describe the image that is actually being sent.
        // Capture-resolution intrinsics with a downscaled JPEG is a silent
        // factor-of-two error in every depth estimate the server produces.
        let intrinsics = request.intrinsics.map {
            CameraIntrinsics(fx: $0.fx, fy: $0.fy, cx: $0.cx, cy: $0.cy,
                             imageWidth: captureWidth, imageHeight: captureHeight)
                .scaled(by: factor)
        }
        return EncodedFrame(frameID: request.frameID, jpeg: data,
                            width: size.width, height: size.height, intrinsics: intrinsics)
    }

    public enum EncodeError: Error, LocalizedError {
        case noStagedFrame
        case noColorSpace
        case jpegFailed

        public var errorDescription: String? {
            switch self {
            case .noStagedFrame: "No pixel buffer was staged for this frame."
            case .noColorSpace: "Could not create an sRGB colour space."
            case .jpegFailed: "CIContext could not produce a JPEG."
            }
        }
    }
}
