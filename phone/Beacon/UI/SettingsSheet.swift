import SwiftUI
import SwarmCore

/// The plain-Swift shell's settings drawer, opened by the gear in the camera
/// chrome. The Expo shell has its own at `mobile/src/screens/settings.tsx`; this
/// target had nothing, so an operator on this build could not recalibrate, could
/// not turn the mini-map off and could not leave without killing the app.
///
/// An ordinary `Form` in a `.sheet`, deliberately: it is the one surface in the
/// app that is *not* drawn over a camera, so it should look like Settings rather
/// than like the HUD. No `.cameraChrome()`, no invented colour.
///
/// It reads `model.frame.overlay` directly. That is a 30 Hz value, but this is a
/// modal with four rows on it, and Observation only invalidates on the fields
/// actually read.
struct SettingsSheet: View {
    let model: OperatorViewModel
    @Binding var showDebug: Bool
    @Binding var showMiniMap: Bool
    let onLeave: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var overlay: OverlayState { model.frame.overlay }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // The one action here that is not a preference, and the
                    // reason this drawer exists. It lived on the camera chrome
                    // as a bare ↻ for a while, where it read as "reload" — a
                    // control that throws the marker lock away should say so
                    // in words, and should take one more tap than a sweep.
                    Button {
                        model.resetOrigin()
                        dismiss()
                    } label: {
                        Label("Recalibrate", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Position")
                } footer: {
                }

                Section("Over the camera") {
                    Toggle("Marker outlines", systemImage: "viewfinder", isOn: $showDebug)
                    Toggle("Mini-map", systemImage: "map.fill", isOn: $showMiniMap)
                }

                Section("This phone") {
                    LabeledContent("Status", value: overlay.status.title)
                    LabeledContent("Located by", value: located)
                    if let index = overlay.index {
                        LabeledContent("Phone", value: "#\(index)")
                    }
                    if let phase = overlay.phase {
                        LabeledContent("Phase", value: phase)
                    }
                }

                Section {
                    Button(role: .destructive, action: onLeave) {
                        Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                            // `role: .destructive` reddens the title and leaves
                            // the SF Symbol on the accent colour, so the row
                            // reads half-destructive. `foregroundStyle` on the
                            // label colours glyph and text alike — the same fix
                            // the Expo settings screen carries.
                            .foregroundStyle(Color.ssProblem)
                    }
                } footer: {
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The operator's words for `RoomAligner.Source`, which is a wire value.
    private var located: String {
        switch overlay.alignment {
        case .marker: "A printed marker"
        case .seat: "The seat you tapped"
        case .none: "Not located yet"
        }
    }
}
