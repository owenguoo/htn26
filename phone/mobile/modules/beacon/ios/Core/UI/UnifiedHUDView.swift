import SwiftUI
import SwarmCore

/// The HUD, drawn from the same `HubHUDMirror` the phone sends to the operator
/// console, with the same geometry `web/console.js` `drawHud` uses to draw it
/// over the live feed. One description, two renderers that follow the same
/// recipe: what the person holding the phone sees and what the operator sees
/// on the feed are the same thing by construction, not by discipline.
///
/// Everything is scaled by `k = width / 390`, exactly as the console does, so
/// the proportions match whatever size either side happens to be.
///
/// Detection / banner / AR chip colours stay the console's literals so both
/// renderers name the same alert the same way. The compass *tape* on the phone
/// is light frosted instead: the Simulator room is light, and a dark slab on
/// top of it was just hardcoded night mode.
enum HUDStyle {
    /// Light frosted bar — readable over the rehearsal room and a bright feed.
    static let tapeBackground = Color.white.opacity(0.88)
    static let detection = Color(hex: "#ff5d73") ?? .red
    /// The ink on a compass marker chip and on the toast.
    static let deepInk = Color(hex: "#05070f") ?? .black

    /// The ink for a compass chip, read against the fill the hub named.
    ///
    /// Every chip used to be near-black, which was fine while the whole palette
    /// was the console's pale yellows, greens and cyans. The alignment marker's
    /// `MARKER_COLOR` purple is dark enough that black-on-purple is barely a
    /// chip at all, so the ink follows the fill's luminance instead of assuming
    /// the fill is light.
    static func chipInk(on fill: String?) -> Color {
        guard let (r, g, b) = HexColor.parse(fill) else { return deepInk }
        let luminance = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        return luminance < 0.55 ? .white : deepInk
    }
    /// "Looking for" text on the light tape plate.
    static let lookingForInk = Color.black.opacity(0.72)
    /// console.js `rgba(255,255,255,0.95)`.
    static let toastBackground = Color.white.opacity(0.95)
    /// Ticks, degree labels, STAGE, and the centre caret.
    static let tapeInk = Color.black.opacity(0.78)
    static let tapeSpanDegrees = 120.0

    /// `TONES` in console.js: background, foreground.
    static func tone(_ name: String) -> (Color, Color) {
        switch name {
        case "ok": (Color(hex: "#7ae582") ?? .green, Color(hex: "#04210a") ?? .black)
        case "alert": (Color(hex: "#ff5d73") ?? .red, .white)
        default: (Color(hex: "#ffb703") ?? .orange, Color(hex: "#1a1200") ?? .black)
        }
    }

    /// `pill()` in console.js: text centred in a fully-rounded capsule.
    static func pill(_ context: inout GraphicsContext, at center: CGPoint, text: String, background: Color,
                     foreground: Color, size: CGFloat, bold: Bool = false, maxWidth: CGFloat? = nil) {
        let resolved = context.resolve(label(text).font(.system(size: size, weight: bold ? .bold : .semibold))
            .foregroundStyle(foreground))
        let measured = resolved.measure(in: CGSize(width: maxWidth ?? .infinity, height: .infinity))
        let width = measured.width + size * 1.4, height = max(size * 1.9, measured.height + size * 0.6)
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        context.fill(Path(roundedRect: rect, cornerRadius: min(height / 2, size * 0.95)), with: .color(background))
        context.draw(resolved, in: CGRect(x: center.x - measured.width / 2, y: center.y - measured.height / 2,
                                          width: measured.width, height: measured.height))
    }

    /// A `Canvas` cannot draw colour emoji, and the hub's toast starts with 📣.
    /// The SF Symbol stands in for it; everything else is the text as sent.
    private static func label(_ text: String) -> Text {
        guard text.hasPrefix("📣") else { return Text(text) }
        let rest = text.dropFirst().drop { $0 == " " }
        return Text(Image(systemName: "megaphone.fill")) + Text(" " + rest)
    }
}

/// A glance-speed indication for a local loud sound or an off-screen find.
/// The cue itself lives in `HubHUDMirror`, beside the compass marker and banner,
/// so this is only a renderer of the same HUD contract sent to the console.
struct HUDSoundEdgeView: View {
    let edge: HubHUDMirror.SoundEdge?

