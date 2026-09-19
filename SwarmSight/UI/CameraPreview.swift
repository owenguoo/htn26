import CoreImage
import CoreVideo
import Metal
import Observation
import SwiftUI

/// Shows what the camera sees, behind the overlay.
///
/// Without this the app is a black screen with the camera light on, and an
/// operator cannot aim at a marker — which reads as "tracking is broken" when
/// what is actually happening is that no marker has ever been in frame.
///
/// Note what is *not* imported: ARKit. The preview renders the same
/// `CVPixelBuffer` the provider already copies out for the encoder, so the one
/// ARKit file stays the only one, and the operator sees exactly what the server
/// sees rather than a separate camera feed that might disagree.
@MainActor
@Observable
public final class CameraPreviewSource {
    private(set) var image: CGImage?
    /// Frames dropped because a render was still running. Expected under load;
    /// the preview is the first thing that should suffer.
    private(set) var dropped = 0

    private let context: CIContext
    private let queue = DispatchQueue(label: "swarmsight.preview", qos: .userInitiated)
    private var rendering = false
    private var nextDue: Double = 0

    /// Well below the 60 Hz ARKit delivers. The preview exists so a human can
    /// aim; it does not need to be smooth, and every millisecond it takes is a
    /// millisecond stolen from the latency budget that does matter.
    private let targetHz: Double = 15
    /// Small enough that the render is cheap, large enough to aim by.
    private let targetWidth = 480

    init() {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// Called from the ARSession delegate queue with the same buffer the encoder
    /// will get. Drops rather than queues, exactly like the encoder: a preview
    /// that falls behind is showing the past, which is worse than showing less.
    nonisolated func offer(_ handoff: PixelBufferHandoff, now: Double) {
        Task { @MainActor [weak self] in
            self?.consider(handoff, now: now)
        }
    }

    private func consider(_ handoff: PixelBufferHandoff, now: Double) {
        guard !rendering, now >= nextDue else {
            if rendering { dropped += 1 }
            return
        }
        nextDue = now + 1.0 / targetHz
        rendering = true

        let context = self.context
        let width = targetWidth
        queue.async { [weak self] in
            let rendered = Self.render(handoff.buffer, context: context, targetWidth: width)
            Task { @MainActor [weak self] in
                self?.image = rendered ?? self?.image
                self?.rendering = false
            }
        }
    }

    private nonisolated static func render(_ buffer: CVPixelBuffer, context: CIContext,
                                           targetWidth: Int) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        // ARKit's capture is in sensor orientation, which is landscape-right for
        // a phone held upright. `.right` turns it the way the operator is
        // holding it.
        let oriented = image.oriented(.right)
        let scale = CGFloat(targetWidth) / oriented.extent.width
        let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent)
    }
}

struct CameraPreviewView: View {
    let source: CameraPreviewSource

    var body: some View {
        GeometryReader { geometry in
            if let image = source.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                // Before the first frame. Says which of the two black screens
                // this is, because "no camera yet" and "camera showing a dark
                // room" look identical and mean very different things.
                ZStack {
                    Color.black
                    Text("waiting for the camera…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .ignoresSafeArea()
    }
}
