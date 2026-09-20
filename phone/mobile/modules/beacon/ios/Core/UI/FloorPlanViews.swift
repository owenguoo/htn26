import CoreGraphics
import Foundation
import SwiftUI
import SwarmCore

/// The console's marker system: 20 points outside-to-outside with a 2-point
/// white border, and four points of air before any attached label.
/// `MAP_MARKER_*` / `MAP_LABEL_*` in `web/console.js`.
private enum MapMarker {
    static let radius: CGFloat = 10
    static let stroke: CGFloat = 2
    static let labelHeight: CGFloat = 18
    static let labelGap: CGFloat = 4
}

/// `drawPersonGlyph()`: a head and shoulders in a white disc, ringed in the
/// colour that says which kind of person this is. One function rather than one
/// per caller, because the map and the legend have to show the same glyph or
/// the legend is not a legend.
private enum PersonGlyph {
    /// Outside-to-outside size of the glyph in its own units. The disc is
    /// `radius * 2` across, and a centred stroke puts half its width outside
    /// that — so a box of `radius * 2` clips the ring at the four corners,
    /// which is exactly what it looked like.
    static let outerUnits = MapMarker.radius * 2 + MapMarker.stroke

    static func draw(_ context: inout GraphicsContext, at point: CGPoint, color: Color,
                     scale: CGFloat = 1) {
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: point.x + x * scale, y: point.y + y * scale)
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(origin: at(x, y), size: CGSize(width: width * scale, height: height * scale))
        }
        let radius = MapMarker.radius
        let circle = Path(ellipseIn: box(-radius, -radius, radius * 2, radius * 2))
        context.fill(circle, with: .color(MapInk.markerBorder))
        context.stroke(circle, with: .color(color), lineWidth: MapMarker.stroke * scale)
        // arc(0, -3.5, 2.7) and roundRect(-4.5, .5, 9, 5.5, 3).
        context.fill(Path(ellipseIn: box(-2.7, -6.2, 5.4, 5.4)), with: .color(color))
        context.fill(Path(roundedRect: box(-4.5, 0.5, 9, 5.5), cornerRadius: 3 * scale),
                     with: .color(color))
    }
}

/// `drawHazards()`'s sign, which is also the `.hazard-key` in the console's
/// legend: a 22-unit warning triangle with a bang in it, in amber on amber.
private enum HazardSign {
    /// Outside-to-outside, in the sign's own units: 22 across for the triangle
    /// itself, a centred 2-unit stroke either side of that, and another couple
    /// for the mitred corners, which reach past their vertices.
    static let outerUnits: CGFloat = 27

    /// The console's own geometry, in its own units, scaled about `point`.
    /// The triangle runs from −11 to +9 in y, so its visual centre is a unit
    /// above the point it is drawn at — `centred` puts that right for a legend
    /// swatch, where the box is what has to look centred.
    static func draw(_ context: inout GraphicsContext, at point: CGPoint,
                     scale: CGFloat = 1, centred: Bool = false) {
        let origin = centred ? CGPoint(x: point.x, y: point.y + scale) : point
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var triangle = Path()
        triangle.move(to: at(0, -11))
        triangle.addLine(to: at(11, 9))
        triangle.addLine(to: at(-11, 9))
        triangle.closeSubpath()
        context.fill(triangle, with: .color(MapInk.hazardFill))
        context.stroke(triangle, with: .color(MapInk.hazardStroke), lineWidth: MapMarker.stroke * scale)
        var bang = Path()
        bang.addRect(CGRect(origin: at(-1, -3), size: CGSize(width: 2 * scale, height: 6 * scale)))
        bang.addRect(CGRect(origin: at(-1, 5), size: CGSize(width: 2 * scale, height: 2 * scale)))
        context.fill(bang, with: .color(MapInk.hazardBang))
    }
}

/// Room metres ↔ view points. x is 0 on the stage centre line; y is 0 at the
/// stage wall, which is drawn at the top — the same way up as the console.
///
/// **The stage lives at negative y, outside the room rectangle.** That is
/// `web/room.js` `bounds()`: `y0 = -stage.depth`, `y1 = room.depth`. The room
/// outline starts at y = 0 and the stage block sits above it, against the wall.
///
/// Two modes. With no `focus` the whole plan is fitted into the view with the
/// console's own 28 points of padding — `makeView(room, w, h, 28)`. With a
/// `focus` the view is a fixed-size window of `metresAcross` centred on that
/// point: the map scrolls under the operator instead of the operator walking
/// off the edge of it. That matters more than it sounds — `room.json` is a
/// nominal 20 × 15 m, and real rooms, seat origins and drift all put people
/// outside it. The console never needs it because nobody is standing in it.
struct FloorPlanGeometry {
    let room: HubRoom
    let size: CGSize
    var focus: (x: Double, y: Double)?
    var metresAcross: Double = 12
    var padding: CGFloat = 28

    private var stageDepth: Double { room.stage?.depth ?? 0 }
    private var spanX: Double { room.width }
    private var spanY: Double { room.depth + stageDepth }

