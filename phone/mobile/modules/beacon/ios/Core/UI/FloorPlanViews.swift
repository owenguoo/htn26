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

    /// The stage block, above the room's top edge.
    var stageRect: CGRect? {
        guard let stage = room.stage else { return nil }
        let topLeft = point(x: -stage.width / 2, y: -stage.depth)
        return CGRect(x: topLeft.x, y: topLeft.y, width: length(stage.width), height: length(stage.depth))
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

            var labels: [CGRect] = []
            drawPings(&context, plan: plan)
            drawCandidate(&context, plan: plan, labels: &labels, size: size)
            for who in people {
                phone(&context, at: plan.point(x: who.x, y: who.y), heading: who.heading, number: who.index)
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
        var out = phones.map { Searcher(x: $0.x, y: $0.y, heading: $0.h, index: $0.i) }
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
            layer.interpolation = .high
            layer.draw(Image(decorative: field, scale: 1, orientation: .up), in: rect)
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
        let sorted = bins.sorted()
        let spread = Double(sorted[n - 1] - sorted[Int(Double(n) * heatLowPercentile)]) / Double(top)
        guard spread > heatMinSpread else { return nil }
        return heatEqualise(bins)
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

    /// `HEAT_MAX_ALPHA` / `HEAT_GAMMA` / `HEAT_STEPS` / `HEAT_MIN_SPREAD` /
    /// `HEAT_LOW_PERCENTILE` in `web/room.js`. Keep the five in step with it.
    static let heatMaxAlpha: Double = 0.34
    static let heatGamma: Double = 1.8
    static let heatSteps = 36
    static let heatMinSpread: Double = 0.04
    static let heatLowPercentile: Double = 0.05

    static func heatAlpha(_ level: Double) -> Double {
        heatMaxAlpha * pow(min(1, max(0, level)), heatGamma)
    }

    /// The field as a cols×rows bitmap in `MapInk.heat`, one pixel per cell,
    /// drawn scaled up with interpolation. `heatCanvas()` in `web/room.js`.
    static func heatImage(_ levels: [Double], cols: Int, rows: Int) -> CGImage? {
        guard cols > 0, rows > 0, levels.count >= cols * rows else { return nil }
        // `MapInk.heat` = rgb(24, 131, 75), premultiplied by the cell's alpha.
        let ink = (r: 24.0, g: 131.0, b: 75.0)
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
            Gradient(colors: [MapInk.heat.opacity(0.12), MapInk.heat.opacity(0)]),
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

    /// `drawPersonGlyph()`: a head and shoulders in a white disc.
    private func person(_ context: inout GraphicsContext, at point: CGPoint, color: Color) {
        let circle = Path(ellipseIn: CGRect(x: point.x - MapMarker.radius, y: point.y - MapMarker.radius,
                                            width: MapMarker.radius * 2, height: MapMarker.radius * 2))
        context.fill(circle, with: .color(MapInk.markerBorder))
        context.stroke(circle, with: .color(color), lineWidth: MapMarker.stroke)
        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.7, y: point.y - 6.2, width: 5.4, height: 5.4)),
                     with: .color(color))
        context.fill(Path(roundedRect: CGRect(x: point.x - 4.5, y: point.y + 0.5, width: 9, height: 5.5),
                          cornerRadius: 3), with: .color(color))
    }

    /// `drawPings()`: an expanding ring, a dark diamond, and the label above it.
    private func drawPings(_ context: inout GraphicsContext, plan: FloorPlanGeometry) {
        for ping in pings {
            let p = plan.point(x: ping.x, y: ping.y)
            let k = time.truncatingRemainder(dividingBy: 1)
            let radius = CGFloat(6 + k * 18)
            context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(MapInk.heat.opacity(0.8 * (1 - k))), lineWidth: 1)
            var diamond = Path()
            diamond.move(to: CGPoint(x: p.x, y: p.y - 7))
            diamond.addLine(to: CGPoint(x: p.x + 7, y: p.y))
            diamond.addLine(to: CGPoint(x: p.x, y: p.y + 7))
            diamond.addLine(to: CGPoint(x: p.x - 7, y: p.y))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(MapInk.ping))
            guard showsDetail else { continue }
            context.draw(Text(ping.label).font(.system(size: 11, weight: .medium))
                .foregroundStyle(MapInk.ping), at: CGPoint(x: p.x, y: p.y - 14))
        }
    }

    /// The found-person half of `drawCandidate()`. The rehearsal target, the
    /// responder lines and the marker pin are console-only: nothing in the
    /// phone's `world` message describes them.
    private func drawCandidate(_ context: inout GraphicsContext, plan: FloorPlanGeometry,
                               labels: inout [CGRect], size: CGSize) {
        guard let candidate = world?.candidate else { return }
        let p = plan.point(x: candidate.x, y: candidate.y)
        // `(performance.now() / 1100) % 1` — a little slower than the pings.
        let k = (time * 1000 / 1100).truncatingRemainder(dividingBy: 1)
        let radius = MapMarker.radius + MapMarker.stroke + 1 + CGFloat(k * 24)
        context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                              width: radius * 2, height: radius * 2)),
                       with: .color(MapInk.found.opacity(0.7 * (1 - k))), lineWidth: 2)
        person(&context, at: p, color: MapInk.found)
        guard showsDetail else { return }
        let y = p.y - MapMarker.radius - MapMarker.stroke / 2 - MapMarker.labelGap - MapMarker.labelHeight / 2
        mapLabel(&context, "FOUND PERSON", at: CGPoint(x: p.x, y: y), background: MapInk.found,
                 labels: &labels, size: size)
    }

    /// `drawMapLabel()` plus `reserveMapLabel()`: a pill in the marker's colour,
    /// nudged vertically until it is not sitting on another one.
    private func mapLabel(_ context: inout GraphicsContext, _ text: String, at point: CGPoint,
                          background: Color, labels: inout [CGRect], size: CGSize) {
        let resolved = context.resolve(Text(text).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MapInk.markerBorder))
        let width = resolved.measure(in: CGSize(width: .infinity, height: .infinity)).width + 12
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
            PulsingFloorPlan(isAnimating: !pings.isEmpty || world?.candidate != nil) { time in
                FloorPlanCanvas(room: room, world: world, me: me, pings: pings,
                                followsMe: true, showsDetail: false, time: time)
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
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Search map").font(TypeScale.sheetTitle)
                    Text("\(Int(room.width)) × \(Int(room.depth)) m · \(summary)")
                        .font(TypeScale.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

            VStack(spacing: 0) {
                PulsingFloorPlan(isAnimating: !pings.isEmpty || world?.candidate != nil) { time in
                    FloorPlanCanvas(room: room, world: world, me: me, pings: pings, time: time)
                }
                .aspectRatio(room.width / max(1, room.depth + (room.stage?.depth ?? 0)), contentMode: .fit)
                .accessibilityLabel("Room plan. You, your team, and what has been searched.")

                // `.map-legend`: a full-width strip under the map, not a card
                // floating over the floor.
                HStack(spacing: Space.l) {
                    MapLegendKey(label: "Searcher", fill: MapInk.searcher, ring: MapInk.markerBorder)
                    MapLegendKey(label: "Possible", fill: MapInk.markerBorder, ring: MapInk.sighting)
                    MapLegendKey(label: "Found", fill: MapInk.markerBorder, ring: MapInk.found)
                    Spacer(minLength: 0)
                }
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
        // the operator is still aiming, and a sheet would cover the preview.
        .background(Surface.card, in: Radius.rect(Radius.sheet))
        .padding(Space.l)
    }
}

/// `.map-key`: a 20-point disc with a 2-point border, filled for a searcher and
/// hollow for a person.
private struct MapLegendKey: View {
    let label: String
    let fill: Color
    let ring: Color

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(fill)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(ring, lineWidth: 2))
            Text(label)
        }
        .accessibilityElement(children: .combine)
    }
}
