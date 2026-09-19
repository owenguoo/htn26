import ExpoModulesCore
import SwarmCore

/// The whole JS-facing surface. Deliberately tiny: JS asks to join, leave, and
/// how things are going at a human rate. Frames, poses and the socket never
/// cross this boundary — they live in SwarmCore, behind `SwarmRuntime`.
/// `Module` is not `Sendable`, and the event pumps run in tasks. This is the one
/// thing they need from it. `sendEvent` is safe from any thread; the reference
/// is weak so a pump outliving its module sends into nothing.
private final class EventSink: @unchecked Sendable {
  private let lock = NSLock()
  private weak var module: Module?

  func attach(_ module: Module) {
    lock.withLock { self.module = module }
  }

  func send(_ name: String, _ body: [String: Any]) {
    lock.withLock { module }?.sendEvent(name, body)
  }
}

public class BeaconModule: Module {
  private let events = EventSink()
  private var binder: SessionBinder?
  private var observer: UUID?

  public func definition() -> ModuleDefinition {
    Name("Beacon")

    Events("onState", "onWelcome", "onPhase", "onError")

    OnCreate {
      self.events.attach(self)
      // The pumps are owned by the sink's lifetime, not the module's isolation:
      // `bind` only touches the two task handles, from wherever the runtime
      // publishes a session.
      let binder = SessionBinder(events: self.events)
      self.binder = binder
      self.observer = SwarmRuntime.shared.observe { session in binder.bind(session) }

      // Before the first frame, so the app never flashes dark while the root
      // window is still coming up. The module is created before that window
      // exists, hence the observer as well as the immediate apply.
      Task { @MainActor in
        ThemeController.applyLight()
        ThemeController.followNewWindows()
      }
    }

    OnDestroy {
      if let observer = self.observer { SwarmRuntime.shared.removeObserver(observer) }
      self.binder?.bind(nil)
    }

    /// `poseSource`: "arkit" | "replay". Replay is a recorded walk plus a
    /// synthetic JPEG: the whole client minus ARKit, which is what the
    /// Simulator can run.
    Function("configure") { (options: [String: Any]) in
      var next = SwarmRuntime.shared.currentOptions
      if let source = (options["poseSource"] as? String).flatMap(PoseSourceKind.init(rawValue:)) {
        next.poseSource = source
      }
      if let fixture = options["fixture"] as? String { next.fixture = fixture }
      if let rate = options["replayRate"] as? Double, rate > 0 { next.replayRate = rate }
      if let markers = options["replayMarkers"] as? Bool { next.replayMarkers = markers }
      SwarmRuntime.shared.configure(next)
    }

    /// UserDefaults-backed. JS stores nothing.
    Function("getConfig") { () -> [String: Any] in
      [
        "phoneId": PhoneIdentity.phoneId,
        "name": PhoneIdentity.name,
        "lastHubURL": PhoneIdentity.lastHubURL,
        "venueHubURL": (try? ModuleResources.loadVenue())?.hubURL ?? "",
        "poseSource": SwarmRuntime.shared.currentOptions.poseSource.rawValue,
        // `simctl launch … -BeaconJoin <link>`: iOS puts a confirmation in
        // front of `simctl openurl` that nothing headless can tap.
        "launchJoin": UserDefaults.standard.string(forKey: "BeaconJoin") ?? "",
      ]
    }

    /// QR / typed text / deep link → the hub's phone socket, or null.
    Function("resolveHubURL") { (scanned: String) -> String? in
      HubURL.derive(scanned)?.absoluteString
    }

    let events = self.events
    AsyncFunction("join") { (hubURL: String, name: String) async throws in
      do {
        try await SwarmRuntime.shared.join(hub: hubURL, name: name)
      } catch {
        events.send("onError", ["message": error.localizedDescription])
        throw error
      }
    }

    AsyncFunction("leave") { () async in
      await SwarmRuntime.shared.leave()
    }

    AsyncFunction("setName") { (name: String) async in
      PhoneIdentity.name = name
      await SwarmRuntime.shared.session?.client.setName(name)
    }

    AsyncFunction("setSeat") { (x: Double, y: Double) async in
      await SwarmRuntime.shared.session?.client.setSeat(x: x, y: y)
    }

    AsyncFunction("calibrateFacingStage") { () async -> Bool in
      await SwarmRuntime.shared.session?.client.calibrateFacingStage() ?? false
    }

    AsyncFunction("resetOrigin") { () async in
      await SwarmRuntime.shared.session?.client.resetOrigin()
    }

    /// The mic control, and the only thing JS may do to voice. Returns the new
    /// state so a toggle can settle immediately instead of waiting for the next
    /// `onState`.
    ///
    /// **No audio buffer ever crosses this boundary** — same rule as frames,
    /// poses and the socket. JS gets a bool in and a string out; the samples go
    /// from `MicrophoneCapture`'s tap straight into `SwarmClient`.
    ///
    /// Goes through the capture when there is one, because muting has to stop
    /// the input running as well as tell the gate. With no live tap (replay,
    /// drive, or the operator declined the microphone) the control stays
    /// unavailable — do not let the gate alone look like a working mic.
    AsyncFunction("setMicrophoneMuted") { (muted: Bool) async -> String in
      if let state = await MicrophoneCapture.setMuted(muted) { return state.rawValue }
      return MicrophoneState.unavailable.rawValue
    }

    AsyncFunction("getDiagnostics") { () async -> [String: Any] in
      guard let client = SwarmRuntime.shared.session?.client else { return ["joined": false] }
      return Self.payload(await client.snapshot())
    }

    View(OperatorExpoView.self) {
      Events("onRequestSettings")

      Prop("showDebug") { (view: OperatorExpoView, value: Bool) in
        view.showDebug = value
      }

      Prop("showMiniMap") { (view: OperatorExpoView, value: Bool) in
        view.showMiniMap = value
      }
    }
  }

