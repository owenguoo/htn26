import SwiftUI
import SwarmCore

/// Full-screen colour. No inset, no corner radius, no label: it exists to be
/// visible across a room at a glance.
struct FlashView: View {
    let flash: FlashCue

    var body: some View {
        Color(.sRGB, red: Double(flash.red), green: Double(flash.green),
              blue: Double(flash.blue), opacity: 1)
            .ignoresSafeArea()
            .transition(.opacity)
    }
}
