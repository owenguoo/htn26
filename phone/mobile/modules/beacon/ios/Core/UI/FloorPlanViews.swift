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
/// **The stage lives at negative y, outside the room rectangle.** That is
/// `web/room.js` `bounds()`: `y0 = -stage.depth`, `y1 = room.depth`. The room
/// outline starts at y = 0 and the stage block sits above it, against the wall.
/// Drawing the stage inside the room — which is what this used to do — put the
/// rectangle below the stage instead of beside it and did not match the console.
///
/// Two modes. With no `focus` the whole plan, stage included, is fitted into
/// the view. With a `focus` the view is a fixed-size window of `metresAcross`
/// centred on that point: the map scrolls under the operator instead of the
/// operator walking off the edge of it. That matters more than it sounds —
/// `room.json` is a nominal 20 × 15 m, and real rooms, seat-tap origins and
/// drift all put people outside it.
struct FloorPlanGeometry {
    let room: HubRoom
    let size: CGSize
    var focus: (x: Double, y: Double)?
    var metresAcross: Double = 12
    /// Breathing room around a fitted plan, in points. `makeView` in room.js
    /// uses 28 on the console's much larger canvas.
    var padding: CGFloat = 10

    /// `bounds()` in room.js: the stage hangs off the top of the room.
    private var stageDepth: Double { room.stage?.depth ?? 0 }
    private var spanX: Double { room.width }
    private var spanY: Double { room.depth + stageDepth }

    private var scale: CGFloat {
        guard focus == nil else { return size.width / metresAcross }
        return min(max(1, size.width - 2 * padding) / spanX, max(1, size.height - 2 * padding) / spanY)
    }

    /// View position of room (−width/2, 0): the stage-left corner of the stage wall.
    private var origin: CGPoint {
        if let focus {
            return CGPoint(x: size.width / 2 - (focus.x + room.width / 2) * scale,
                           y: size.height / 2 - focus.y * scale)
        }
        // Centre the whole plan (stage + floor), then step back down to y = 0.
        return CGPoint(x: (size.width - spanX * scale) / 2,
                       y: (size.height - spanY * scale) / 2 + stageDepth * scale)
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

    /// The stage block, above the room's top edge.
    var stageRect: CGRect? {
        guard let stage = room.stage else { return nil }
        let topLeft = point(x: -stage.width / 2, y: -stage.depth)
        return CGRect(x: topLeft.x, y: topLeft.y, width: length(stage.width), height: length(stage.depth))
    }
}

/// The shared picture: where I am, where everyone else is and which way they
/// are looking, what has been searched, where the pings are.
///
/// Everything here is redrawn from `world`, which the hub pushes at `WORLD_HZ`,
/// so both the mini-map and the full map are live without either of them asking
/// for anything. The mini-map is the same drawing with the detail turned down.
struct FloorPlanCanvas: View {
    let room: HubRoom
    let world: HubWorld?
    let me: RoomPose?
    let colorHex: String?
    let pings: [PingCue]
    /// Keep `me` in the middle and scroll the room underneath.
    var followsMe = false
    /// Off on the mini-map: numbers, the STAGE word and ping labels need room.
    var showsDetail = true
    /// Lets a caller pick the tap target's geometry back out of the view.
    var onGeometry: ((FloorPlanGeometry) -> Void)?

