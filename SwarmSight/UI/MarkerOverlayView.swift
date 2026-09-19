import SwiftUI
import SwarmCore

/// Draws where the venue *believes* each marker is, over the live camera.
///
/// This is the most direct accuracy check there is. If the outline sits on the
/// printed marker and stays glued to it while you walk around, the origin, the
/// scale and the tracking are all correct. If it slides off as you move, you are
/// watching drift happen, in the units that matter, without waiting for a number
/// to come back from anywhere.
///
/// The hard part is not the projection — that is tested in SwarmCore — but
/// mapping captured-image pixels onto the view, because the preview is rotated
/// for portrait and cropped to fill. Getting that wrong produces an overlay that
/// is subtly offset everywhere, which looks like bad calibration and is not.
struct MarkerOverlayView: View {
    let projections: [Projection.MarkerProjection]
    /// The resolution the intrinsics describe, i.e. the captured frame.
    let captureSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let transform = ImageToViewTransform(capture: captureSize, view: geometry.size)
            ForEach(projections, id: \.markerID) { projection in
                let points = projection.outline.map(transform.callAsFunction)
                ZStack {
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                        path.closeSubpath()
                    }
                    .stroke(colour(for: projection), lineWidth: 3)

                    // A tick on the top edge, so an upside-down or mirrored
                    // overlay is obvious rather than merely wrong.
                    if points.count == 4 {
                        Path { path in
                            path.move(to: points[0])
                            path.addLine(to: points[1])
                        }
                        .stroke(colour(for: projection), lineWidth: 8)
                    }

                    if let centre = centre(of: points) {
                        Text(label(for: projection))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(colour(for: projection).opacity(0.85), in: Capsule())
                            .foregroundStyle(.black)
                            .position(centre)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func centre(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func label(for projection: Projection.MarkerProjection) -> String {
        String(format: "%@  %.2fm  %.0f°", projection.markerID.replacingOccurrences(
            of: "marker-", with: ""), projection.distance, projection.obliquityDegrees)
    }

    /// Green where ARKit should be able to detect it, amber where the angle or
    /// distance makes detection unlikely — so "why is it not locking" has an
    /// answer on screen rather than being guesswork.
    private func colour(for projection: Projection.MarkerProjection) -> Color {
        if projection.obliquityDegrees > 60 || projection.distance > 4.5 { return .orange }
        return .green
    }
}

/// Maps a point in the captured image onto the preview as it is actually drawn.
///
/// Two things happen between the sensor and the screen and both must be undone
/// here. The capture is in sensor orientation — landscape for a phone held
/// upright — and the preview rotates it 90° clockwise. Then it is scaled to
/// *fill* the view and centre-cropped, so one axis overflows.
struct ImageToViewTransform {
    private let scale: CGFloat
    private let offset: CGSize
    private let rotatedSize: CGSize
    private let captureSize: CGSize

    init(capture: CGSize, view: CGSize) {
        captureSize = capture
        // After a 90° rotation the image's width and height swap.
        rotatedSize = CGSize(width: capture.height, height: capture.width)
        guard rotatedSize.width > 0, rotatedSize.height > 0 else {
            scale = 1
            offset = .zero
            return
        }
        // `.fill` uses the larger scale, so the shorter axis overflows and is
        // cropped equally at both ends.
        scale = max(view.width / rotatedSize.width, view.height / rotatedSize.height)
        offset = CGSize(width: (view.width - rotatedSize.width * scale) / 2,
                        height: (view.height - rotatedSize.height * scale) / 2)
    }

    func callAsFunction(_ point: CGPoint) -> CGPoint {
        // 90° clockwise: a pixel at (x, y) in a W×H image lands at (H−y, x).
        let rotated = CGPoint(x: captureSize.height - point.y, y: point.x)
        return CGPoint(x: rotated.x * scale + offset.width,
                       y: rotated.y * scale + offset.height)
    }
}
