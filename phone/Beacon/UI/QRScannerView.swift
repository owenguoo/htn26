import AVFoundation
import SwiftUI
import SwarmCore

/// Point the phone at the console's Join QR and it fills the hub address in.
///
/// The console has had a **Join QR** button since the beginning and the phone
/// had no way to read it — the operator typed `http://10.0.0.5:8000/` on a
/// phone keyboard, in a dark room, with the search waiting on them. A QR code
/// on a laptop screen two feet away is the fastest, least error-prone hub
/// address there is.
///
/// `AVCaptureMetadataOutput` rather than VisionKit's `DataScannerViewController`:
/// this has to work on every phone that can run the app, and the scanner
/// requires the Neural Engine. Reading one symbology out of a preview is a
/// small enough job that the older API costs nothing.
///
/// DEVICE-VERIFY: the Simulator has no camera, so nothing here can be exercised
/// off a device. On hardware, confirm the console's Join QR fills the field and
/// dismisses on the first read, that a QR code which is not a hub address is
/// ignored rather than accepted, and that declining the camera permission shows
/// the explanation instead of a black rectangle.
/// DEVICE_CHECKLIST.md item 14.
struct QRScannerView: View {
    /// Called with the scanned string once, for a code that parses as a hub.
    let onFound: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var denied = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if denied {
                    ContentUnavailableView("No camera access",
                                           systemImage: "video.slash",
                                           description: Text("Allow the camera in Settings, or type the address instead."))
                        .foregroundStyle(.white)
                } else {
                    CodeCaptureView(onFound: found, onDenied: { denied = true })
                        .ignoresSafeArea()
                    // A frame to aim with. The capture reads the whole image —
                    // this only tells a person where to point.
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.9), lineWidth: 3)
                        .frame(width: 240, height: 240)
                        .shadow(radius: 12)
                    VStack {
                        Spacer()
                        Text("Point at the console's Join QR")
                            .font(TypeScale.detail)
                            .foregroundStyle(.white)
                            .padding(.bottom, Space.xxl)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    /// Only a code that is actually a hub address counts. A poster, a ticket or
    /// a Wi-Fi QR in the same room should not silently replace the field the
    /// operator is about to join with.
    private func found(_ text: String) {
        guard HubURL.derive(text) != nil else { return }
        onFound(text)
        dismiss()
    }
}

/// The capture session itself, with no opinions about how it looks.
private struct CodeCaptureView: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    let onDenied: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> CaptureController {
        CaptureController(coordinator: context.coordinator, onDenied: onDenied)
    }

    func updateUIViewController(_ controller: CaptureController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onFound: (String) -> Void
        /// One code, once. The output fires every frame the code is in view.
        private var handled = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !handled,
                  let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
                  let text = code.stringValue else { return }
            handled = true
            onFound(text)
        }
    }

    /// `AVCaptureSession` is not `Sendable`, and `startRunning()` blocks until
    /// the first frame arrives — so it must not be called on the main thread,
    /// and it cannot simply be captured out of a `@MainActor` view controller
    /// into a task either. That is the data race the compiler refuses, and it
    /// is right to.
    ///
    /// This box is the escape hatch, and it is narrow on purpose: the only two
    /// things it ever does away from the main actor are start and stop, both on
    /// one serial queue, so they cannot overlap each other. Everything else —
    /// adding the input and output, building the preview layer — happens on
    /// main before anything is running, and the metadata delegate is delivered
    /// back on main. That discipline is what makes the unchecked conformance
    /// true rather than merely asserted.
    final class SessionRunner: @unchecked Sendable {
        let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "sh.beacon.qr-session")

        func start() {
            queue.async { [self] in
                guard !session.isRunning else { return }
                session.startRunning()
            }
        }

        func stop() {
            queue.async { [self] in
                guard session.isRunning else { return }
                session.stopRunning()
            }
        }
    }

    final class CaptureController: UIViewController {
        private let runner = SessionRunner()
        private var session: AVCaptureSession { runner.session }
        private let coordinator: Coordinator
        private let onDenied: () -> Void
        private var preview: AVCaptureVideoPreviewLayer?

        init(coordinator: Coordinator, onDenied: @escaping () -> Void) {
            self.coordinator = coordinator
            self.onDenied = onDenied
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                start()
            case .notDetermined:
                // The async form, not the completion handler: the handler is
                // `@Sendable` and this controller is not, so capturing it there
                // is the same complaint in a different place.
                Task { @MainActor [weak self] in
                    let granted = await AVCaptureDevice.requestAccess(for: .video)
                    guard let self else { return }
                    if granted { start() } else { onDenied() }
                }
            default:
                onDenied()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Off the main thread: stopping a running session blocks until the
            // last buffer is delivered, and doing that during a dismiss
            // animation stutters the dismissal.
            runner.stop()
        }

        private func start() {
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else { return onDenied() }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return onDenied() }
            session.addOutput(output)
            // Set *after* adding to the session; the available types are empty
            // until then, and assigning an unavailable type traps.
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer

            runner.start()
        }
    }
}