    var body: some View {
        Canvas { context, size in
            let plan = FloorPlanGeometry(room: room, size: size,
                                         focus: followsMe ? me.map { ($0.x, $0.y) } : nil,
                                         padding: showsDetail ? 10 : 4)
            onGeometry?(plan)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(MapInk.outside))
            context.fill(Path(roundedRect: plan.bounds, cornerRadius: 4), with: .color(MapInk.floor))

            drawCoverage(&context, plan: plan)

            if let stage = plan.stageRect {
                context.fill(Path(roundedRect: stage, cornerRadius: 3), with: .color(MapInk.stage))
                context.stroke(Path(roundedRect: stage, cornerRadius: 3), with: .color(MapInk.outline),
                               lineWidth: 1)
                if showsDetail, stage.height > 14 {
                    context.draw(Text("STAGE")
                        .font(.system(size: min(13, stage.height * 0.5), weight: .semibold))
                        .foregroundStyle(MapInk.labelSecondary), at: CGPoint(x: stage.midX, y: stage.midY))
                }
            }
            context.stroke(Path(roundedRect: plan.bounds, cornerRadius: 4), with: .color(MapInk.outline),
                           lineWidth: 1.25)

            // What everyone is looking at, under the markers — the console's
            // view cones, at the console's own fov and range.
            for peer in world?.phones ?? [] {
                guard let heading = peer.h else { continue }
                cone(&context, plan: plan, x: peer.x, y: peer.y, heading: heading,
                     opacity: peer.id == world?.me ? 0.2 : 0.11)
            }
            // Before the hub has listed this phone in `world.phones` — the first
            // second after joining, and any tick where the pose was too stale to
            // report — the operator is still on the map from the local pose, so
            // draw their cone from that instead of leaving a dot with no gaze.
            if let me, let heading = me.heading,
               !(world?.phones ?? []).contains(where: { $0.id == world?.me }) {
                cone(&context, plan: plan, x: me.x, y: me.y, heading: heading, opacity: 0.2)
            }

            for peer in world?.phones ?? [] where peer.id != world?.me {
                searcher(&context, at: plan.point(x: peer.x, y: peer.y), heading: peer.h,
                         number: showsDetail ? peer.i : nil, isMe: false)
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
                context.stroke(diamond, with: .color(MapInk.markerBorder), lineWidth: 1)
            }
            if let candidate = world?.candidate {
                let p = plan.point(x: candidate.x, y: candidate.y)
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32)),
                               with: .color(MapInk.candidateHalo), lineWidth: FloorPlanMarker.stroke)
                person(&context, at: p, color: MapInk.candidateRing)
            }
            if let me {
                let myIndex = world?.phones?.first(where: { $0.id == world?.me })?.i
                searcher(&context, at: plan.point(x: me.x, y: me.y), heading: me.heading,
                         number: showsDetail ? myIndex : nil, isMe: true)
            }
        }
    }

    /// `drawCoverage` in `web/console.js`, with the same ink, the same radius,
    /// the same blur and the same `.025 + .16·level²` ramp.
    ///
    /// The console has the hub's `heat` string — a per-cell probability. The
    /// phone's `world` message carries only `cells`, which is binary, so the
    /// gradient is recovered here by averaging each cell over its neighbours.
    /// That turns a checkerboard of hard dots into the soft field the console
    /// draws; the edges of a searched region fade instead of ending on a grid
    /// line, which is what made the two maps look like different products.
    private func drawCoverage(_ context: inout GraphicsContext, plan: FloorPlanGeometry) {
        guard let coverage = world?.coverage else { return }
        let cols = max(1, coverage.cols), rows = max(1, coverage.rows)
        let levels = Self.smoothed(coverage.cells, cols: cols, rows: rows)
        guard levels.count == cols * rows else { return }
        guard let low = levels.min(), let high = levels.max(), high - low > 0.04 else { return }

        let side = plan.length(coverage.cell)
        let radius = max(showsDetail ? 8 : 5, side * 1.8)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: max(showsDetail ? 4 : 2.5, radius * 0.45)))
            for row in 0..<rows {
                for col in 0..<cols {
                    let level = (levels[row * cols + col] - low) / (high - low)
                    guard level >= 0.16 else { continue }
                    let centre = plan.point(x: coverage.x0 + (Double(col) + 0.5) * coverage.cell,
                                            y: (Double(row) + 0.5) * coverage.cell)
                    layer.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                      width: radius * 2, height: radius * 2)),
                               with: .color(MapInk.heat.opacity(0.025 + 0.16 * level * level)))
                }
            }
        }
    }

    /// Each cell averaged with its eight neighbours, itself counting double.
    static func smoothed(_ cells: String, cols: Int, rows: Int) -> [Double] {
        let bytes = Array(cells.utf8)
        guard bytes.count >= cols * rows, cols > 0, rows > 0 else { return [] }
        var out = [Double](repeating: 0, count: cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                var sum = 0.0, weight = 0.0
                for dr in -1...1 {
                    for dc in -1...1 {
                        let r = row + dr, c = col + dc
                        guard r >= 0, r < rows, c >= 0, c < cols else { continue }
                        let w = (dr == 0 && dc == 0) ? 2.0 : 1.0
                        sum += bytes[r * cols + c] == UInt8(ascii: "1") ? w : 0
                        weight += w
                    }
                }
                out[row * cols + col] = weight > 0 ? sum / weight : 0
            }
        }
        return out
    }

    /// `drawCone` in `web/room.js`: a wedge that fades out along its length.
    private func cone(_ context: inout GraphicsContext, plan: FloorPlanGeometry,
                      x: Double, y: Double, heading: Double, opacity: Double) {
        let length = plan.length(FloorPlanCanvas.coneLength(room))
        guard length > 2 else { return }
        let p = plan.point(x: x, y: y)
        // Canvas angle 0 = +x; heading 0 = −y (toward the stage).
        let mid = Angle(degrees: heading - 90)
        let half = Angle(degrees: (room.cameraFovDeg ?? 55) / 2)
        var wedge = Path()
        wedge.move(to: p)
        wedge.addArc(center: p, radius: length, startAngle: mid - half, endAngle: mid + half, clockwise: false)
        wedge.closeSubpath()
        context.fill(wedge, with: .radialGradient(
            Gradient(colors: [MapInk.searcher.opacity(opacity), MapInk.searcher.opacity(0)]),
            center: p, startRadius: 0, endRadius: length))
    }

    /// The console draws the cone at the room's full camera range. On a phone
    /// that swamps the picture, so the mini-map keeps the angle and shortens
    /// the reach — the same call the console now makes.
    static func coneLength(_ room: HubRoom) -> Double { (room.coneLength ?? 5) * 0.6 }

    private func searcher(_ context: inout GraphicsContext, at point: CGPoint, heading: Double?,
                          number: Int?, isMe: Bool) {
        let radius = isMe ? FloorPlanMarker.radius : FloorPlanMarker.radius * 0.85
        if let heading {
            // Heading 0 faces the stage, which is up; clockwise from there.
            let angle = heading * .pi / 180
            let direction = CGVector(dx: sin(angle), dy: -cos(angle))
            let side = CGVector(dx: cos(angle), dy: sin(angle))
            let tip = CGPoint(x: point.x + direction.dx * (radius + 6), y: point.y + direction.dy * (radius + 6))
            let base = CGPoint(x: point.x + direction.dx * (radius - 2), y: point.y + direction.dy * (radius - 2))
            var pointer = Path()
            pointer.move(to: tip)
            pointer.addLine(to: CGPoint(x: base.x + side.dx * 5, y: base.y + side.dy * 5))
            pointer.addLine(to: CGPoint(x: base.x - side.dx * 5, y: base.y - side.dy * 5))
            pointer.closeSubpath()
            context.fill(pointer, with: .color(isMe ? MapInk.searcher : MapInk.peer))
        }
        let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                            width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(isMe ? MapInk.searcher : MapInk.peer))
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

