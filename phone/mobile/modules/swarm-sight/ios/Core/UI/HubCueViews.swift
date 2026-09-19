import SwiftUI
import SwarmCore

struct GuideBannerView: View {
    let banner: GuideBannerCue

    var body: some View {
        Label(banner.text, systemImage: symbol)
            .font(.title3.weight(.bold))
            .lineLimit(2)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
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
