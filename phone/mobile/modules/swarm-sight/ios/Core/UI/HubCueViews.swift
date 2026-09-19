import SwiftUI
import SwarmCore

/// Lobby, calibrate and end are whole-screen states; search and found are not.
struct PhaseCardView: View {
    let phase: String
    let alignment: RoomAligner.Source
    let lookingFor: String?
    let onPickSeat: () -> Void

    static func covers(_ phase: String) -> Bool { PhaseCardText.covers(phase) }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 44))
            Text(title).font(.title.bold())
            Text(detail)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if phase == "calibrate" {
                Label(alignmentText, systemImage: alignment == .none ? "circle.dashed" : "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(alignment == .none ? .orange : .green)
                if alignment != .marker {
                    Button("No marker nearby? Tap your spot", action: onPickSeat)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private var symbol: String {
        switch phase {
        case "lobby": "person.3.fill"
        case "calibrate": "scope"
        default: "flag.checkered"
        }
    }

    // The words live in SwarmCore so the console's mirror of this card matches.
    private var title: String { PhaseCardText.title(for: phase) }
    private var detail: String { PhaseCardText.detail(for: phase) }

    private var alignmentText: String {
        switch alignment {
        case .none: "Not located yet"
        case .seat: "Located from your spot"
        case .marker: "Locked to a marker"
        }
    }
}