    var scale: CGFloat {
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

    func length(_ metres: Double) -> CGFloat { metres * scale }

    /// The room's outline, wherever that falls — partly or wholly off-view when following.
    var bounds: CGRect {
        CGRect(origin: origin, size: CGSize(width: room.width * scale, height: room.depth * scale))
    }

    /// `STAGE_GAP_PX` in `web/room.js`. Keep the two in step.
    static let stageGap: CGFloat = 3

    /// The stage block, above the room's top edge and lifted clear of it by
    /// `stageGap` so that both rectangles are closed and neither borrows the
    /// other's edge. Presentation only: the room's coordinates are unchanged,
    /// and everything placed in the room is still placed against the real
    /// stage line at y = 0.
    var stageRect: CGRect? {
        guard let stage = room.stage else { return nil }
        let topLeft = point(x: -stage.width / 2, y: -stage.depth)
        return CGRect(x: topLeft.x, y: topLeft.y - Self.stageGap,
                      width: length(stage.width), height: length(stage.depth))
    }
}

/// The search map, drawn the way the operator console draws it.
///
/// This is `draw()` in `web/console.js`, in the same order with the same
/// numbers: the backdrop gradient, the floor, the coverage field, the walls,
/// the stage, everyone's view cone, pings, the found person, then the phone
/// markers on top. The operator and the console are looking at one picture of
/// one room, and the fastest way for them to stop agreeing is for the two
/// renderers to drift apart — so where a literal appears here, the `console.js`
/// line it came from is named beside it.
///
/// What the phone adds is `focus`: the mini-map follows the operator. What it
/// leaves out is what the console alone can do — planner sector overlays, the
/// draggable rehearsal target, the marker pin, the explain overlay — because
/// the phone's `world` message does not carry any of it.
struct FloorPlanCanvas: View {
    let room: HubRoom
    let world: HubWorld?
    let me: RoomPose?
    let pings: [PingCue]
    /// Keep `me` in the middle and scroll the room underneath.
    var followsMe = false
    /// Off on the mini-map, where there is no room for the STAGE word, the
    /// labels over the pins or the scale bar.
    var showsDetail = true
    /// Seconds on a monotonic clock. The expanding rings derive their phase
    /// from it the way the console does, each with its own divisor:
    /// `(performance.now() / 1000) % 1` for a ping, `/ 1100` for a find.
    var time: Double = 0

    var body: some View {
        Canvas { context, size in
            let plan = FloorPlanGeometry(room: room, size: size,
                                         focus: followsMe ? me.map { ($0.x, $0.y) } : nil,
                                         padding: showsDetail ? 28 : 6)
            backdrop(&context, size: size)

            // drawRoom(): floor, then walls, with the stage hanging off the top.
            // Square corners and a 2-point wall, exactly as `fillRect`/`strokeRect`.
            context.fill(Path(plan.bounds), with: .color(MapInk.floor))
            coverage(&context, plan: plan)
            context.stroke(Path(plan.bounds), with: .color(MapInk.wall), lineWidth: 2)
            if let stage = plan.stageRect {
                context.fill(Path(stage), with: .color(MapInk.stage))
                // The stage carries the same 2-point wall the room does, all
                // the way around — see `drawRoom()` in `web/room.js`.
                context.stroke(Path(stage), with: .color(MapInk.wall), lineWidth: 2)
                if showsDetail {
                    // `600 ${Math.max(10, view.scale * 0.6)}px` — the STAGE word
                    // grows with the room, not with the operator's text size.
                    let fontSize = max(10, plan.scale * 0.6)
                    context.draw(Text("STAGE").font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(MapInk.stageLabel), at: CGPoint(x: stage.midX, y: stage.midY))
                }
            }

            let people = searchers
            for who in people {
                guard let heading = who.heading else { continue }
                cone(&context, plan: plan, x: who.x, y: who.y, heading: heading)
            }

            // `draw()`: marker, then pings, then the found person, then the
            // phone pins over all of it.
            var labels: [CGRect] = []
            drawMarker(&context, plan: plan)
            drawPings(&context, plan: plan)
            drawHazards(&context, plan: plan)
            drawCandidate(&context, plan: plan, labels: &labels, size: size)
            for who in people {
                phone(&context, at: plan.point(x: who.x, y: who.y), heading: who.heading,
                      number: who.index)
            }
            if showsDetail { scaleBar(&context, plan: plan, size: size) }
        }
    }

    private struct Searcher {
        var x: Double
        var y: Double
        var heading: Double?
        var index: Int?
    }

    /// Everyone on the map, the operator included. The hub lists this phone in
    /// `world.phones` like any other; before it has (the first second after
    /// joining, or a tick where the pose was too stale to report) the local
    /// pose stands in, so the operator's own dot never blinks out.
    private var searchers: [Searcher] {
        let phones = world?.phones ?? []
        var out = phones.map {
            Searcher(x: $0.x, y: $0.y, heading: $0.h, index: $0.i)
        }
        if let me, !phones.contains(where: { $0.id == world?.me }) {
            out.append(Searcher(x: me.x, y: me.y, heading: me.heading, index: nil))
        }
        return out
    }

