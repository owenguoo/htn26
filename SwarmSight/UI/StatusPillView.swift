import SwiftUI
import SwarmCore

/// Tracking state, connection, in-flight, drops, thermal, seconds since the last
/// marker correction. Six numbers, one line, readable at arm's length.
struct StatusPillView: View {
    let pill: StatusPill

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)

            Text(pill.sessionState.rawValue)
                .font(.caption.weight(.semibold))

            Divider().frame(height: 12)

            field("conf", String(format: "%.2f", pill.confidence))
            field("fix", correctionText)
            field("net", pill.connection.rawValue)
            field("air", "\(pill.inFlight)")
            field("drop", "\(pill.dropped)")

            if pill.thermalState >= .fair {
                Image(systemName: "thermometer.high")
                    .foregroundStyle(pill.thermalState >= .serious ? .red : .orange)
            }
            if pill.isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(statusColor.opacity(0.6), lineWidth: 1))
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(name).foregroundStyle(.secondary)
            Text(value)
        }
    }

    /// nil means this phone has never been corrected, so nothing it reports can
    /// be fused with anyone else's. That is not the same as "0 s ago".
    private var correctionText: String {
        guard let seconds = pill.secondsSinceCorrection else { return "never" }
        return String(format: "%.0fs", seconds)
    }

    private var statusColor: Color {
        if pill.needsAttention { return pill.isStale || pill.connection != .online ? .red : .orange }
        return .green
    }
}
