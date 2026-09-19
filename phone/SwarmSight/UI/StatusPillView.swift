import SwiftUI
import SwarmCore

/// Tracking state, connection, in-flight, drops, thermal, seconds since the last
/// marker correction — one line, readable at arm's length in a dark room.
///
/// Everything here is `lineLimit(1)` and `fixedSize`. A wrapping status pill is
/// worse than no status pill: the first version of this broke words mid-syllable
/// ("cali-brat-ing", "dro p 0") and an operator sweeping a room has no time to
/// parse that. Where the width does not fit, the text scales down rather than
/// reflowing.
struct StatusPillView: View {
    let pill: StatusPill

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            Text(pill.sessionState.rawValue)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)

            Divider().frame(height: 11)

            field("conf", String(format: "%.2f", pill.confidence))
            field("fix", correctionText)
            field("air", "\(pill.inFlight)")
            field("drop", "\(pill.dropped)")

            Image(systemName: connectionSymbol)
                .foregroundStyle(pill.connection == .online ? .green : .orange)
            if pill.thermalState >= .fair {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(pill.thermalState >= .serious ? .red : .orange)
            }
            if pill.isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(statusColor.opacity(0.6), lineWidth: 1))
        // Scale the whole pill down before anything inside it is allowed to wrap.
        .scaledToFit()
        .minimumScaleFactor(0.55)
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(name).foregroundStyle(.secondary)
            Text(value)
        }
        .lineLimit(1)
        .fixedSize()
    }

    /// nil means this phone has never been corrected, so nothing it reports can
    /// be fused with anyone else's. That is not the same as "0 s ago".
    private var correctionText: String {
        // Located from a seat tap: there is no marker fix, and that is fine.
        if pill.alignment == .seat, pill.secondsSinceCorrection == nil { return "seat" }
        guard let seconds = pill.secondsSinceCorrection else { return "never" }
        return String(format: "%.0fs", seconds)
    }

    private var connectionSymbol: String {
        switch pill.connection {
        case .online: "wifi"
        case .connecting, .reconnecting: "wifi.exclamationmark"
        case .offline: "wifi.slash"
        }
    }

    private var statusColor: Color {
        if pill.needsAttention { return pill.isStale || pill.connection != .online ? .red : .orange }
        return .green
    }
}
