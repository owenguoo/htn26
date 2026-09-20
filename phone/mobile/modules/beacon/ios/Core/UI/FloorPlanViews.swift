import SwiftUI
import SwarmCore

private enum FloorPlanMarker {
    /// Matches the console marker system: 22 points outside-to-outside with a
    /// 2-point border, and four points of air before any attached label.
    static let radius: CGFloat = 10
    static let stroke: CGFloat = 2
    static let labelGap: CGFloat = 4
}

/// Room metres ↔ view points. x is 0 on the stage centre line; y is 0 at the
/// stage wall, which is drawn at the top — the same way up as the console.
///
/// Two modes. With no `focus` the whole room is fitted into the view, which is
/// what the seat picker needs. With a `focus` the view is a fixed-size window
/// of `metresAcross` centred on that point: the map scrolls under the operator
/// instead of the operator walking off the edge of it. That matters more than
/// it sounds — `room.json` is a nominal 20 × 15 m, and real rooms, seat-tap
/// origins and drift all put people outside it.
struct FloorPlanGeometry {
    let room: HubRoom
    let size: CGSize
    var focus: (x: Double, y: Double)?
    var metresAcross: Double = 12

    private var scale: CGFloat {
        focus == nil ? min(size.width / room.width, size.height / room.depth) : size.width / metresAcross
    }

    /// View position of room (−width/2, 0): the stage-left corner of the stage wall.
    private var origin: CGPoint {
        if let focus {
            return CGPoint(x: size.width / 2 - (focus.x + room.width / 2) * scale,
                           y: size.height / 2 - focus.y * scale)
        }
        return CGPoint(x: (size.width - room.width * scale) / 2, y: (size.height - room.depth * scale) / 2)
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

    /// The room's outline, wherever that falls — partly or wholly off-view when following.
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
    /// Keep `me` in the middle and scroll the room underneath.
    var followsMe = false

    var body: some View {
        Canvas { context, size in
            let plan = FloorPlanGeometry(room: room, size: size,
                                         focus: followsMe ? me.map { ($0.x, $0.y) } : nil)
            if followsMe {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(MapInk.outside))
            }
            context.fill(Path(roundedRect: plan.bounds, cornerRadius: 4), with: .color(MapInk.floor))

            if let coverage = world?.coverage {
                let cells = Array(coverage.cells.utf8)
                let side = plan.length(coverage.cell)
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: max(1.5, side * 0.45)))
                    for index in cells.indices where cells[index] == UInt8(ascii: "1") {
                        let col = index % max(1, coverage.cols), row = index / max(1, coverage.cols)
                        let centre = plan.point(x: coverage.x0 + (Double(col) + 0.5) * coverage.cell,
                                                y: (Double(row) + 0.5) * coverage.cell)
                        let radius = max(2, side * 0.9)
                        layer.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                          width: radius * 2, height: radius * 2)),
                                   with: .color(MapInk.searched))
                    }
                }
            }

            if let stage = room.stage {
                let topLeft = plan.point(x: -stage.width / 2, y: 0)
                context.fill(Path(CGRect(x: topLeft.x, y: topLeft.y, width: plan.length(stage.width),
                                         height: plan.length(stage.depth))),
                             with: .color(MapInk.stage))
            }
            context.stroke(Path(roundedRect: plan.bounds, cornerRadius: 4), with: .color(MapInk.outline),
                           lineWidth: 1.25)

            for peer in world?.phones ?? [] where peer.id != world?.me {
                searcher(&context, at: plan.point(x: peer.x, y: peer.y), heading: peer.h, number: peer.i)
            }
            for ping in pings {
                let p = plan.point(x: ping.x, y: ping.y)
                var diamond = Path()
                diamond.move(to: CGPoint(x: p.x, y: p.y - 7))
                diamond.addLine(to: CGPoint(x: p.x + 7, y: p.y))
                diamond.addLine(to: CGPoint(x: p.x, y: p.y + 7))
                diamond.addLine(to: CGPoint(x: p.x - 7, y: p.y))
                diamond.closeSubpath()
                context.fill(diamond, with: .color(MapInk.ping))
            }
            if let candidate = world?.candidate {
                let p = plan.point(x: candidate.x, y: candidate.y)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)),
                               with: .color(MapInk.candidateHalo), lineWidth: FloorPlanMarker.stroke)
                person(&context, at: p, color: MapInk.candidateRing)
            }
            if let seat {
                let p = plan.point(x: seat.x, y: seat.y)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                               with: .color(MapInk.seatRing), lineWidth: 2)
            }
            if let me {
                let myIndex = world?.phones?.first(where: { $0.id == world?.me })?.i
                searcher(&context, at: plan.point(x: me.x, y: me.y), heading: me.heading, number: myIndex)
            }
        }
    }

    private func searcher(_ context: inout GraphicsContext, at point: CGPoint, heading: Double?, number: Int?) {
        if let heading {
            // Heading 0 faces the stage, which is up; clockwise from there.
            let angle = heading * .pi / 180
            let direction = CGVector(dx: sin(angle), dy: -cos(angle))
            let side = CGVector(dx: cos(angle), dy: sin(angle))
            let tip = CGPoint(x: point.x + direction.dx * 16, y: point.y + direction.dy * 16)
            let base = CGPoint(x: point.x + direction.dx * 8, y: point.y + direction.dy * 8)
            var pointer = Path()
            pointer.move(to: tip)
            pointer.addLine(to: CGPoint(x: base.x + side.dx * 5, y: base.y + side.dy * 5))
            pointer.addLine(to: CGPoint(x: base.x - side.dx * 5, y: base.y - side.dy * 5))
            pointer.closeSubpath()
            context.fill(pointer, with: .color(MapInk.searcher))
        }
        let circle = Path(ellipseIn: CGRect(x: point.x - FloorPlanMarker.radius,
                                            y: point.y - FloorPlanMarker.radius,
                                            width: FloorPlanMarker.radius * 2,
                                            height: FloorPlanMarker.radius * 2))
        context.fill(circle, with: .color(MapInk.searcher))
        context.stroke(circle, with: .color(MapInk.markerBorder), lineWidth: FloorPlanMarker.stroke)
        if let number {
            context.draw(Text(String(number)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(MapInk.markerBorder), at: point)
        }
    }

    private func person(_ context: inout GraphicsContext, at point: CGPoint, color: Color) {
        let circle = Path(ellipseIn: CGRect(x: point.x - FloorPlanMarker.radius,
                                            y: point.y - FloorPlanMarker.radius,
                                            width: FloorPlanMarker.radius * 2,
                                            height: FloorPlanMarker.radius * 2))
        context.fill(circle, with: .color(MapInk.markerBorder))
        context.stroke(circle, with: .color(color), lineWidth: FloorPlanMarker.stroke)
        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.7, y: point.y - 6.2, width: 5.4, height: 5.4)),
                     with: .color(color))
        context.fill(Path(roundedRect: CGRect(x: point.x - 4.5, y: point.y + 0.5, width: 9, height: 5.5),
                          cornerRadius: 3), with: .color(color))
    }
}

