import SwiftUI
import SwarmCore

/// One plain sentence about the phone's health, and what to do about it.
///
/// This used to be `LOST  conf 1.00  fix 34s  air 1  drop 0`: six true facts and
/// no instruction. The wording and the choice of *which* problem to show live in
/// `OperatorStatus` in SwarmCore, where they are tested; the numbers moved to
/// Settings. When the fix is "get located", the whole thing is the button.
struct OperatorStatusView: View {
    let status: OperatorStatus
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.bold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    if let hint = status.hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if status.offersSeatPicker {
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, status.hint == nil ? 7 : 9)
            .frame(maxWidth: status.hint == nil ? nil : .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: status.hint == nil ? 18 : 14))
            .overlay(RoundedRectangle(cornerRadius: status.hint == nil ? 18 : 14).stroke(tint.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!status.offersSeatPicker)
        .accessibilityLabel([status.title, status.hint].compactMap { $0 }.joined(separator: ". "))
    }

    private var tint: Color {
        switch status.level {
        case .ok: .green
        case .attention: .orange
        case .problem: .red
        }
    }

    private var background: some ShapeStyle {
        status.level == .ok ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(tint.opacity(0.28))
    }

    private var symbol: String {
        switch status.level {
        case .ok: "checkmark.circle.fill"
        case .attention: status.offersSeatPicker ? "scope" : "exclamationmark.circle.fill"
        case .problem: "exclamationmark.triangle.fill"
        }
    }
}
