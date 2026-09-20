import SwiftUI
import SwarmCore

/// Who this operator is being sent to, and how far it is.
///
/// The banner at the top of the screen already says what to do *this instant* —
/// "Turn right 40°" — and rewrites itself on every tick. That is an
/// instruction, and instructions are useless for the question an operator
/// actually keeps asking on a long walk across a room: *who am I going to, and
/// am I getting closer.* So this sits still, in one corner, and answers that.
///
/// Bottom-trailing, opposite the mini-map, which is the layout the reference
/// HUDs converge on: the map in one bottom corner, the thing you are tasked
/// with in the other. It shares that row with the mini-map, which the operator
/// can drag on top of it — their drag, their problem.
///
/// The wording, the rounding and the tone all come from `HubHUDMirror.Objective`
/// in SwarmCore, where they are tested and where the console reads the same
/// values, so this file only decides what it looks like.
struct ObjectiveCardView: View {
    let objective: HubHUDMirror.Objective

    var body: some View {
        HStack(spacing: Space.s) {
            // A plain arrow, turned to the bearing. It was `location.north`,
            // which draws a horizontal rule across the top of the head — that
            // glyph means "north on a map", not "that way", and it pointed the
            // same direction whatever the operator did. This one points.
            Image(systemName: "arrow.up")
                .font(TypeScale.inlineSymbol)
                .foregroundStyle(tint)
                .rotationEffect(.degrees(objective.bearing))
                .animation(.easeOut(duration: 0.15), value: objective.bearing)
            VStack(alignment: .leading, spacing: 1) {
                Text(objective.title)
                    .font(TypeScale.statusTitle)
                    // Fixed light-on-dark: the backdrop is a camera frame, so
                    // the colour scheme says nothing about contrast here.
                    .foregroundStyle(.hudInk)
                Text(objective.detail)
                    // Monospaced digits: the distance counts down while the
                    // operator walks, and proportional figures make the whole
                    // line twitch on every metre.
                    .font(TypeScale.readout)
                    .foregroundStyle(.hudInkSecondary)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .fixedSize(horizontal: false, vertical: true)
        .background(background, in: Radius.rect(Radius.card))
        .overlay(Radius.rect(Radius.card).stroke(tint.opacity(0.7), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(objective.title). \(objective.detail)")
    }

    /// The console's three pill colours, by the name the mirror sent.
    private var tint: Color {
        switch objective.tone {
        case "alert": .ssProblem
        case "ok": .ssOK
        default: .ssAttention
        }
    }

    private var background: some ShapeStyle {
        objective.tone == "alert" ? AnyShapeStyle(Color.ssProblem.opacity(0.28))
                                  : AnyShapeStyle(Surface.hudChrome)
    }
}
