import SwiftUI
import SwarmCore

/// Raise or lower the phone — the vertical half of a directional cue.
///
/// **"One HUD, two renderers" is satisfied, and it was checked rather than
/// assumed.** `OverlayModel` folds `ElevationCue.text` into `banner.text`
/// whenever the cue exists, and `HUDMirror.make` puts that banner straight into
/// `HubHUDMirror.banner` — so the operator console is already showing
/// "Look down 34°" in its pill at the moment this chevron appears. This view
/// renders no information the console lacks; it is the glance-speed form of a
/// sentence both renderers already have, the way `←` and `→` in the banner sit
/// on the side of the line the operator has to turn toward. That is why it
/// carries a glyph and the degrees and **not** a second copy of the sentence:
/// the words are the banner's job, in the one place the console draws them too.
///
/// If a dedicated `elev` field on the mirror is ever wanted — so the console can
/// draw its own chevron over the feed instead of only the words — that is a
/// `HubHUDMirror` change in SwarmCore and a `web/console.js` change on the
/// team's side, not something to add here first.
struct ElevationCueView: View {
    let cue: ElevationCue

    /// Grows with the operator's text size, like every other hero glyph here.
    @ScaledMetric(relativeTo: .title) private var symbolSize: CGFloat = 30

    var body: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: cue.isUp ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: symbolSize))
                // Meaning, not decoration: this is something for the operator to
                // do, which is what `.ssAttention` means everywhere else.
                .foregroundStyle(.ssAttention)
            Text("\(degrees)°")
                .font(TypeScale.readout)
                .foregroundStyle(.hudInk)
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(Surface.hudChrome, in: Radius.rect(Radius.card))
        // Toward the edge it is asking for: a cue that drifts the way the phone
        // has to move is readable before the number is.
        .offset(y: cue.isUp ? -Space.xxl * 2 : Space.xxl * 2)
        .cameraChrome()
        .accessibilityLabel(cue.text)
    }

    private var degrees: Int { Int(abs(cue.neededDegrees).rounded()) }
}

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
