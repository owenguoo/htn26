import SwiftUI
import SwarmCore

/// The room, drawn where the camera would be.
///
/// It replaces `ReplayBackdrop` on the drive path, and it exists for one
/// reason: a HUD floating on a flat gradient can only be judged as typography.
/// Over a floor that slides and a stage wall that swings out of shot as you
/// turn, you can see whether the compass tape moves the right way, whether the
/// mini-map cone agrees with what is in front of you, and whether a heading
/// sign is mirrored — which `phone/CLAUDE.md` calls out as the most
/// consequential class of bug here.
///
/// **It is a backdrop, not a game.** A floor grid on the room's own metre
/// lines, the room's bounds, and the stage wall are enough to answer "which way
/// am I facing"; everything is drawn in the mini-map's own palette at low
/// contrast so it stays behind the HUD rather than competing with it. There is
/// no texture, no lighting and no motion that is not the operator's.
///
/// Nothing here is new plumbing: `overlay.room` and `overlay.roomPose` are
/// already on every `OverlayFrame`.
struct DriveBackdropView: View {
    /// From the hub's `welcome`. nil until it arrives, and then `room.json`'s
    /// own numbers stand in — the same default `DriveBounds` starts with, so
    /// the picture does not jump when `welcome` lands.
    let room: HubRoom?
    /// Where the operator has driven to. nil before the first pose.
    let pose: RoomPose?
    /// The confirmed person, at the same room coordinate used by the compass
    /// and mini-map. nil until the hub has actually found someone.
    let candidate: PingCue?

    private var width: Double { max(1, room?.width ?? DriveBounds.roomJSON.width) }
    private var depth: Double { max(1, room?.depth ?? DriveBounds.roomJSON.depth) }

    var body: some View {
        GeometryReader { geometry in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let camera = RoomCamera(
                    x: pose?.x ?? 0,
                    y: pose?.y ?? depth / 3,
                    heading: pose?.heading ?? 0,
                    pitch: pose?.pitch ?? 0,
                    // Matches `DriveBounds.eyeHeight`. The two are the same
                    // camera; a mismatch would put the horizon somewhere the
                    // poses say it is not.
                    eye: DriveBounds.roomJSON.eyeHeight,
                    // The mini-map's cone angle, so the slice of room in shot
                    // and the slice the cone claims are the same slice. The
                    // vertical field is therefore wide — which is what puts
                    // enough floor on screen for a turn to be legible.
                    fovDegrees: room?.cameraFovDeg ?? 55,
                    size: size)
                draw(&context, camera: camera)
            }
        }
        .background(
            // As dark as the feed it stands in for, so the HUD's contrast is
            // the same thing in the Simulator as it is on a device.
            LinearGradient(colors: [Color(red: 0.05, green: 0.07, blue: 0.16), .hudVoid],
                           startPoint: .top, endPoint: .bottom)
        )
        .cameraChrome()
        .ignoresSafeArea()
        // The whole point is that `DriveLookLayer` underneath gets the drag.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Metres, floor to the top of the drawn walls. Head height plus a bit, so
    /// the wall line sits above the horizon and reads as a wall.
    private static let wallHeight: Double = 2.6