    /// `#mapWrap`'s CSS background, which the half-transparent floor sits on.
    private func backdrop(_ context: inout GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width * 0.5, y: size.height * 0.45)
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
            Gradient(stops: [.init(color: MapInk.backdropCentre, location: 0),
                             .init(color: MapInk.backdropMid, location: 0.72),
                             .init(color: MapInk.backdropEdge, location: 1)]),
            center: centre, startRadius: 0, endRadius: max(size.width, size.height) * 0.75))
    }

    /// `drawCoverage()` in `web/console.js`, sharing its `heatLevels` /
    /// `heatAlpha` from `web/room.js`: the field is equalised, then painted
    /// once at cell resolution and scaled up, rather than stamped as one
    /// blurred disc per cell.
    ///
    /// **The field is probability, not coverage.** The console draws the hub's
    /// `heat`, which is high where the candidate probably *is* — and that is
    /// mostly where nobody has looked yet, because every camera look
    /// multiplies the cells it swept downwards (`swarm/coverage.py`). Drawing
    /// "where we have looked" instead, which is what this used to do, lit up
    /// the floor the swarm had already cleared and left the unsearched floor
    /// blank: the exact inverse of the console's picture of the same room.
    private func coverage(_ context: inout GraphicsContext, plan: FloorPlanGeometry) {
        guard let coverage = world?.coverage else { return }
        let cols = max(1, coverage.cols), rows = max(1, coverage.rows)
        guard let levels = Self.heatLevels(heat: coverage.heat, cells: coverage.cells,
                                           cols: cols, rows: rows),
              let field = Self.heatImage(levels, cols: cols, rows: rows) else { return }

        let topLeft = plan.point(x: coverage.x0, y: 0)
        let bottomRight = plan.point(x: coverage.x0 + Double(cols) * coverage.cell,
                                     y: Double(rows) * coverage.cell)
        let rect = CGRect(x: topLeft.x, y: topLeft.y,
                          width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
        guard rect.width > 1, rect.height > 1 else { return }
        // Half a cell of blur on top of the scaler's own interpolation: enough
        // to lose the grid, not enough to smear a hotspot off where it is.
        let blur: CGFloat = max(showsDetail ? 3 : 1.5, plan.length(coverage.cell) * 0.5)
        context.drawLayer { layer in
            layer.clip(to: Path(rect))  // heat stops at the walls
            layer.addFilter(.blur(radius: blur))
            // Interpolation is a property of the image, not of the context:
            // `GraphicsContext` has no `interpolation`. Without `.high` the
            // 40 x 30 field would nearest-neighbour up into visible cells.
            layer.draw(Image(decorative: field, scale: 1, orientation: .up).interpolation(.high),
                       in: rect)
        }
    }

    /// `heatLevels()` in `web/room.js`, over whichever field the hub sent.
    ///
    /// With `heat` this is the console's own probability field, character for
    /// character. Without it — `hub.py`'s `world_loop` does not forward `heat`
    /// to phones today — the binary `cells` mask is inverted into "nobody has
    /// looked here, so they may still be here" and quantised into the same 36
    /// steps, so the rest of the pipeline is identical either way. That
    /// fallback is only an approximation, and a short-lived one: `cells` is a
    /// one-way latch that a four-phone sweep drives past 90% in seconds, and
    /// once every cell is set the field is flat and nothing is drawn.
    ///
    /// Nil when the field is too flat to say anything.
    static func heatLevels(heat: String?, cells: String, cols: Int, rows: Int) -> [Double]? {
        let n = cols * rows
        guard n > 0 else { return nil }
        let top = heatSteps - 1
        let bins: [Int]
        if let heat, heat.utf8.count >= n {
            bins = Array(heat.utf8.prefix(n)).map { min(top, max(0, base36($0))) }
        } else {
            let looked = smoothed(cells, cols: cols, rows: rows)
            guard looked.count == n else { return nil }
            bins = looked.map { min(top, max(0, Int((min(1, max(0, 1 - $0)) * Double(top)).rounded()))) }
        }
        guard let low = bins.min(), let high = bins.max(),
              Double(high - low) / Double(top) > heatMinSpread else { return nil }
        var levels = heatEqualise(bins)
        // Normalise to the hottest cell. Ranking alone leaves the plateau of
        // never-looked-at cells at its *midpoint* rank, which early in a search
        // is about 0.5 for the whole map — a flat, near-invisible tint. See
        // `heatLevels()` in `web/room.js`.
        if let peak = levels.max(), peak > 0 {
            for i in levels.indices { levels[i] /= peak }
        }
        return levels
    }

    /// One base-36 digit, the way `parseInt(c, 36)` reads it. Anything else is 0.
    @inline(__always)
    static func base36(_ byte: UInt8) -> Int {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return Int(byte - UInt8(ascii: "A")) + 10
        default: return 0
        }
    }

    /// Rank of each bin among all cells, 0…1, ties sharing the midpoint of the
    /// span they occupy. A plain min/max stretch cannot draw this field: most
    /// of it is one plateau of cells nobody has looked at, which a linear ramp
    /// paints as a solid sheet, and that plateau collapses into a step or two
    /// the moment one detection lifts a single cell far above it — at which
    /// point the same linear ramp paints the whole room as empty. Ranking
    /// survives both.
    static func heatEqualise(_ bins: [Int]) -> [Double] {
        let n = bins.count
        var counts = [Int](repeating: 0, count: heatSteps)
        for b in bins where b >= 0 && b < heatSteps { counts[b] += 1 }
        var level = [Double](repeating: 0, count: heatSteps)
        var seen = 0
        for v in 0..<heatSteps where counts[v] > 0 {
            level[v] = n > 1 ? (Double(seen) + Double(counts[v] - 1) / 2) / Double(n - 1) : 1
            seen += counts[v]
        }
        return bins.map { $0 >= 0 && $0 < heatSteps ? level[$0] : 0 }
    }

    /// `HEAT_MAX_ALPHA` / `HEAT_GAMMA` / `HEAT_STEPS` / `HEAT_MIN_SPREAD` in
    /// `web/room.js`. Keep the four in step with it. `heatMinSpread` is over
    /// the *full* range, coldest to hottest: a percentile cut meant nothing was
    /// drawn until a good fraction of the floor had been swept, which is
    /// exactly the stretch of a search the operator is watching the map for.
    static let heatMaxAlpha: Double = 0.38
    static let heatGamma: Double = 1.8
    static let heatSteps = 36
    static let heatMinSpread: Double = 0.04

    static func heatAlpha(_ level: Double) -> Double {
        heatMaxAlpha * pow(min(1, max(0, level)), heatGamma)
    }

    /// `heatGradientCSS()` in `web/room.js`: the ramp as gradient stops for the
    /// legend key, off the same numbers the field is painted with, so the
    /// swatch cannot drift away from the thing it explains.
    static var heatStops: [Gradient.Stop] {
        (0..<6).map { step in
            let level = Double(step) / 5
            return Gradient.Stop(color: MapInk.heatField.opacity(heatAlpha(level)), location: level)
        }
    }

    /// The field as a cols×rows bitmap in `MapInk.heatField`, one pixel per cell,
    /// drawn scaled up with interpolation. `heatCanvas()` in `web/room.js`.
    static func heatImage(_ levels: [Double], cols: Int, rows: Int) -> CGImage? {
        guard cols > 0, rows > 0, levels.count >= cols * rows else { return nil }
        // `MapInk.heatField` = rgb(37, 99, 235), premultiplied by the cell's alpha.
        let ink = (r: 37.0, g: 99.0, b: 235.0)
        var bytes = [UInt8](repeating: 0, count: cols * rows * 4)
        for i in 0..<(cols * rows) {
            let a = heatAlpha(levels[i])
            bytes[i * 4] = UInt8((ink.r * a).rounded())
            bytes[i * 4 + 1] = UInt8((ink.g * a).rounded())
            bytes[i * 4 + 2] = UInt8((ink.b * a).rounded())
            bytes[i * 4 + 3] = UInt8((255 * a).rounded())
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: cols * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// Each cell averaged with its eight neighbours, itself counting double.
    /// Without it the binary mask upscales into hard-edged blocks where the
    /// console has a soft field, which is what made the two look unrelated.
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

    /// `drawCone()` in `web/room.js` at `console.js`'s connected alpha, over
    /// `CONE_DRAW_SCALE` of the camera's real range — the same shortening the
    /// console applies, so both maps claim the same amount of floor is seen.
    private func cone(_ context: inout GraphicsContext, plan: FloorPlanGeometry,
                      x: Double, y: Double, heading: Double) {
        let length = plan.length((room.coneLength ?? 5) * Self.coneDrawScale)
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
            Gradient(colors: [MapInk.searcher.opacity(0.12), MapInk.searcher.opacity(0)]),
            center: p, startRadius: 0, endRadius: length))
    }

    /// `CONE_DRAW_SCALE` in `web/console.js`. Keep the two in step.
    static let coneDrawScale: Double = 0.6

    /// `drawPhone()`: a dot with a heading triangle, the phone's index in it.
    private func phone(_ context: inout GraphicsContext, at point: CGPoint,
                       heading: Double?, number: Int?) {
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: MapInk.markerShadow, radius: 7, x: 0, y: 2))
            if let heading {
                let angle = CGFloat(heading * .pi / 180)
                // ctx.rotate(heading), then moveTo(0,-16) lineTo(5,-8) lineTo(-5,-8).
                let rotate = { (x: CGFloat, y: CGFloat) -> CGPoint in
                    CGPoint(x: point.x + x * cos(angle) - y * sin(angle),
                            y: point.y + x * sin(angle) + y * cos(angle))
                }
                var pointer = Path()
                pointer.move(to: rotate(0, -16))
                pointer.addLine(to: rotate(5, -8))
                pointer.addLine(to: rotate(-5, -8))
                pointer.closeSubpath()
                layer.fill(pointer, with: .color(MapInk.searcher))
            }
            let circle = Path(ellipseIn: CGRect(x: point.x - MapMarker.radius, y: point.y - MapMarker.radius,
                                                width: MapMarker.radius * 2, height: MapMarker.radius * 2))
            layer.fill(circle, with: .color(MapInk.searcher))
            layer.stroke(circle, with: .color(MapInk.markerBorder), lineWidth: MapMarker.stroke)
        }
        if let number {
            context.draw(Text(String(number)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(MapInk.markerBorder), at: CGPoint(x: point.x, y: point.y + 0.5))
        }
    }

    private func person(_ context: inout GraphicsContext, at point: CGPoint, color: Color) {
        PersonGlyph.draw(&context, at: point, color: color)
    }

    /// `drawMarker()`: the printed alignment marker, wherever the operator put
    /// it on the console.
    ///
    /// The console draws it as a tag rather than a dot, "so it reads as a thing
    /// on a wall, not another searcher" — 16 points square with a 4-point
    /// radius, filled in `MARKER_COLOR`, a 2-point white border and the same
    /// drop shadow the phone pins carry — and, like the console, no text label:
    /// the legend strip under the map already names the purple tag.
    /// The phone used to show it as an ordinary ping instead: a dark diamond
    /// with an expanding ring, which is the shape the map uses for "go here
    /// now" and reads as a completely different thing.
    private func drawMarker(_ context: inout GraphicsContext, plan: FloorPlanGeometry) {
        guard let marker = world?.marker else { return }
        let p = plan.point(x: marker.x, y: marker.y)
        let tag = Path(roundedRect: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16),
                       cornerRadius: 4)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: MapInk.markerShadow, radius: 7, x: 0, y: 2))
            layer.fill(tag, with: .color(MapInk.marker))
            layer.stroke(tag, with: .color(MapInk.markerBorder), lineWidth: MapMarker.stroke)
        }
    }

    /// Before the search starts the hub also pushes the marker down the ping
    /// channel (`hub.py` `marker_cue`), because the compass and the camera view
    /// have no other way to hear about it. The map does, so it drops that cue
    /// rather than drawing a ping diamond underneath the marker tag.
    ///
    /// Static: the views that host the map gate their animation clock on the
    /// same list. A marker cue that is no longer drawn must not keep a map with
    /// nothing moving on it repainting at 30 Hz.
    static func drawablePings(_ pings: [PingCue], world: HubWorld?) -> [PingCue] {
        world?.marker == nil ? pings : pings.filter { $0.label != "MARKER" }
    }

    /// `drawDetectedPeople()` and `drawHazards()`. Both used to be invented
    /// here — a plain blue dot for a person and an orange outline triangle with
    /// a text "!" for a hazard — so the same two things wore different shapes
    /// and different ambers on the console and on the phone. These are the
    /// console's own glyphs.
    private func drawHazards(_ context: inout GraphicsContext, plan: FloorPlanGeometry) {
        for detected in world?.detectedPeople ?? [] {
            guard detected.x.isFinite, detected.y.isFinite else { continue }
            person(&context, at: plan.point(x: detected.x, y: detected.y),
                   color: detected.stale ? MapInk.staleInk : MapInk.detectedPerson)
        }
        for hazard in world?.hazards ?? [] {
            guard hazard.x.isFinite, hazard.y.isFinite else { continue }
            let p = plan.point(x: hazard.x, y: hazard.y)
            var layer = context
            // `ctx.globalAlpha = stale ? .5 : 1`.
            layer.opacity = hazard.stale ? 0.5 : 1
            HazardSign.draw(&layer, at: p, scale: showsDetail ? 1 : 0.7)
        }
    }

    private var mapPings: [PingCue] { Self.drawablePings(pings, world: world) }

    /// `drawPings()`: an expanding ring, a dark diamond, and the label above it.
    private func drawPings(_ context: inout GraphicsContext, plan: FloorPlanGeometry) {
        for ping in mapPings {
            let p = plan.point(x: ping.x, y: ping.y)
            let k = time.truncatingRemainder(dividingBy: 1)
            let radius = CGFloat(6 + k * 18)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(MapInk.searcher.opacity(0.8 * (1 - k) * ping.fade)),
                           lineWidth: 1)
            var diamond = Path()
            diamond.move(to: CGPoint(x: p.x, y: p.y - 7))
            diamond.addLine(to: CGPoint(x: p.x + 7, y: p.y))
            diamond.addLine(to: CGPoint(x: p.x, y: p.y + 7))
            diamond.addLine(to: CGPoint(x: p.x - 7, y: p.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(MapInk.ping.opacity(ping.fade)))
            guard showsDetail else { continue }
            context.draw(Text(ping.label).font(.system(size: 11, weight: .medium))
                .foregroundStyle(MapInk.ping.opacity(ping.fade)), at: CGPoint(x: p.x, y: p.y - 14))
        }
    }

    /// The found-person half of `drawCandidate()`. The rehearsal target, the
    /// responder lines and the marker pin are console-only: nothing in the
    /// phone's `world` message describes them.
    private func drawCandidate(_ context: inout GraphicsContext, plan: FloorPlanGeometry,
                               labels: inout [CGRect], size: CGSize) {
        guard let candidate = world?.candidate else { return }
        let p = plan.point(x: candidate.x, y: candidate.y)
        let color: Color = candidate.possible == true ? .orange : MapInk.found
        // `(performance.now() / 1100) % 1` — a little slower than the pings.
        let k = (time * 1000 / 1100).truncatingRemainder(dividingBy: 1)
        let radius = MapMarker.radius + MapMarker.stroke + 1 + CGFloat(k * 24)
        context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                              width: radius * 2, height: radius * 2)),
                       with: .color(color.opacity(0.7 * (1 - k))), lineWidth: 2)
        person(&context, at: p, color: color)
        guard showsDetail else { return }
        let y = p.y - MapMarker.radius - MapMarker.stroke / 2 - MapMarker.labelGap - MapMarker.labelHeight / 2
        mapLabel(&context, candidate.possible == true ? "POSSIBLE MATCH" : "FOUND PERSON", at: CGPoint(x: p.x, y: y), background: color,
                 labels: &labels, size: size)
    }

    /// `drawMapLabel()` plus `reserveMapLabel()`: a pill in the marker's colour,
    /// nudged vertically until it is not sitting on another one.
    private func mapLabel(_ context: inout GraphicsContext, _ text: String, at point: CGPoint,
                          background: Color, labels: inout [CGRect], size: CGSize) {
        let resolved = context.resolve(Text(text).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MapInk.markerBorder))
        let width = resolved.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width + 12
        let half = width / 2
        let x = max(half + 4, min(size.width - half - 4, point.x))
        var rect = CGRect(x: x - half, y: point.y - 9, width: width, height: MapMarker.labelHeight)
        for offset in [0, -22, -44, 22, 44, -66, 66] as [CGFloat] {
            let y = max(MapMarker.labelHeight / 2 + 4,
                        min(size.height - MapMarker.labelHeight / 2 - 4, point.y + offset))
            rect = CGRect(x: x - half, y: y - 9, width: width, height: MapMarker.labelHeight)
            if !labels.contains(where: { $0.insetBy(dx: -3, dy: -3).intersects(rect) }) { break }
        }
        labels.append(rect)
        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(background))
        context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY + 0.5))
    }

    /// `.map-scale`: a 5 m rule in the bottom-right corner.
    private func scaleBar(_ context: inout GraphicsContext, plan: FloorPlanGeometry, size: CGSize) {
        let width = plan.length(5)
        guard width > 16, width < size.width - 60 else { return }
        let right = size.width - 14, bottom = size.height - 14
        var rule = Path()
        rule.move(to: CGPoint(x: right - width, y: bottom - 6))
        rule.addLine(to: CGPoint(x: right - width, y: bottom))
        rule.addLine(to: CGPoint(x: right, y: bottom))
        rule.addLine(to: CGPoint(x: right, y: bottom - 6))
        context.stroke(rule, with: .color(MapInk.labelTertiary), lineWidth: 1)
        context.draw(Text("5 m").font(.system(size: 10, design: .monospaced))
            .foregroundStyle(MapInk.labelTertiary),
                     at: CGPoint(x: right - width - 14, y: bottom - 4))
    }
}

