import SwiftUI
import SwarmCore

/// One plain sentence about the phone's health, and what to do about it.
///
/// This used to be `LOST  conf 1.00  fix 34s  air 1  drop 0`: six true facts and
/// no instruction. The wording and the choice of *which* problem to show live in
/// `OperatorStatus` in SwarmCore, where they are tested; the numbers moved to
/// Settings. When the fix is "get located", the whole thing is the button —
/// otherwise it is just a label, never a disabled control with a fake chevron.
struct OperatorStatusView: View {
    let status: OperatorStatus
    var onTap: (() -> Void)?

    var body: some View {
        Group {
            if status.offersSeatPicker, let onTap {
                Button(action: onTap) { content }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the map so you can tap where you are standing")
            } else {
                content
                    .accessibilityHint("")
            }
        }
        // Without this a ZStack proposes the full row width and the card fills
        // it, so a one-line title like "Reconnecting…" sits on the left even
        // though the stack is meant to centre it.
        .fixedSize(horizontal: status.hint == nil, vertical: true)
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
            if status.offersSeatPicker {
                Spacer(minLength: Space.xs)
                Image(systemName: "chevron.right")
                    .font(TypeScale.affordance)
                    .foregroundStyle(.hudInkTertiary)
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
        case .attention: status.offersSeatPicker ? "scope" : "exclamationmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        }
    }
}
