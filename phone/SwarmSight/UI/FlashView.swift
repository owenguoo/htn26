import SwiftUI
import SwarmCore

/// Full-screen colour. No inset, no corner radius: it exists to be visible
/// across a room at a glance. The hub may put a line or two of text on it
/// ("You're there ✓"), which is for the operator, not the room.
struct FlashView: View {
    let flash: FlashCue

    var body: some View {
        ZStack {
            Color(.sRGB, red: Double(flash.red), green: Double(flash.green),
                  blue: Double(flash.blue), opacity: 1)
                .ignoresSafeArea()
            if let text = flash.text {
                Text(text)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(luminance > 0.6 ? .black : .white)
                    .padding(24)
            }
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    private var luminance: Double {
        0.2126 * Double(flash.red) + 0.7152 * Double(flash.green) + 0.0722 * Double(flash.blue)
    }
}