/// Eases the plan between pose updates, so walking scrolls the map instead of
/// stepping it.
///
/// **The choppiness is the pose rate, not the frame rate.** Poses reach the
/// overlay at about 10 Hz (`CLAUDE.md`: "pose at ~10 Hz"), and the mini-map
/// keeps the operator centred — so the room moved in ten visible jumps a
/// second while they walked. Nothing here redraws faster than before on its
/// own: `Animatable` asks SwiftUI to hand back the interpolated value on each
/// display frame *for the length of one tween*, so the plan is drawn at the
/// screen's rate between two poses and then stops. A phone standing still
/// redraws as rarely as it did.
///
/// The heading is unwrapped before it gets here, because interpolating 359 → 1
/// the arithmetic way spins the cone 358° the wrong way.
private struct SmoothedPose<Content: View>: View, Animatable {
    var x: Double
    var y: Double
    var heading: Double
    var hasHeading: Bool
    var pitch: Double
    @ViewBuilder var content: (RoomPose) -> Content

    /// **`nonisolated`, and it has to be.** `View` is `@MainActor`, so a type
    /// conforming to it is too — but `Animatable` is not, and SwiftUI drives
    /// this property from its own animation machinery. Without the keyword the
    /// conformance "crosses into main actor-isolated code" and Swift 6 rejects
    /// it. Safe because the three values it touches are `Double`s in a value
    /// type, which SE-0434 makes implicitly nonisolated; `content`, which is
    /// not `Sendable`, is never read here.
    nonisolated var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(x, AnimatablePair(y, heading)) }
        set {
            x = newValue.first
            y = newValue.second.first
            heading = newValue.second.second
        }
    }

    var body: some View {
        content(RoomPose(x: x, y: y, heading: hasHeading ? heading : nil, pitch: pitch))
    }
}

