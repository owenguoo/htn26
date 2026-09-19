import SwiftUI
import SwarmCore

/// Points the operator at a target.
///
/// The bearing is radians clockwise from straight ahead, which is also SwiftUI's
/// rotation direction, so the rotation is the bearing with no sign flip. That
/// correspondence is the reason `Geometry.relativeBearing` uses this convention
/// rather than a mathematical counter-clockwise one.
struct ArrowView: View {
    let arrow: ArrowCue

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: arrow.isOnTarget ? "scope" : "arrow.up")
                .font(.system(size: 140, weight: .bold))
                .foregroundStyle(arrow.isOnTarget ? .green : .white)
                .rotationEffect(.radians(arrow.isOnTarget ? 0 : Double(arrow.bearingRadians)))
                .shadow(radius: 12)

            VStack(spacing: 6) {
                if let label = arrow.label {
                    Text(label)
                        .font(.title.weight(.semibold))
                }
                if let distance = arrow.distance {
                    Text(String(format: "%.1f m", distance))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if arrow.isOnTarget {
                    Text("In view")
                        .font(.headline)
                        .foregroundStyle(.green)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// An operator sweeping a room is not looking at the screen. Spoken
    /// directions are the fallback, so they have to say which way in words.
    private var accessibilityDescription: String {
        if arrow.isOnTarget { return "Target in view" }
        let degrees = Int(abs(arrow.bearingRadians) * 180 / .pi)
        let direction = arrow.bearingRadians > 0 ? "right" : "left"
        return "Turn \(degrees) degrees \(direction)"
    }
}