struct MiniMapView: View {
    let room: HubRoom
    let world: HubWorld?
    let me: RoomPose?
    let colorHex: String?
    let pings: [PingCue]

    var body: some View {
        FloorPlanCanvas(room: room, world: world, me: me, colorHex: colorHex, pings: pings, followsMe: true)
            .clipShape(Radius.rect(Radius.plate))
            .overlay(Radius.rect(Radius.plate).stroke(MapInk.plateBorder, lineWidth: 1))
            .overlay(alignment: .bottom) {
            if let searched = world?.searched {
                VStack(spacing: Space.xs) {
                    HStack {
                        Text("Searched")
                            .foregroundStyle(MapInk.labelSecondary)
                        Spacer(minLength: Space.xs)
                        Text("\(Int((searched * 100).rounded()))%")
                            .foregroundStyle(MapInk.label)
                    }
                    .font(TypeScale.readout)
                    ProgressView(value: min(1, max(0, searched)))
                        .progressViewStyle(.linear)
                        .tint(MapInk.searcher)
                        .accessibilityLabel("Area searched")
                        .accessibilityValue("\(Int((searched * 100).rounded())) percent")
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.s)
                .background(MapInk.legendBackground, in: Radius.rect(Radius.plate))
                .padding(Space.xs)
            }
            }
        .cameraChrome()
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
    /// Non-nil only while a marker owns the alignment.
    var onResetOrigin: (() -> Void)?
    let onClose: () -> Void

    @State private var seat: HubSeat?
    @State private var message: String?

    var body: some View {
        VStack(spacing: Space.m) {
            HStack {
                Text("Map").font(TypeScale.sheetTitle)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Text("STAGE")
                .font(TypeScale.readout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("The stage is at the top of this map")
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
            // The plan is the same drawn artefact as the mini-map — white
            // strokes on a dark floor — so it keeps its own ink whichever way
            // the card around it resolves.
            .clipShape(Radius.rect(Radius.plate))
            .cameraChrome()
            .accessibilityLabel("Room plan. Tap where you are standing.")

            if let message {
                Text(message)
                    .font(TypeScale.footnote)
                    .foregroundStyle(.ssAttention)
                    .multilineTextAlignment(.center)
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
                    .font(TypeScale.action)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(seat == nil)

            if let onResetOrigin {
                // The phone re-anchors by itself when markers keep disagreeing
                // with it; this is for the operator who can see it is wrong now.
                Button(role: .destructive) {
                    onResetOrigin()
                    onClose()
                } label: {
                    Label("Position looks wrong — forget the marker lock", systemImage: "arrow.counterclockwise")
                        .font(TypeScale.footnote)
                }
            }
        }
        .padding(Space.xl)
        // Not a presented sheet, on purpose: this card sits over a live camera
        // the operator is still aiming, and a sheet would cover the preview.
        .background(Surface.card, in: Radius.rect(Radius.sheet))
        .padding(Space.l)
    }
}