/// The corner map. Live, and small enough that everything on it has to earn its
/// place: the room, the heat, everyone's cone and dot, and me in the middle.
///
/// The searched readout is a row *under* the plan, not a plate floating on top
/// of it. Overlaid, it covered the bottom third of a 132 × 150 map — including
/// the operator's own dot whenever they walked toward the back of the room.
struct MiniMapView: View {
    let room: HubRoom
    let world: HubWorld?
    let me: RoomPose?
    let colorHex: String?
    let pings: [PingCue]

    var body: some View {
        VStack(spacing: 0) {
            FloorPlanCanvas(room: room, world: world, me: me, colorHex: colorHex, pings: pings,
                            followsMe: true, showsDetail: false)
            if let searched = world?.searched {
                HStack(spacing: Space.xs) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(MapInk.labelSecondary)
                    Text("\(Int((searched * 100).rounded()))%")
                        .foregroundStyle(MapInk.label)
                    Spacer(minLength: 0)
                    if let searchers = world?.searchers, searchers > 0 {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(MapInk.labelSecondary)
                        Text("\(searchers)")
                            .foregroundStyle(MapInk.label)
                    }
                }
                .font(TypeScale.readout)
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity)
                .background(MapInk.legendBackground)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Area searched")
                .accessibilityValue("\(Int((searched * 100).rounded())) percent")
            }
        }
        .clipShape(Radius.rect(Radius.plate))
        .overlay(Radius.rect(Radius.plate).stroke(MapInk.plateBorder, lineWidth: 1))
        .cameraChrome()
    }
}

/// The map, full size. Opened by tapping the mini-map, and that is all it is:
/// the same live picture with the whole room in view. It carries no controls —
/// no "confirm you're on your spot", no "forget the marker lock". Those belong
/// them under the map meant every glance at where the team was came with a
/// prompt about a problem the operator had not asked about. There is now one
/// way to get located anyway, and it is to look at a printed marker.
struct RoomMapView: View {
    let room: HubRoom
    let world: HubWorld?
    let me: RoomPose?
    let pings: [PingCue]
    let onClose: () -> Void

    private var summary: String {
        var parts = ["\(Int((((world?.searched ?? 0)) * 100).rounded()))% searched"]
        if let searchers = world?.searchers, searchers > 0 {
            parts.append(searchers == 1 ? "1 searching" : "\(searchers) searching")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: Space.m) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Map").font(TypeScale.sheetTitle)
                    if let lookingFor = world?.lookingFor, !lookingFor.isEmpty {
                        Text(lookingFor)
                            .font(TypeScale.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
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

            FloorPlanCanvas(room: room, world: world, me: me, colorHex: nil, pings: pings)
                .aspectRatio(room.width / max(1, room.depth + (room.stage?.depth ?? 0)), contentMode: .fit)
                // The plan is the same drawn artefact as the mini-map — dark
                // strokes on a light floor — so it keeps its own ink whichever
                // way the card around it resolves.
                .clipShape(Radius.rect(Radius.plate))
                .overlay(Radius.rect(Radius.plate).stroke(MapInk.plateBorder, lineWidth: 1))
                .accessibilityLabel("Room plan. You, your team, and what has been searched.")

            // One quiet line, not a row of scoreboard tiles. Rank is gone
            // outright: an operator sweeping a room does not need to be told
            // they are third, and turning a search into a leaderboard is the
            // wrong thing to put under a map of where everyone is.
            Text(summary)
                .font(TypeScale.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Space.xl)
        // Not a presented sheet, on purpose: this card sits over a live camera
        // the operator is still aiming, and a sheet would cover the preview.
        .background(Surface.card, in: Radius.rect(Radius.sheet))
        .padding(Space.l)
    }
}
