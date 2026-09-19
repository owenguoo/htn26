import SwiftUI
import SwarmCore

/// Lobby, calibrate and end are whole-screen states; search and found are not.
struct PhaseCardView: View {
    let phase: String
    let alignment: RoomAligner.Source
    let lookingFor: String?
    let onPickSeat: () -> Void

    static func covers(_ phase: String) -> Bool { PhaseCardText.covers(phase) }

    /// The hero glyph grows with the operator's text size. It used to be a flat
    /// 44, which stayed 44 while the sentence under it doubled.
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 44

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(.ssAccent)
            Text(title).font(TypeScale.coverTitle)
            Text(detail)
                .font(TypeScale.detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if phase == "calibrate" {
                Label(alignmentText, systemImage: alignment == .none ? "circle.dashed" : "checkmark.circle.fill")
                    .font(TypeScale.action)
                    .foregroundStyle(alignment == .none ? .ssAttention : .ssOK)
                if alignment != .marker {
                    Button("No marker nearby? Tap your spot", action: onPickSeat)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .padding(Space.xxl)
        .frame(maxWidth: 340)
        // This card covers the whole screen while it is up, so the camera behind
        // it is not the point: a thicker material is what keeps `.secondary`
        // body text readable over whatever the lens happens to be pointed at.
        // Semantic, not pinned dark — a light-mode operator gets a light card.
        .background(Surface.card, in: Radius.rect(Radius.sheet))
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
