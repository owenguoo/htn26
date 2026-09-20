import SwiftUI
import SwarmCore

/// The whole phone, for a second or two, at the moments worth taking it for.
///
/// **A takeover is a frame and a plate, never a fill.** The colour is a plate
/// with a hole cut in it — an even-odd fill, so the window is genuinely
/// transparent and the live camera and its detection boxes carry on underneath
/// exactly where they already were. Nothing is re-projected into the window and
/// no second preview is started; the searcher is looking at the same frame they
/// were looking at a moment ago, through a smaller opening.
///
/// That is the whole reason this is not simply a coloured screen. The person
/// reading it is standing in a crowd, and a screen that blinds them for two
/// seconds is a screen they have to lower to stay safe.
///
/// It is also why the card is measured in seconds. The window is a crop, and a
/// crop is only survivable while somebody is standing still reading it. What
/// the card leaves behind is `HUDAmbientView` — the same colour, at the bezel
/// only, camera back at full frame — held for as long as the situation lasts.
///
/// Every value on screen comes from `HUDMirror.takeover(kind:name:)`: one table
/// in SwarmCore, one row per card, so the phone and the operator console show
/// the same card rather than two that resemble each other.
struct TakeoverView: View {
    let takeover: HubHUDMirror.Takeover
    /// Where to point, for the `arrow` window. Degrees right of facing.
    let bearingDegrees: Double?
    /// The label under the arrow, e.g. "SAM · 12 m".
    let chip: String?

    /// The plate arrives at full size and contracts away, which is what makes
    /// it read as *becoming* the badge rather than blinking out.
    @State private var shown = false
    private var isHazard: Bool { takeover.kind == "hazard" }

    var body: some View {
        GeometryReader { geometry in
            let window = windowRect(in: geometry.size)
            ZStack {
                PlateWithWindow(window: window, radius: Radius.plate)
                    .fill(color, style: FillStyle(eoFill: true))
                Radius.rect(Radius.plate)
                    .stroke(.white.opacity(0.35), lineWidth: 1)
                    .frame(width: window.width, height: window.height)
                    .position(x: window.midX, y: window.midY)
                if takeover.window == "arrow" { arrow(in: window) }
                header(above: window, width: geometry.size.width)
                footer(below: window, in: geometry.size)
            }
        }
        .ignoresSafeArea()
        .scaleEffect(shown ? 1 : 0.94, anchor: .center)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { shown = true } }
        .onDisappear { shown = false }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([takeover.title, takeover.detail, takeover.footer]
            .compactMap { $0 }.joined(separator: ". "))
    }

    /// The hole, in the proportions the card's own row asked for. A hazard card
    /// keeps nearly the whole screen as camera; a person card can afford to
    /// crop, because it is about somebody who is not in front of the lens yet.
    private func windowRect(in size: CGSize) -> CGRect {
        let x = size.width * takeover.insetX
        let y = size.height * takeover.top
        return CGRect(x: x, y: y, width: size.width - x * 2,
                      height: size.height * (takeover.bottom - takeover.top))
    }

    /// Glyph, name and instruction, in the plate above the window.
    private func header(above window: CGRect, width: CGFloat) -> some View {
        VStack(spacing: Space.s) {
            Image(systemName: takeover.symbol)
                .font(.system(size: 28, weight: .medium))
            Text(takeover.title)
                // The hazard card runs smaller because it gave its space to the
                // window, which is the point of that card.
                .font(TypeScale.alert(isHazard ? 28 : 34))
                .minimumScaleFactor(0.6)
            if let detail = takeover.detail {
                Text(detail)
                    .font(.system(size: 17, weight: .semibold))
                    .opacity(0.94)
            }
            // The other thing that is also true, in its own colour. An obstacle
            // card carries the person you were running to; a person card
            // carries the obstacle. Whichever lost the plate did not lose the
            // screen.
            if let badge = takeover.badge {
                Text(badge.text)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.hudInk)
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.xs)
                    .background(Color(hex: badge.color) ?? .red, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
            }
        }
        // Plate ink is white on both plate colours by construction — they are
        // the console's own dark green and dark red, picked for exactly this.
        .foregroundStyle(.hudInk)
        .multilineTextAlignment(.center)
        .frame(width: width - Space.xl * 2)
        .position(x: width / 2, y: window.minY / 2)
    }

    private func footer(below window: CGRect, in size: CGSize) -> some View {
        Group {
            if let footer = takeover.footer {
                Text(footer)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.hudInk)
                    .opacity(0.94)
                    .position(x: size.width / 2, y: (window.maxY + size.height) / 2)
            }
        }
    }

    /// A single big chevron in the window, turned to where the person is, with
    /// their name and range under it. The same arrow the compass tape is
    /// carrying, at the size somebody glances at once and then walks.
    private func arrow(in window: CGRect) -> some View {
        let centre = CGPoint(x: window.midX, y: window.midY - window.height * 0.06)
        return ZStack {
            Chevron()
                .fill(.white)
                .frame(width: 64, height: 72)
                .rotationEffect(.degrees(bearingDegrees ?? 0))
                .position(centre)
            if let chip {
                Text(chip)
                    .font(TypeScale.readout)
                    .foregroundStyle(.hudInk)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
                    .background(.hudVoid.opacity(0.75), in: Capsule())
                    .position(x: window.midX, y: centre.y + 78)
            }
        }
    }

    private var color: Color { Color(hex: takeover.color) ?? .red }
}

/// The plate: the whole card, minus the window. Filled even-odd, so the window
/// is a genuine hole and whatever is behind this view shows through it.
private struct PlateWithWindow: Shape {
    let window: CGRect
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addPath(Path(roundedRect: window, cornerRadius: radius))
        return path
    }
}

/// A navigation chevron, point up, in its own unit box.
private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
