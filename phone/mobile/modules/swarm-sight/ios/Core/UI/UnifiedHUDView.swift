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
enum HUDStyle {
    static let tapeBackground = Color(.sRGB, red: 12 / 255, green: 17 / 255, blue: 32 / 255, opacity: 0.82)
    static let detection = Color(hex: "#ff5d73") ?? .red
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

/// The screen-space stack: compass tape, guide banner, "looking for", toast —
/// top to bottom in the order and spacing the console uses.
struct HUDStackView: View {
    let hud: HubHUDMirror

    /// Same increments the drawing uses (48/40/30/36 × k), at the phone's k ≈ 1.
    private var contentHeight: CGFloat {
        let rows: [(Bool, CGFloat)] = [(hud.compass != nil, 48), (hud.banner != nil, 44),
                                       (hud.lookingFor != nil, 30), (hud.toast != nil, 38)]
        return max(1, rows.reduce(0) { $0 + ($1.0 ? $1.1 : 0) })
    }

    var body: some View {
        GeometryReader { geometry in
            let k = geometry.size.width / 390
            Canvas { context, size in
                var top: CGFloat = 0
                if let compass = hud.compass {
                    drawTape(&context, x0: 0, y0: top, width: size.width, height: 40 * k, compass: compass, k: k)
                    top += 48 * k
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
                                  background: HUDStyle.tapeBackground.opacity(1), foreground: Color(hex: "#eef2ff") ?? .white,
                                  size: 12 * k, maxWidth: size.width - 30 * k)
                    top += 30 * k
                }
                if let toast = hud.toast {
                    HUDStyle.pill(&context, at: CGPoint(x: size.width / 2, y: top + 14 * k), text: toast,
                                  background: .white.opacity(0.95), foreground: Color(hex: "#05070f") ?? .black,
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
                layer.stroke(tick, with: .color(.white.opacity(major ? 0.7 : 0.3)), lineWidth: major ? 1.5 : 1)
                if major {
                    // Room degrees, never N/E/S/W: `.gravity` alignment has no true north.
                    layer.draw(Text(String(wrapped)).font(.system(size: 9 * k, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55)), at: CGPoint(x: x, y: y0 + height - 18 * k))
                }
                degree += 5
            }

            for marker in compass.markers {
                let edge = abs(marker.off) > span / 2 - 8
                let x = edge ? (marker.off > 0 ? x0 + width - 18 * k : x0 + 18 * k)
                    : centerX + marker.off * pointsPerDegree
                let label = edge ? (marker.off > 0 ? "\(marker.label) ▶" : "◀ \(marker.label)") : marker.label
                let text = layer.resolve(Text(label).font(.system(size: (marker.big ? 10 : 9) * k, weight: .heavy))
                    .foregroundStyle(Color(hex: "#05070f") ?? .black))
                let textWidth = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width + 10 * k
                let boxX = max(x0 + 2, min(x0 + width - textWidth - 2, x - textWidth / 2))
                let box = CGRect(x: boxX, y: y0 + 2 * k, width: textWidth, height: 14 * k)
                layer.fill(Path(roundedRect: box, cornerRadius: 7 * k), with: .color(Color(hex: marker.color) ?? .white))
                layer.draw(text, at: CGPoint(x: box.midX, y: box.midY))
            }
        }

        var caret = Path()
        caret.move(to: CGPoint(x: centerX - 5 * k, y: y0 + height))
        caret.addLine(to: CGPoint(x: centerX + 5 * k, y: y0 + height))
        caret.addLine(to: CGPoint(x: centerX, y: y0 + height - 6 * k))
        caret.closeSubpath()
        context.fill(caret, with: .color(.white))
    }
}

/// The frame-space layer: detection boxes and the diamonds floating on pings
/// and the candidate. Positions are fractions of the upright frame the hub has,
/// mapped onto the aspect-filled preview.
struct HUDFrameLayerView: View {
    let hud: HubHUDMirror
    let captureSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let transform = ImageToViewTransform(capture: captureSize, view: geometry.size)
            let k = geometry.size.width / 390
            Canvas { context, size in
                for box in hud.dets ?? [] {
                    let rect = transform.rect(uprightFractionX: box.x, y: box.y, width: box.w, height: box.h)
                    context.stroke(Path(rect), with: .color(HUDStyle.detection), lineWidth: 3)
                    let label = [box.label, box.score.map { "\(Int(($0 * 100).rounded()))%" }]
                        .compactMap { $0 }.joined(separator: " ")
                    guard !label.isEmpty else { continue }
                    let text = context.resolve(Text(label).font(.system(size: 13 * k, weight: .bold))
                        .foregroundStyle(.white))
                    let width = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width + 10
                    let tag = CGRect(x: rect.minX, y: rect.minY - 20 * k, width: width, height: 20 * k)
                    context.fill(Path(tag), with: .color(HUDStyle.detection))
                    context.draw(text, at: CGPoint(x: tag.midX, y: tag.midY))
                }
                for marker in hud.ar {
                    let at = transform.rect(uprightFractionX: marker.x, y: marker.y, width: 0, height: 0).origin
                    let r = max(6, marker.r * size.height)
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: at.x, y: at.y - r))
                    diamond.addLine(to: CGPoint(x: at.x + r, y: at.y))
                    diamond.addLine(to: CGPoint(x: at.x, y: at.y + r))
                    diamond.addLine(to: CGPoint(x: at.x - r, y: at.y))
                    diamond.closeSubpath()
                    context.fill(diamond, with: .color(Color(hex: marker.color) ?? .yellow))
                    context.stroke(diamond, with: .color(.black.opacity(0.6)), lineWidth: 2)
                    HUDStyle.pill(&context, at: CGPoint(x: at.x, y: at.y - r - 13 * k), text: marker.label,
                                  background: .black.opacity(0.7), foreground: .white, size: 12 * k)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
