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

struct GuideBannerView: View {
    let banner: GuideBannerCue

    var body: some View {
        Label(banner.text, systemImage: symbol)
            .font(TypeScale.action.weight(.bold))
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.9), in: Radius.rect(Radius.card))
            .foregroundStyle(.black)
    }

    private var symbol: String {
        switch banner.kind {
        case "go": "figure.walk"
        case "respond": "exclamationmark.triangle.fill"
        case "look": "eye.fill"
        default: banner.onTarget ? "checkmark.circle.fill" : "arrow.triangle.turn.up.right.circle.fill"
        }
    }

    private var tint: Color {
        if banner.kind == "respond" { return Color(red: 1, green: 0.36, blue: 0.45) }
        return banner.onTarget ? Color(red: 0.48, green: 0.9, blue: 0.51) : .white
    }
}

struct ToastView: View {
    let toast: ToastCue

    var body: some View {
        Label(toast.text, systemImage: "megaphone.fill")
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Boxes from `/api/detections`: fractions of the frame the hub received, which
/// is the portrait JPEG — the capture rotated upright.
struct DetectionBoxesView: View {
    let cue: DetectionsCue
    let captureSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let transform = ImageToViewTransform(capture: captureSize, view: geometry.size)
            ForEach(Array(cue.boxes.enumerated()), id: \.offset) { _, box in
                let likely = cue.rehearsal || (box.similarity.map { $0 >= (cue.threshold ?? 1) } ?? false)
                let tint: Color = cue.rehearsal ? .yellow : (likely ? .red : .white)
                let rect = transform.rect(uprightFractionX: box.x, y: box.y, width: box.w, height: box.h)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(tint, lineWidth: 3)
                    if let label = box.label {
                        Text(cue.rehearsal ? "Rehearsal · \(label)" :
                            String(format: "%@ · Similarity %.2f · confidence %.0f%%", label, box.similarity ?? 0, (box.detectionScore ?? 0) * 100))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(tint)
                            .foregroundStyle(.black)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// An operator's ping, pinned to the floor where they put it. In view it is a
/// diamond on the spot; out of view it is a chevron on the edge to turn toward.
struct PingMarkersView: View {
    let pings: [PingCue]
    let captureSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let transform = ImageToViewTransform(capture: captureSize, view: geometry.size)
            ForEach(pings) { ping in
                let onScreen = ping.imagePoint.map(transform.callAsFunction)
                    .flatMap { geometry.frame(in: .local).insetBy(dx: 24, dy: 60).contains($0) ? $0 : nil }
                if let point = onScreen {
                    VStack(spacing: 2) {
                        Image(systemName: "diamond.fill").font(.title2)
                        Text(caption(ping)).font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.cyan)
                    .shadow(color: .black, radius: 3)
                    .position(point)
                } else if let bearing = ping.bearingRadians {
                    let right = bearing > 0
                    HStack(spacing: 4) {
                        if !right { Image(systemName: "chevron.left.2") }
                        Text(caption(ping)).font(.caption.weight(.bold))
                        if right { Image(systemName: "chevron.right.2") }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.cyan, in: Capsule())
                    .foregroundStyle(.black)
                    .position(x: right ? geometry.size.width - 70 : 70, y: geometry.size.height * 0.62)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func caption(_ ping: PingCue) -> String {
        ping.distance.map { String(format: "%@ · %.1f m", ping.label, $0) } ?? ping.label
    }
}

/// Lobby, calibrate and end are whole-screen states; search and found are not.
///
/// The calibrate card only exists while this phone is *not* located
/// (`PhaseCardText.covers(_:alignment:)`), so it has nothing to report about
/// alignment and nothing to offer but the one instruction. It used to carry a
/// "Not located yet" row in orange under a heading that already said Calibrate,
/// a "Locked to a marker ✓" row that is now unreachable because the card is
/// gone by then, and a second calibration method.
struct PhaseCardView: View {
    let phase: String
    let lookingFor: String?
    /// The calibrate prompt has just been answered: this phone is located.
    /// Same card, a green checkmark where the scope was, held for a moment by
    /// `OperatorView` so that locking on reads as an answer rather than as the
    /// screen going away on its own.
    var confirmed = false
    /// This phone had a lock and lost it, so the prompt says "Recalibrate".
    var again = false

    static func covers(_ phase: String) -> Bool { PhaseCardText.covers(phase) }

    /// The hero glyph grows with the operator's text size. It used to be a flat
    /// 44, which stayed 44 while the sentence under it doubled.
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 44

    var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize))
                .foregroundStyle(confirmed ? Color.ssOK : Color.ssAccent)
                // The glyph is the whole message at a glance, so it gets the
                // one bit of motion on this card.
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(TypeScale.coverTitle)
            Text(detail)
                .font(TypeScale.detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
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
        if confirmed { return "checkmark.circle.fill" }
        switch phase {
        case "lobby": return "person.3.fill"
        case "calibrate": return "scope"
        default: return "flag.checkered"
        }
    }

    // The words live in SwarmCore so the console's mirror of this card matches.
    private var title: String {
        confirmed ? PhaseCardText.confirmedTitle : PhaseCardText.title(for: phase, again: again)
    }
    private var detail: String {
        confirmed ? PhaseCardText.confirmedDetail : PhaseCardText.detail(for: phase, again: again)
    }
}

/// Where to point the camera while calibrating.
///
/// The calibrate card used to be the whole answer: a sentence saying "point at
/// a printed marker" over a camera the card itself was covering. The operator
/// could not see what they were aiming at, which on a phone held at arm's
/// length across a room is most of the task.
///
/// Four corner brackets and nothing between them: a closed box reads as a crop
/// and invites people to fill it exactly, and the marker only has to land
/// inside. Square caps and mitred corners, so the marks are four right angles
/// rather than anything rounded. The tint is `MARKER_COLOR` — the same purple
/// the map draws the alignment marker in and the compass chip wears — so the
/// thing being hunted and the place to put it are named the same colour.
struct MarkerReticleView: View {
    /// Breathing, slowly. Enough to read as live while the operator moves the
    /// phone around; not enough to compete with a marker entering the frame.
    @State private var breathing = false

    private static let side: CGFloat = 230
    private static let arm: CGFloat = 46
    /// Centre of the reticle to the centre of a corner arm.
    private static let reach: CGFloat = (side - arm) / 2

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Bracket()
                    .stroke(MapInk.marker, style: StrokeStyle(lineWidth: 4, lineCap: .square,
                                                              lineJoin: .miter))
                    .frame(width: Self.arm, height: Self.arm)
                    .rotationEffect(.degrees(Double(index) * 90))
                    .offset(x: index == 0 || index == 3 ? -Self.reach : Self.reach,
                            y: index < 2 ? -Self.reach : Self.reach)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .shadow(color: .black.opacity(0.45), radius: 6)
        .scaleEffect(breathing ? 1.03 : 0.99)
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathing)
        .onAppear { breathing = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One corner: an L drawn top-left, rotated into the other three.
    private struct Bracket: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            return path
        }
    }
}