/// Hands the plan a pose that moves continuously. Both maps draw through it.
struct MovingPlan<Content: View>: View {
    let me: RoomPose?
    @ViewBuilder var content: (RoomPose?) -> Content

    /// The heading with the wrap taken out: it keeps accumulating past 360 so
    /// every turn is interpolated the short way round.
    @State private var heading: Double = 0

    /// Just over the pose interval. Long enough that one tween runs into the
    /// next — which is what makes a walk continuous rather than ten little
    /// slides — and short enough that the dot is not visibly behind the
    /// operator. Linear, because a walk at constant speed should not ease in
    /// and out ten times a second.
    private static var step: Animation { .linear(duration: 0.12) }

    private struct Target: Equatable {
        var x: Double
        var y: Double
        var heading: Double
    }

    var body: some View {
        Group {
            if let me {
                // `content` takes an optional — the no-pose case below hands
                // it nil — so it is adapted rather than passed straight on.
                SmoothedPose(x: me.x, y: me.y, heading: heading,
                             hasHeading: me.heading != nil, pitch: me.pitch) { content($0) }
                    .animation(Self.step, value: Target(x: me.x, y: me.y, heading: heading))
            } else {
                content(nil)
            }
        }
        .onChange(of: me?.heading) { _, next in
            guard let next else { return }
            heading += RoomMath.signedDiff(next, RoomMath.wrap360(heading))
        }
        .onAppear { heading = me?.heading ?? 0 }
    }
}

