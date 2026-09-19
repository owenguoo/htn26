import SwiftUI
import SwarmCore

/// The whole interface: a flash, an arrow, a status pill.
///
/// Everything it draws comes from `OverlayModel` in SwarmCore, so the decisions
/// — which way to point, when an arrow is stale, when to stop showing a flash —
/// are all tested. This file only turns that data into pixels.
struct OverlayView: View {
    let coordinator: AppCoordinator

    var body: some View {
        ZStack {
            // The thing the overlay overlays. Without it the operator is aiming
            // a camera they cannot see through.
            CameraPreviewView(source: coordinator.preview)

            // Where the venue thinks the markers are. If these outlines sit on
            // the printed markers and stay there as you walk, calibration is
            // good; if they slide off, that is the drift.
            MarkerOverlayView(projections: coordinator.markerProjections,
                              captureSize: coordinator.captureSize)

            if let arrow = coordinator.overlay.arrow {
                // A scrim, so white chevrons stay legible over a bright room.
                Color.black.opacity(0.35).ignoresSafeArea()
                ArrowView(arrow: arrow)
            }

            VStack {
                StatusPillView(pill: coordinator.overlay.pill)
                    .padding(.top, 8)
                Spacer()
                if let error = coordinator.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.yellow)
                        .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 16)

            // Last, and over everything: a flash the audience can see from the
            // back of the room is the point of the flash.
            if let flash = coordinator.overlay.flash {
                FlashView(flash: flash)
            }
        }
        .animation(.easeOut(duration: 0.12), value: coordinator.overlay.flash)
        .animation(.easeOut(duration: 0.08), value: coordinator.overlay.arrow)
    }
}
