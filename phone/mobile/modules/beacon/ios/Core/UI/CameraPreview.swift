import CoreImage
import CoreVideo
import Observation
import SwiftUI
import UIKit

/// Hosts the live camera. On device the content is an `ARSCNView` that shares
/// the `ARSession` (see `ARKitPoseProvider`) — we do **not** re-render
/// `CVPixelBuffer`s through Core Image for the operator preview. That path
/// retained capture-pool buffers and tripped `_dispatch_assert_queue_fail` on
/// device (camera LED on, "waiting for the camera…", process halted).
@MainActor
@Observable
public final class CameraPreviewSource {
    /// Becomes true once the AR session has handed us its scene view.
    private(set) var isLive = false

    let container = CameraPreviewContainerView()

    /// Called after `ARSession.run` with the session's `ARSCNView`.
    public func attach(_ view: UIView) {
        container.setContent(view)
        isLive = true
    }

    public func clear() {
        container.setContent(nil)
        isLive = false
    }
}

public final class CameraPreviewContainerView: UIView {
    private weak var content: UIView?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContent(_ view: UIView?) {
        content?.removeFromSuperview()
        content = nil
        guard let view else { return }
        view.frame = bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(view)
        content = view
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        content?.frame = bounds
    }
}

struct CameraPreviewView: View {
    let source: CameraPreviewSource

    var body: some View {
        ZStack {
            CameraPreviewRepresentable(source: source)
            if !source.isLive {
                // Before the AR scene view is attached. Says which of the two
                // black screens this is: "no camera yet" vs a dark room.
                ZStack {
                    Color.hudVoid
                    Text("waiting for the camera…")
                        .font(TypeScale.footnote)
                        .foregroundStyle(.hudInkSecondary)
                }
                .cameraChrome()
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

private struct CameraPreviewRepresentable: UIViewRepresentable {
    let source: CameraPreviewSource

    func makeUIView(context: Context) -> CameraPreviewContainerView {
        source.container
    }

    func updateUIView(_ uiView: CameraPreviewContainerView, context: Context) {}
}