/// Wraps the map in a clock only when something on it is actually animating.
/// The console repaints on every animation frame regardless; a phone running
/// ARKit, an encoder and a socket does not get to be that relaxed, so a map
/// with no pings and nobody found is drawn once and left alone.
private struct PulsingFloorPlan<Content: View>: View {
    let isAnimating: Bool
    @ViewBuilder var content: (Double) -> Content

    var body: some View {
        if isAnimating {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                content(timeline.date.timeIntervalSinceReferenceDate)
            }
        } else {
            content(0)
        }
    }
}

/// The corner map: the console's map, scrolled to keep the operator centred,
/// with the labels and the scale bar dropped because there is no room for them.
/// The strip underneath is the console's legend strip — same background, same
/// ink, cut down to the two numbers that mean anything to a person in the room.
struct MiniMapView: View {
    let room: HubRoom
    let world: HubWorld?
    let me: RoomPose?
    let pings: [PingCue]

    var body: some View {
        VStack(spacing: 0) {
            MovingPlan(me: me) { eased in
                PulsingFloorPlan(isAnimating: !FloorPlanCanvas.drawablePings(pings, world: world).isEmpty
                                     || world?.candidate != nil) { time in
                    FloorPlanCanvas(room: room, world: world, me: eased, pings: pings,
                                    followsMe: true, showsDetail: false, time: time)
                }
            }
            if let searched = world?.searched {
                HStack(spacing: Space.xs) {
                    Text("\(Int((searched * 100).rounded()))% searched")
                    Spacer(minLength: Space.xs)
                    if let searchers = world?.searchers, searchers > 0 {
                        Text("\(searchers)")
                        Image(systemName: "person.2.fill").font(.system(size: 8, weight: .bold))
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MapInk.labelSecondary)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(MapInk.legendBackground)
                .overlay(alignment: .top) { MapInk.line.frame(height: 1) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Area searched")
                .accessibilityValue("\(Int((searched * 100).rounded())) percent")
            }
        }
        .clipShape(Radius.rect(Radius.plate))
        .overlay(Radius.rect(Radius.plate).stroke(MapInk.line, lineWidth: 1))
        .cameraChrome()
    }
}

/// The map, full size. Opened by tapping the mini-map, and that is all it is:
/// the console's search map with the whole room in view, live, with the
/// console's own legend under it.
///
/// It carries no controls. Looking at where the team is should not come with a
/// prompt about a problem the operator did not ask about — and getting located
/// has one answer anyway, which is to look at a printed marker.
struct RoomMapView: View {
    let room: HubRoom
    let world: HubWorld?
    let me: RoomPose?
    let pings: [PingCue]
    let onClose: () -> Void

    private var summary: String {
        var parts = ["\(Int(((world?.searched ?? 0) * 100).rounded()))% searched"]
        if let searchers = world?.searchers, searchers > 0 {
            parts.append(searchers == 1 ? "1 searching" : "\(searchers) searching")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: Space.m) {
            HStack(spacing: Space.s) {
                Text("Search map").font(TypeScale.sheetTitle)
                Spacer(minLength: 0)
                // A real close control, not a hand-built glyph with a tap
                // gesture: the system draws the circle, the glass and the
                // pressed state, and it comes with a 44-point target.
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    .buttonStyle(.glass)
                    .tint(.secondary)
                    .accessibilityLabel("Close map")
            }

            VStack(spacing: 0) {
                // How the search is going, in a strip of its own above the
                // plan. Floated over the plan it sat on the stage block and the
                // MARKER label; as a subtitle under the title it was a grey
                // line nobody read. A strip matching the legend below it reads
                // as part of the plate and takes nothing off the room.
                HStack(spacing: Space.xs) {
                    Text(summary)
                    Spacer(minLength: 0)
                }
                .font(TypeScale.readout)
                .foregroundStyle(MapInk.labelSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, Space.m)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(MapInk.legendBackground)
                .overlay(alignment: .bottom) { MapInk.line.frame(height: 1) }
                .accessibilityLabel("Area searched")

                MovingPlan(me: me) { eased in
                    PulsingFloorPlan(isAnimating: !FloorPlanCanvas.drawablePings(pings, world: world).isEmpty
                                         || world?.candidate != nil) { time in
                        FloorPlanCanvas(room: room, world: world, me: eased, pings: pings, time: time)
                    }
                }
                .aspectRatio(room.width / max(1, room.depth + (room.stage?.depth ?? 0)), contentMode: .fit)
                .accessibilityLabel("Room plan. You, your team, and what has been searched.")

                // `.map-legend`: a full-width strip under the map, not a card
                // floating over the floor.
                // Five keys and the ramp, the same six the console's legend
                // carries, in the same order and wearing the same glyphs.
                // `.map-legend` is a wrapping flex; an HStack cannot wrap, so
                // the rows are explicit and the gap is a notch tighter than the
                // console's 18px.
                VStack(alignment: .leading, spacing: Space.s) {
                    // Three people, then the two things that are not people.
                    // Five across does not fit a phone at a legible size, and
                    // the flex on the console wraps in the same place.
                    HStack(spacing: Space.m) {
                        MapLegendKey(label: "Searcher", fill: MapInk.searcher, ring: MapInk.markerBorder)
                        MapLegendKey(label: "Possible", fill: MapInk.markerBorder, ring: MapInk.sighting,
                                     glyph: .person)
                        MapLegendKey(label: "Found", fill: MapInk.markerBorder, ring: MapInk.found,
                                     glyph: .person)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: Space.m) {
                        MapLegendKey(label: "Marker", fill: MapInk.marker, ring: MapInk.markerBorder,
                                     glyph: .rounded)
                        MapLegendKey(label: "Hazard", fill: MapInk.hazardFill,
                                     ring: MapInk.hazardStroke, glyph: .hazard)
                        Spacer(minLength: 0)
                    }
                    // The field is a scale, not a category, so its key names
                    // both ends instead of showing one swatch.
                    HStack(spacing: 7) {
                        Text("Cleared")
                        HeatScaleBar()
                        Text("Likely here")
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Shading: pale where the area is cleared, "
                                        + "strong where the person is likely to be.")
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .font(.system(size: 11))
                .foregroundStyle(MapInk.labelSecondary)
                .padding(.horizontal, Space.m)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(MapInk.legendBackground)
                .overlay(alignment: .top) { MapInk.line.frame(height: 1) }
            }
            .clipShape(Radius.rect(Radius.plate))
            .overlay(Radius.rect(Radius.plate).stroke(MapInk.line, lineWidth: 1))
        }
        .padding(Space.xl)
        // Not a presented sheet, on purpose: this card sits over a live camera
        // the operator is still aiming, and a sheet would cover the preview —
        // and could not collapse back into the mini-map the way this does.
        // Close with the button, or by tapping the room behind it
        // (`OperatorView` owns that scrim).
        .background(Surface.card, in: Radius.rect(Radius.sheet))
        .padding(Space.l)
        .accessibilityAction(.escape, onClose)
    }
}

/// `.heat-scale`: the probability ramp, white underneath because the cleared
/// end of it is transparent over the map's white floor.
private struct HeatScaleBar: View {
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 3, style: .continuous) }

    var body: some View {
        shape.fill(.white)
            .overlay(shape.fill(LinearGradient(stops: FloorPlanCanvas.heatStops,
                                               startPoint: .leading, endPoint: .trailing)))
            .overlay(shape.strokeBorder(MapInk.line, lineWidth: 1))
            .frame(width: 54, height: 10)
    }
}

/// `.map-key`: a 20-point disc with a 2-point border, filled for a searcher and
/// hollow for a person. Every key is the same box, so the strip reads as five
/// things of one kind rather than one of them shouting — which is why the
/// hazard triangle is drawn into the same square as the discs instead of being
/// given a bigger one.
private struct MapLegendKey: View {
    /// Which of the map's own shapes this key is showing.
    enum Glyph {
        /// A plain disc: a searcher.
        case disc
        /// `.map-key.sighting::before/::after` — the head and shoulders the map
        /// draws inside a hollow disc for somebody who has been seen.
        case person
        /// `.map-key.marker { border-radius: 5px }`: the alignment marker is the
        /// one thing on the map that is not a person, so it is the one key that
        /// is not a disc — the same distinction the map itself draws.
        case rounded
        /// `.hazard-key`: the warning triangle, the console's own path.
        case hazard
    }