  static func payload(_ s: ClientSnapshot) -> [String: Any] {
    var out: [String: Any] = [
      "joined": true,
      "connection": s.connection.rawValue,
      "sessionState": s.sessionState.rawValue,
      "trackingState": s.trackingState,
      "confidence": s.confidence,
      "alignment": s.alignment.rawValue,
      "phoneId": s.phoneId,
      "name": s.name,
      "frameFPS": s.frameFPS,
      "framesSent": s.framesSent,
      "dropped": s.dropped,
      "reconnects": s.reconnects,
      "thermal": s.thermal.rawValue,
      // "unavailable" | "muted" | "idle" | "speaking". The client knows whether
      // voice is configured and whether the gate is open; only the capture
      // knows whether the operator ever granted the microphone, so a declined
      // prompt is folded in here rather than being reported as a quiet mic.
      "micState": MicrophoneCapture.availability == .running
        ? s.micState.rawValue : MicrophoneState.unavailable.rawValue,
    ]
    // Absent rather than null: a missing key is `undefined` in JS, and every
    // one of these is optional in the TypeScript type.
    if let index = s.index { out["index"] = index }
    if let color = s.colorHex { out["color"] = color }
    if let phase = s.phase { out["phase"] = phase }
    if let latency = s.latencyP50Ms { out["latencyP50Ms"] = latency }
    if let command = s.lastCommand { out["lastCommand"] = command }
    if let error = s.lastError { out["lastError"] = error }
    if let room = s.roomPose {
      var pose: [String: Any] = ["x": room.x, "y": room.y, "pitch": room.pitch]
      if let heading = room.heading { pose["heading"] = heading }
      out["roomPose"] = pose
    }
    if let seat = s.seat { out["seat"] = ["x": seat.x, "y": seat.y] }
    return out
  }
}

/// Starts and stops the low-rate event pumps for a session. `onState` is capped
/// at 2 Hz: it exists to drive a settings screen, not a render loop.
private final class SessionBinder: @unchecked Sendable {
  private let events: EventSink
  private let lock = NSLock()
  private var tasks: [Task<Void, Never>] = []

  init(events: EventSink) {
    self.events = events
  }

  func bind(_ session: RuntimeSession?) {
    let events = self.events
    var next: [Task<Void, Never>] = []
    if let client = session?.client {
      next.append(Task {
        var lastPhase: String?
        while !Task.isCancelled {
          let snapshot = await client.snapshot()
          events.send("onState", BeaconModule.payload(snapshot))
          if snapshot.phase != lastPhase, let phase = snapshot.phase {
            lastPhase = phase
            events.send("onPhase", ["phase": phase])
          }
          try? await Task.sleep(nanoseconds: 500_000_000)
        }
      })
      next.append(Task {
        for await welcome in await client.welcomes() {
          events.send("onWelcome", [
            "phoneId": welcome.phoneId, "index": welcome.index, "color": welcome.color,
            "phase": welcome.phase ?? "",
          ])
        }
      })
    } else {
      events.send("onState", ["joined": false])
    }
    let old = lock.withLock { () -> [Task<Void, Never>] in
      defer { tasks = next }
      return tasks
    }
    for task in old { task.cancel() }
  }
}