    /// Fades the band in when the target leaves the frame, rather than popping.
    @State private var visible = false


    var body: some View {
        GeometryReader { geometry in
            let color = Color(hex: edge?.color) ?? .red
            // Narrower than the old 24% band — a hint at the bezel, not a wash.
            let width = min(52, geometry.size.width * 0.14)
            let height = min(48, geometry.size.height * 0.08)
            ZStack {
                if let edge {
                    switch edge.side {
                    case "left":
                        LinearGradient(
                            colors: [color.opacity(0.9), color.opacity(0.28), color.opacity(0)],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    case "right":
                        LinearGradient(
                            colors: [color.opacity(0), color.opacity(0.28), color.opacity(0.9)],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    default:
                        LinearGradient(
                            colors: [color.opacity(0.85), color.opacity(0.25), color.opacity(0)],
                            startPoint: .top, endPoint: .bottom)
                            .frame(height: height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        .opacity(bandOpacity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { sync(to: edge) }
        .onChange(of: edge?.side) { _, _ in sync(to: edge) }
        .onChange(of: edge?.color) { _, _ in sync(to: edge) }
    }

    /// Held, not pulsed. Everything else that says "urgent" on this screen — the
    /// wash, the plates — stopped blinking for the same reason: the operator is
    /// looking *through* all of it while they walk, and a surface that changes
    /// brightness is harder to see past than one that does not. The rhythm is
    /// in the haptics.
    private var bandOpacity: Double { visible && edge != nil ? 0.95 : 0 }

    private func sync(to edge: HubHUDMirror.SoundEdge?) {
        if edge != nil {
            withAnimation(.easeInOut(duration: 0.5)) { visible = true }
        } else {
            withAnimation(.easeInOut(duration: 0.35)) { visible = false }
        }
    }
}

/// The screen-space stack: compass tape, guide banner, "looking for", toast —
/// top to bottom in the order and spacing the console uses.
struct HUDStackView: View {
    let hud: HubHUDMirror

    /// Same increments the drawing uses (60/30/40/30/36 × k), at the phone's k ≈ 1.
    /// Tape is taller than the console's 40 so the marker chip and degree
    /// labels are not stacked on top of each other.
    private var contentHeight: CGFloat {
        let rows: [(Bool, CGFloat)] = [(hud.compass != nil, 60), (hud.warning != nil, 30),
                                       (hud.banner != nil, 40), (hud.lookingFor != nil, 30),
                                       (hud.toast != nil, 36)]
        return max(1, rows.reduce(0) { $0 + ($1.0 ? $1.1 : 0) })
    }

    var body: some View {
        GeometryReader { geometry in
            let k = geometry.size.width / 390
            Canvas { context, size in
                var top: CGFloat = 0
                if let compass = hud.compass {
                    drawTape(&context, x0: 0, y0: top, width: size.width, height: 52 * k, compass: compass, k: k)
                    top += 60 * k
                }
                // Directly under the tape, above the banner: what is about to be
                // underfoot outranks what the operator is being asked to do
                // about the search.
                if let warning = hud.warning {
                    HUDStyle.pill(&context, at: CGPoint(x: size.width / 2, y: top + 12 * k),
                                  text: warning.text,
                                  background: Color(hex: warning.color) ?? .orange,
                                  foreground: HUDStyle.chipInk(on: warning.color),
                                  size: 13 * k, bold: true, maxWidth: size.width - 30 * k)
                    top += 30 * k
                }
                if let banner = hud.banner {
                    let (background, foreground) = HUDStyle.tone(banner.tone)
                    HUDStyle.pill(&context, at: CGPoint(x: size.width / 2, y: top + 16 * k), text: banner.text,
                                  background: background, foreground: foreground, size: 15 * k, bold: true,
                                  maxWidth: size.width - 30 * k)
                    top += 40 * k
                }
                if let lookingFor = hud.lookingFor {
                    HUDStyle.pill(&context, at: CGPoint(x: size.width / 2, y: top + 12 * k), text: lookingFor,
                                  background: HUDStyle.tapeBackground.opacity(1), foreground: HUDStyle.lookingForInk,
                                  size: 12 * k, maxWidth: size.width - 30 * k)
                    top += 30 * k
                }
                if let toast = hud.toast {
                    HUDStyle.pill(&context, at: CGPoint(x: size.width / 2, y: top + 14 * k), text: toast,
                                  background: HUDStyle.toastBackground, foreground: HUDStyle.deepInk,
                                  size: 13 * k, bold: true, maxWidth: size.width - 30 * k)
                }
            }
        }
        .frame(height: contentHeight)
        .allowsHitTesting(false)
    }

    /// `drawTape()` in console.js, line for line.
    private func drawTape(_ context: inout GraphicsContext, x0: CGFloat, y0: CGFloat, width: CGFloat,
                          height: CGFloat, compass: HubHUDMirror.Compass, k: CGFloat) {
        let span = HUDStyle.tapeSpanDegrees
        let pointsPerDegree = width / span, centerX = x0 + width / 2
        let tape = CGRect(x: x0, y: y0, width: width, height: height)
        context.fill(Path(roundedRect: tape, cornerRadius: 10 * k), with: .color(HUDStyle.tapeBackground))

        context.drawLayer { layer in
            layer.clip(to: Path(roundedRect: tape, cornerRadius: 10 * k))
            var degree = (compass.center - span / 2).rounded(.up)
            degree = (degree / 5).rounded(.up) * 5
            while degree <= compass.center + span / 2 {
                let x = centerX + (degree - compass.center) * pointsPerDegree
                let wrapped = Int(RoomMath.wrap360(degree).rounded()) % 360
                let major = wrapped % 15 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: y0 + height - (major ? 10 : 6) * k))
                tick.addLine(to: CGPoint(x: x, y: y0 + height - 2))
                layer.stroke(tick, with: .color(HUDStyle.tapeInk.opacity(major ? 0.7 : 0.3)),
                             lineWidth: major ? 1.5 : 1)
                if major {
                    // Room degrees, never N/E/S/W: `.gravity` alignment has no true north.
                    // Sit just above the ticks — leaves a clear gap under the marker chips.
                    layer.draw(Text(String(wrapped)).font(.system(size: 9 * k, weight: .semibold))
                        .foregroundStyle(HUDStyle.tapeInk.opacity(0.55)), at: CGPoint(x: x, y: y0 + height - 16 * k))
                }
                degree += 5
            }

            for marker in compass.markers {
                let edge = abs(marker.off) > span / 2 - 8
                let x = edge ? (marker.off > 0 ? x0 + width - 18 * k : x0 + 18 * k)
                    : centerX + marker.off * pointsPerDegree
                let label = edge ? (marker.off > 0 ? "\(marker.label) ▶" : "◀ \(marker.label)") : marker.label
                if marker.label == "STAGE" {
                    drawStageLandmark(&layer, x: x, y0: y0, label: label, k: k)
                    continue
                }
                let text = layer.resolve(Text(label).font(.system(size: (marker.big ? 10 : 9) * k, weight: .heavy))
                    .foregroundStyle(HUDStyle.chipInk(on: marker.color)))
                let textWidth = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width + 10 * k
                let boxX = max(x0 + 2, min(x0 + width - textWidth - 2, x - textWidth / 2))
                // Top of the tape, clear of the degree row which sits near the ticks.
                let box = CGRect(x: boxX, y: y0 + 4 * k, width: textWidth, height: 15 * k)
                layer.fill(Path(roundedRect: box, cornerRadius: 7.5 * k), with: .color(Color(hex: marker.color) ?? .white))
                layer.draw(text, at: CGPoint(x: box.midX, y: box.midY))
            }
        }

        var caret = Path()
        caret.move(to: CGPoint(x: centerX - 5 * k, y: y0 + height))
        caret.addLine(to: CGPoint(x: centerX + 5 * k, y: y0 + height))
        caret.addLine(to: CGPoint(x: centerX, y: y0 + height - 6 * k))
        caret.closeSubpath()
        context.fill(caret, with: .color(HUDStyle.tapeInk))
    }

    /// The stage is a permanent room landmark, not an alert. Quiet label only —
    /// no coloured badge or locator tick (those are for temporary guidance).
    private func drawStageLandmark(_ context: inout GraphicsContext, x: CGFloat, y0: CGFloat,
                                   label: String, k: CGFloat) {
        let text = context.resolve(Text(label).font(.system(size: 9 * k, weight: .bold))
            .foregroundStyle(HUDStyle.tapeInk.opacity(0.9)))
        let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        let minimumX = measured.width / 2 + 2 * k
        let maximumX = 390 * k - measured.width / 2 - 2 * k
        let labelX = max(minimumX, min(maximumX, x))
        context.draw(text, at: CGPoint(x: labelX, y: y0 + 8 * k))
    }
}

/// The frame-space layer: detection boxes and the diamonds floating on pings
/// and the candidate. Positions are fractions of the upright frame the hub has,
/// mapped onto the aspect-filled preview.
struct HUDFrameLayerView: View {
    let hud: HubHUDMirror
    let captureSize: CGSize
    /// Drive mode draws candidates in the backdrop with `RoomCamera`; camera-
    /// frame AR diamonds would disagree with that picture.
    var showAR: Bool = true

    var body: some View {
        GeometryReader { geometry in
            let transform = ImageToViewTransform(capture: captureSize, view: geometry.size)
            let k = geometry.size.width / 390
            Canvas { context, size in
                for box in hud.dets ?? [] {
                    let color: Color = box.label == "Hazard" ? .orange : box.possibleMatch == true ? .green : HUDStyle.detection
                    let rect = transform.rect(uprightFractionX: box.x, y: box.y, width: box.w, height: box.h)
                    // 2, not 3: `web/console.js:367` strokes detections at 2 and
                    // the two renderers have to draw the same box.
                    context.stroke(Path(rect), with: .color(color), lineWidth: 2)
                    let label = box.displayLabel
                    guard !label.isEmpty else { continue }
                    let text = context.resolve(Text(label).font(.system(size: 13 * k, weight: .bold))
                        .foregroundStyle(.white))
                    let width = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width + 10
                    let tag = CGRect(x: max(0, min(rect.minX, size.width - width)),
                                     y: max(0, min(rect.minY - 20 * k, size.height - 20 * k)),
                                     width: width, height: 20 * k)
                    context.fill(Path(tag), with: .color(color))
                    context.draw(text, at: CGPoint(x: tag.midX, y: tag.midY))
                }
                guard showAR else { return }
                for marker in hud.ar {
                    let at = transform.rect(uprightFractionX: marker.x, y: marker.y, width: 0, height: 0).origin
                    let r = max(6, marker.r * size.height)
                    let color = Color(hex: marker.color) ?? .yellow
                    if marker.label.hasPrefix("MARKER") {
                        // The alignment marker is a thing on a wall, not a spot
                        // to walk to, and the map already draws that difference:
                        // a rounded tag in `MARKER_COLOR` with a white border
                        // (`drawMarker` in `FloorPlanViews`), never the ping
                        // diamond. One shape for one thing, in both pictures.
                        let side = r * 2.2
                        let tag = Path(roundedRect: CGRect(x: at.x - side / 2, y: at.y - side / 2,
                                                           width: side, height: side),
                                       cornerRadius: side / 4)
                        context.fill(tag, with: .color(color))
                        context.stroke(tag, with: .color(.white), lineWidth: 2)
                        HUDStyle.pill(&context, at: CGPoint(x: at.x, y: at.y - side / 2 - 13 * k),
                                      text: marker.label, background: .black.opacity(0.7),
                                      foreground: .white, size: 12 * k)
                        continue
                    }
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: at.x, y: at.y - r))
                    diamond.addLine(to: CGPoint(x: at.x + r, y: at.y))
                    diamond.addLine(to: CGPoint(x: at.x, y: at.y + r))
                    diamond.addLine(to: CGPoint(x: at.x - r, y: at.y))
                    diamond.closeSubpath()
                    if marker.hollow {
                        // A teammate. Outline only, so a searcher can never be
                        // read as the person being searched for — the filled
                        // diamond below is what a find looks like.
                        context.stroke(diamond, with: .color(.black.opacity(0.5)), lineWidth: 4)
                        context.stroke(diamond, with: .color(color), lineWidth: 2)
                    } else {
                        context.fill(diamond, with: .color(color))
                        context.stroke(diamond, with: .color(.black.opacity(0.6)), lineWidth: 2)
                    }
                    HUDStyle.pill(&context, at: CGPoint(x: at.x, y: at.y - r - 13 * k), text: marker.label,
                                  background: .black.opacity(0.7), foreground: .white, size: 12 * k)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
