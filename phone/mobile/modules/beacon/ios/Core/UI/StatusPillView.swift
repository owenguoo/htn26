import SwiftUI
import SwarmCore

/// One plain sentence about the phone's health, and what to do about it.
///
/// This used to be `LOST  conf 1.00  fix 34s  air 1  drop 0`: six true facts and
/// no instruction. The wording and the choice of *which* problem to show live in
/// `OperatorStatus` in SwarmCore, where they are tested; the numbers moved to
/// Settings.
///
/// It is a label, not a control. It used to become a button when the problem
/// was "not located", because tapping it opened the seat picker; with that gone
/// there is nothing on this phone the operator fixes by tapping a status line.
/// They fix it by pointing the camera at a marker, which is what it says.
struct OperatorStatusView: View {
    let status: OperatorStatus

    var body: some View {
        content
            // Without this a ZStack proposes the full row width and the card
            // fills it, so a one-line title like "Reconnecting…" sits on the
            // left even though the stack is meant to centre it.
            .fixedSize(horizontal: status.hint == nil, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityLabel([status.title, status.hint].compactMap { $0 }.joined(separator: ". "))
    }

    private var content: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(TypeScale.inlineSymbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.title)
                    .font(TypeScale.statusTitle)
                    // Fixed light-on-dark: the backdrop is a camera frame,
                    // so the colour scheme says nothing about contrast here.
                    .foregroundStyle(.hudInk)
                if let hint = status.hint {
                    Text(hint)
                        .font(TypeScale.hint)
                        .foregroundStyle(.hudInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .frame(maxWidth: status.hint == nil ? nil : .infinity, alignment: .leading)
        .background(background, in: shape)
        .overlay(shape.stroke(tint.opacity(0.7), lineWidth: 1))
    }

    /// One line is a capsule; two lines is a card. A hand-picked 18 was only
    /// ever approximating the capsule, and never quite reached it as the text
    /// size grew.
    private var shape: AnyShape {
        status.hint == nil ? AnyShape(Capsule()) : AnyShape(Radius.rect(Radius.card))
    }

    private var tint: Color {
        switch status.level {
        case .ok: .ssOK
        case .attention: .ssAttention
        case .problem: .ssProblem
        }
    }

    private var background: some ShapeStyle {
        status.level == .ok ? AnyShapeStyle(Surface.hudChrome) : AnyShapeStyle(tint.opacity(0.28))
    }

    private var symbol: String {
        switch status.level {
        case .ok: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        }
    }
}