    let label: String
    let fill: Color
    let ring: Color
    var glyph: Glyph = .disc

    /// `.map-key` carries `box-shadow: 0 1px 4px rgba(23,55,38,.18)`; the
    /// hollow person keys turn it off with `box-shadow: none`. So: the filled
    /// keys lift off the strip, the outlined ones sit flat on it.
    private var filled: Bool { fill != MapInk.markerBorder && glyph != .hazard }

    private static let side: CGFloat = 16

    var body: some View {
        HStack(spacing: 7) {
            Group {
                switch glyph {
                case .disc:
                    Circle().fill(fill).overlay(Circle().strokeBorder(ring, lineWidth: 2))
                case .rounded:
                    let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                    shape.fill(fill).overlay(shape.strokeBorder(ring, lineWidth: 2))
                case .person:
                    // Drawn, not composed out of shapes: the same call the map
                    // makes, so the key cannot drift away from the pin. Scaled
                    // by the glyph's *outer* size — a `Canvas` clips to its
                    // bounds, so anything sized by the path alone loses its
                    // stroke where the path runs closest to the edge.
                    Canvas { context, size in
                        PersonGlyph.draw(&context, at: CGPoint(x: size.width / 2, y: size.height / 2),
                                         color: ring, scale: size.width / PersonGlyph.outerUnits)
                    }
                case .hazard:
                    Canvas { context, size in
                        HazardSign.draw(&context, at: CGPoint(x: size.width / 2, y: size.height / 2),
                                        scale: size.width / HazardSign.outerUnits, centred: true)
                    }
                }
            }
            .frame(width: Self.side, height: Self.side)
            .shadow(color: filled ? MapInk.legendKeyShadow : .clear, radius: 2, x: 0, y: 1)
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }
}