    private func draw(_ context: inout GraphicsContext, camera: RoomCamera) {
        let halfWidth = width / 2

        // The floor, darker than the space above it. The horizon then needs no
        // line of its own: it is where the two meet.
        if let floor = camera.polygon([(-halfWidth, 0, 0), (halfWidth, 0, 0),
                                       (halfWidth, depth, 0), (-halfWidth, depth, 0)]) {
            context.fill(floor, with: .color(MapInk.floor))
        }

        // Metre lines, on the room's own grid — the same numbers the mini-map
        // is drawn in, so pacing across one is a metre in both.
        var grid = Path()
        var line = -halfWidth.rounded(.up)
        while line <= halfWidth {
            camera.add(&grid, from: (line, 0, 0), to: (line, depth, 0))
            line += 1
        }
        var row: Double = 0
        while row <= depth {
            camera.add(&grid, from: (-halfWidth, row, 0), to: (halfWidth, row, 0))
            row += 1
        }
        context.stroke(grid, with: .color(.white.opacity(0.13)), lineWidth: 1)

        drawRehearsalScene(&context, camera: camera)

        // The stage wall: the one landmark that makes "facing the stage"
        // unambiguous without reading anything. Same fill the mini-map gives
        // the stage, so the two pictures name it the same way.
        let stageWidth = min(width, room?.stage?.width ?? width * 0.4)
        let stageHalf = stageWidth / 2
        if let band = camera.polygon([(-stageHalf, 0, 0), (stageHalf, 0, 0),
                                      (stageHalf, 0, Self.wallHeight), (-stageHalf, 0, Self.wallHeight)]) {
            context.fill(band, with: .color(MapInk.stage.opacity(0.22)))
            context.stroke(band, with: .color(MapInk.outline.opacity(0.5)), lineWidth: 1.5)
            label(&context, in: band.boundingRect)
        }
        // The stage platform's own footprint, so its depth is visible from the
        // side as well as head-on.
        if let stage = room?.stage, stage.depth > 0 {
            var footprint = Path()
            camera.add(&footprint, from: (-stageHalf, stage.depth, 0), to: (stageHalf, stage.depth, 0))
            camera.add(&footprint, from: (-stageHalf, 0, 0), to: (-stageHalf, stage.depth, 0))
            camera.add(&footprint, from: (stageHalf, 0, 0), to: (stageHalf, stage.depth, 0))
            context.stroke(footprint, with: .color(MapInk.outline.opacity(0.35)), lineWidth: 1)
        }

        // The room's bounds, floor line and wall top, so a wall arrives before
        // you walk into it.
        var walls = Path()
        let corners: [(Double, Double)] = [(-halfWidth, 0), (halfWidth, 0), (halfWidth, depth), (-halfWidth, depth)]
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            camera.add(&walls, from: (a.0, a.1, Self.wallHeight), to: (b.0, b.1, Self.wallHeight))
            camera.add(&walls, from: (a.0, a.1, 0), to: (a.0, a.1, Self.wallHeight))
        }
        context.stroke(walls, with: .color(MapInk.outline.opacity(0.28)), lineWidth: 1)
    }

    /// A repeatable, deliberately varied room for exercising the drive mode.
    ///
    /// The people cover stage-left, right aisle and rear-room bearings. The
    /// props give the simulated camera enough landmarks to make turning and
    /// walking legible without pretending this wireframe is a real camera
    /// feed. Nothing here participates in search logic: the highlighted person
    /// below is placed from the hub's real `world.candidate` coordinate.
    private func drawRehearsalScene(_ context: inout GraphicsContext, camera: RoomCamera) {
        let people: [(x: Double, y: Double)] = [
            (-width * 0.24, depth * 0.32),
            (width * 0.27, depth * 0.52),
            (-width * 0.08, depth * 0.78),
        ]
        for person in people {
            drawPerson(&context, camera: camera, x: person.x, y: person.y,
                       color: .white.opacity(0.34))
        }

        drawTable(&context, camera: camera, x: width * 0.22, y: depth * 0.28,
                  color: .white.opacity(0.19))
        drawChair(&context, camera: camera, x: -width * 0.30, y: depth * 0.48,
                  color: .white.opacity(0.19))
        drawBox(&context, camera: camera, x: width * 0.31, y: depth * 0.67,
                width: 0.9, depth: 0.55, height: 0.65, color: .white.opacity(0.19))
        drawBackpack(&context, camera: camera, x: -width * 0.20, y: depth * 0.64,
                     color: .white.opacity(0.23))
        drawCone(&context, camera: camera, x: width * 0.06, y: depth * 0.42,
                 color: .white.opacity(0.23))

        if let candidate {
            drawPerson(&context, camera: camera, x: candidate.x, y: candidate.y,
                       color: HUDStyle.detection, label: "FOUND PERSON")
        }
    }

    private func drawPerson(_ context: inout GraphicsContext, camera: RoomCamera,
                            x: Double, y: Double, color: Color, label: String? = nil) {
        var body = Path()
        camera.add(&body, from: (x, y, 0.25), to: (x, y, 1.42))
        camera.add(&body, from: (x, y, 1.12), to: (x - 0.34, y, 0.78))
        camera.add(&body, from: (x, y, 1.12), to: (x + 0.34, y, 0.78))
        camera.add(&body, from: (x, y, 0.72), to: (x - 0.25, y, 0))
        camera.add(&body, from: (x, y, 0.72), to: (x + 0.25, y, 0))
        // The second shoulder axis keeps a person recognizable when viewed
        // from the side, where the x-axis stick figure would collapse.
        camera.add(&body, from: (x, y - 0.18, 1.1), to: (x, y + 0.18, 1.1))
        context.stroke(body, with: .color(color), lineWidth: label == nil ? 2 : 3)

        guard let head = camera.point((x, y, 1.62)) else { return }
        let radius = camera.projectedRadius(at: (x, y, 1.62), metres: 0.13)
        context.stroke(Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius,
                                              width: radius * 2, height: radius * 2)),
                       with: .color(color), lineWidth: label == nil ? 2 : 3)
        guard let label else { return }
        let text = context.resolve(Text(label).font(.system(size: 11, weight: .heavy))
            .foregroundStyle(HUDStyle.deepInk))
        let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        let badge = CGRect(x: head.x - measured.width / 2 - 6,
                           y: head.y - radius - measured.height - 10,
                           width: measured.width + 12, height: measured.height + 5)
        context.fill(Path(roundedRect: badge, cornerRadius: badge.height / 2), with: .color(color))
        context.draw(text, at: CGPoint(x: badge.midX, y: badge.midY))
    }

    private func drawTable(_ context: inout GraphicsContext, camera: RoomCamera,
                           x: Double, y: Double, color: Color) {
        let halfWidth = 0.75, halfDepth = 0.4, top = 0.78
        var path = Path()
        let corners = [(x - halfWidth, y - halfDepth), (x + halfWidth, y - halfDepth),
                       (x + halfWidth, y + halfDepth), (x - halfWidth, y + halfDepth)]
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            camera.add(&path, from: (a.0, a.1, top), to: (b.0, b.1, top))
            camera.add(&path, from: (a.0, a.1, 0), to: (a.0, a.1, top))
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    private func drawChair(_ context: inout GraphicsContext, camera: RoomCamera,
                           x: Double, y: Double, color: Color) {
        let half = 0.28, seat = 0.48, back = 1.05
        var path = Path()
        let corners = [(x - half, y - half), (x + half, y - half),
                       (x + half, y + half), (x - half, y + half)]
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            camera.add(&path, from: (a.0, a.1, seat), to: (b.0, b.1, seat))
            camera.add(&path, from: (a.0, a.1, 0), to: (a.0, a.1, seat))
        }
        camera.add(&path, from: (x - half, y + half, seat), to: (x - half, y + half, back))
        camera.add(&path, from: (x + half, y + half, seat), to: (x + half, y + half, back))
        camera.add(&path, from: (x - half, y + half, back), to: (x + half, y + half, back))
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    private func drawBox(_ context: inout GraphicsContext, camera: RoomCamera,
                         x: Double, y: Double, width boxWidth: Double, depth boxDepth: Double,
                         height: Double, color: Color) {
        let x0 = x - boxWidth / 2, x1 = x + boxWidth / 2
        let y0 = y - boxDepth / 2, y1 = y + boxDepth / 2
        let corners = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        var path = Path()
        for index in corners.indices {
            let a = corners[index], b = corners[(index + 1) % corners.count]
            camera.add(&path, from: (a.0, a.1, 0), to: (b.0, b.1, 0))
            camera.add(&path, from: (a.0, a.1, height), to: (b.0, b.1, height))
            camera.add(&path, from: (a.0, a.1, 0), to: (a.0, a.1, height))
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    private func drawBackpack(_ context: inout GraphicsContext, camera: RoomCamera,
                              x: Double, y: Double, color: Color) {
        var path = Path()
        camera.add(&path, from: (x - 0.28, y, 0), to: (x - 0.22, y, 0.66))
        camera.add(&path, from: (x - 0.22, y, 0.66), to: (x, y, 0.82))
        camera.add(&path, from: (x, y, 0.82), to: (x + 0.22, y, 0.66))
        camera.add(&path, from: (x + 0.22, y, 0.66), to: (x + 0.28, y, 0))
        camera.add(&path, from: (x - 0.28, y, 0), to: (x + 0.28, y, 0))
        camera.add(&path, from: (x - 0.15, y, 0.72), to: (x + 0.15, y, 0.72))
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    private func drawCone(_ context: inout GraphicsContext, camera: RoomCamera,
                          x: Double, y: Double, color: Color) {
        var path = Path()
        camera.add(&path, from: (x - 0.28, y, 0), to: (x, y, 0.7))
        camera.add(&path, from: (x + 0.28, y, 0), to: (x, y, 0.7))
        camera.add(&path, from: (x - 0.28, y, 0), to: (x + 0.28, y, 0))
        camera.add(&path, from: (x - 0.17, y, 0.28), to: (x + 0.17, y, 0.28))
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    /// "STAGE" across the band, but only when the band is big enough on screen
    /// for the word to be a landmark rather than clutter.
    private func label(_ context: inout GraphicsContext, in rect: CGRect) {
        guard rect.width > 90, rect.height > 24 else { return }
        context.draw(Text("STAGE").font(.system(size: 13, weight: .heavy))
            .foregroundStyle(MapInk.outline.opacity(0.75)),
                     at: CGPoint(x: rect.midX, y: rect.midY))
    }
}

/// A pinhole camera standing in the room frame.
///
/// Room coordinates in, screen points out. Kept next to the only view that uses
/// it rather than in SwarmCore: it is a drawing convenience, not a claim about
/// where anything is, and `RoomAlignment` already owns the real transform.
private struct RoomCamera {
    let x: Double
    let y: Double
    /// Degrees clockwise, 0 = facing the stage, as everywhere else in the room
    /// frame.
    let heading: Double
    /// Degrees, positive up.
    let pitch: Double
    let eye: Double
    let fovDegrees: Double
    let size: CGSize

    /// Anything closer than this is behind or on top of the lens and has to be
    /// clipped away rather than projected, or a line whips across the screen.
    private static let near: Double = 0.35

    /// Points per unit of `f = 1`, from the horizontal field of view.
    private var focal: Double {
        let half = max(5, min(150, fovDegrees)) / 2 * .pi / 180
        return Double(size.width) / 2 / max(tan(half), 1e-3)
    }

    /// Room point → camera space: right of the lens, above it, in front of it.
    private func view(_ point: (Double, Double, Double)) -> SIMD3<Double> {
        let dx = point.0 - x, dy = point.1 - y
        let radians = heading * .pi / 180
        // Heading 0 faces the stage, which is −y; +90 faces +x. Same convention
        // as `DriveMotionModel`, which is the point of writing it out here.
        let forward = dx * sin(radians) - dy * cos(radians)
        let right = dx * cos(radians) + dy * sin(radians)
        let up = point.2 - eye
        let tilt = pitch * .pi / 180
        return SIMD3(right, up * cos(tilt) - forward * sin(tilt), forward * cos(tilt) + up * sin(tilt))
    }

    private func screen(_ v: SIMD3<Double>) -> CGPoint {
        let depth = max(v.z, Self.near)
        return CGPoint(x: Double(size.width) / 2 + v.x / depth * focal,
                       y: Double(size.height) / 2 - v.y / depth * focal)
    }

    func point(_ point: (Double, Double, Double)) -> CGPoint? {
        let cameraPoint = view(point)
        guard cameraPoint.z >= Self.near else { return nil }
        return screen(cameraPoint)
    }

    /// A world-space radius expressed in screen points. Taking the larger of
    /// the room x/y axes keeps billboard details visible from every heading.
    func projectedRadius(at point: (Double, Double, Double), metres: Double) -> CGFloat {
        guard let center = self.point(point) else { return 0 }
        let x = self.point((point.0 + metres, point.1, point.2))
        let y = self.point((point.0, point.1 + metres, point.2))
        return max(2, max(x.map { hypot($0.x - center.x, $0.y - center.y) } ?? 0,
                          y.map { hypot($0.x - center.x, $0.y - center.y) } ?? 0))
    }

    /// Appends one room-frame segment, clipped to the near plane.
    ///
    /// World → camera is affine, so `z` varies linearly along the segment and
    /// the crossing can be found by interpolating the camera-space endpoints
    /// directly. No projection happens before the clip, which is what stops a
    /// point behind the lens from being drawn in front of it, mirrored.
    func add(_ path: inout Path, from a: (Double, Double, Double), to b: (Double, Double, Double)) {
        var va = view(a), vb = view(b)
        if va.z < Self.near, vb.z < Self.near { return }
        if va.z < Self.near {
            va = mix(va, vb, t: (Self.near - va.z) / (vb.z - va.z))
        } else if vb.z < Self.near {
            vb = mix(vb, va, t: (Self.near - vb.z) / (va.z - vb.z))
        }
        path.move(to: screen(va))
        path.addLine(to: screen(vb))
    }

    /// A convex room-frame polygon, clipped to the near plane by
    /// Sutherland–Hodgman against the single plane that matters.
    func polygon(_ points: [(Double, Double, Double)]) -> Path? {
        var clipped: [SIMD3<Double>] = []
        let corners = points.map(view)
        for index in corners.indices {
            let current = corners[index], next = corners[(index + 1) % corners.count]
            let currentIn = current.z >= Self.near, nextIn = next.z >= Self.near
            if currentIn { clipped.append(current) }
            if currentIn != nextIn {
                clipped.append(mix(current, next, t: (Self.near - current.z) / (next.z - current.z)))
            }
        }
        guard clipped.count >= 3 else { return nil }
        var path = Path()
        path.addLines(clipped.map(screen))
        path.closeSubpath()
        return path
    }

    private func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double) -> SIMD3<Double> {
        guard t.isFinite else { return a }
        return a + (b - a) * min(1, max(0, t))
    }
}
