import SwiftUI
import SwarmCore

/// Room metres ↔ view points. x is 0 on the stage centre line; y is 0 at the
/// stage wall, which is drawn at the top — the same way up as the dashboard.
struct FloorPlanGeometry {
    let room: HubRoom
    let size: CGSize

    private var scale: CGFloat { min(size.width / room.width, size.height / room.depth) }
    private var origin: CGPoint {
        CGPoint(x: (size.width - room.width * scale) / 2, y: (size.height - room.depth * scale) / 2)
    }

    func point(x: Double, y: Double) -> CGPoint {
        CGPoint(x: origin.x + (x + room.width / 2) * scale, y: origin.y + y * scale)
    }

    func room(at point: CGPoint) -> HubSeat {
        let x = (point.x - origin.x) / scale - room.width / 2
        let y = (point.y - origin.y) / scale
        return HubSeat(x: min(room.width / 2, max(-room.width / 2, x)), y: min(room.depth, max(0, y)))
    }

    func length(_ metres: Double) -> CGFloat { metres * scale }

    var bounds: CGRect {
        CGRect(origin: origin, size: CGSize(width: room.width * scale, height: room.depth * scale))
    }
}

/// The shared picture, small: where I am, where everyone else is, what has been
/// searched, where the pings are.
struct FloorPlanCanvas: View {
    let room: HubRoom
    let world: HubWorld?
    let me: RoomPose?
    let colorHex: String?
    let pings: [PingCue]
    var seat: HubSeat?

    var body: some View {
        Canvas { context, size in
            let plan = FloorPlanGeometry(room: room, size: size)
            context.fill(Path(roundedRect: plan.bounds, cornerRadius: 4), with: .color(.black.opacity(0.55)))

            if let coverage = world?.coverage {
                let cells = Array(coverage.cells.utf8)
                for index in cells.indices where cells[index] == UInt8(ascii: "1") {
                    let col = index % max(1, coverage.cols), row = index / max(1, coverage.cols)
                    let topLeft = plan.point(x: coverage.x0 + Double(col) * coverage.cell,
                                             y: Double(row) * coverage.cell)
                    let side = plan.length(coverage.cell)
                    context.fill(Path(CGRect(x: topLeft.x, y: topLeft.y, width: side + 0.5, height: side + 0.5)),
                                 with: .color(.green.opacity(0.28)))
                }
            }

            if let stage = room.stage {
                let topLeft = plan.point(x: -stage.width / 2, y: 0)
                context.fill(Path(CGRect(x: topLeft.x, y: topLeft.y, width: plan.length(stage.width),
                                         height: plan.length(stage.depth))),
                             with: .color(.white.opacity(0.35)))
            }
            context.stroke(Path(roundedRect: plan.bounds, cornerRadius: 4), with: .color(.white.opacity(0.6)),
                           lineWidth: 1)

            for peer in world?.phones ?? [] where peer.id != world?.me {
                dot(&context, at: plan.point(x: peer.x, y: peer.y), heading: peer.h, color: .white.opacity(0.8),
                    radius: 3)
            }
            for ping in pings {
                let p = plan.point(x: ping.x, y: ping.y)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.cyan))
            }
            if let candidate = world?.candidate {
                let p = plan.point(x: candidate.x, y: candidate.y)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                               with: .color(.red), lineWidth: 2)
            }
            if let seat {
                let p = plan.point(x: seat.x, y: seat.y)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                               with: .color(.orange), lineWidth: 2)
            }
            if let me {
                dot(&context, at: plan.point(x: me.x, y: me.y), heading: me.heading,
                    color: Color(hex: colorHex) ?? .yellow, radius: 5)
            }
        }
    }

    private func dot(_ context: inout GraphicsContext, at point: CGPoint, heading: Double?, color: Color,
                     radius: CGFloat) {
        if let heading {
            // Heading 0 faces the stage, which is up; clockwise from there.
            let angle = heading * .pi / 180
            let tip = CGPoint(x: point.x + sin(angle) * radius * 3.2, y: point.y - cos(angle) * radius * 3.2)
            var cone = Path()
            cone.move(to: point)
            cone.addLine(to: tip)
            context.stroke(cone, with: .color(color), lineWidth: 2)
        }
        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                            width: radius * 2, height: radius * 2)), with: .color(color))
    }
}

struct MiniMapView: View {
    let room: HubRoom
    let world: HubWorld?
    let me: RoomPose?
    let colorHex: String?
    let pings: [PingCue]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            FloorPlanCanvas(room: room, world: world, me: me, colorHex: colorHex, pings: pings)
            if let searched = world?.searched {
                Text("\(Int((searched * 100).rounded()))% searched"
                     + (world?.stats?.rank.map { " · rank \($0)" } ?? ""))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2)
            }
        }
    }
}

/// The fallback for a room with no marker in sight: tap where you are standing,
/// face the stage, confirm. Mirrors the web phone's seat map.
struct SeatPickerView: View {
    let room: HubRoom
    let world: HubWorld?
    let current: RoomPose?
    let onSeat: (HubSeat) -> Void
    let onConfirm: () async -> Bool
    let onClose: () -> Void

    @State private var seat: HubSeat?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Where are you standing?").font(.title3.bold())
                Spacer()
                Button("Close", action: onClose)
            }
            Text("STAGE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                FloorPlanCanvas(room: room, world: world, me: current, colorHex: nil, pings: [], seat: seat)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        let picked = FloorPlanGeometry(room: room, size: geometry.size).room(at: tap.location)
                        seat = picked
                        message = nil
                        onSeat(picked)
                    })
            }
            .aspectRatio(room.width / max(1, room.depth), contentMode: .fit)

            if let message {
                Text(message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Button {
                Task {
                    if await onConfirm() {
                        onClose()
                    } else {
                        message = "Hold the phone upright, facing the stage, and try again. "
                            + "(If a marker has already locked, you don't need this.)"
                    }
                }
            } label: {
                Text("I'm on my spot, facing the stage")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(seat == nil)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding(16)
    }
}
