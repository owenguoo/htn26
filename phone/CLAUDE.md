# SwarmSight iOS Client

## What this is

Hackathon iOS app. 3–5 teammate phones become tracked cameras in a room. Each
phone reports its 6DoF pose plus periodic JPEG frames to a central orchestrator
over WebSocket, and displays commands sent back (full-screen color flash,
directional arrow, sound, haptic). The operators walk around and sweep their
cameras; they are not seated.

**A working web prototype already exists.** The orchestrator, dashboard, feed
wall, cone rendering and QR join flow are built and running. This iOS app is a
drop-in replacement for the *pose source* and *frame source* only. Do not
rewrite, redesign or "improve" the server or the dashboard. If the wire protocol
here disagrees with the server, the server wins — ask, don't refactor.

## Non-negotiable architecture

- All logic lives in `Packages/SwarmCore`. It must not import ARKit, UIKit,
  SwiftUI, CoreMotion or CoreHaptics. It must build and test with `swift test`
  on macOS with no simulator and no device.
- ARKit appears in exactly one file: `ARKitPoseProvider.swift` in the app
  target. It conforms to `PoseProvider` and does nothing but adapt.
- If you want ARKit inside SwarmCore, the abstraction is wrong. Widen the
  protocol instead.
- No third-party dependencies. Swift 6, strict concurrency. Actors for the
  session and the transport. No force unwraps outside tests.

## Verification

**You cannot run ARKit. It does not exist in the iOS Simulator.** Do not write
code you cannot test, and never claim positioning "works."

Your only valid evidence is:

```
cd phone/Packages/SwarmCore && swift test
xcodebuild -project phone/SwarmSight.xcodeproj -scheme SwarmSight -destination 'platform=iOS Simulator,name=iPhone 16' build
```

(Paths are from the htn26 repo root; this client lives under `phone/`.)

Tests run against `MockPoseProvider` replaying `Fixtures/trajectory-*.json`,
which contains real recorded ARKit output. Anything ARKit-dependent goes in a
file with a `// DEVICE-VERIFY:` comment stating exactly what a human must check
on hardware, and gets appended to `DEVICE_CHECKLIST.md`.

Commit after every passing gate. An unattended run that dies mid-gate should be
resumable from the last green commit.

## Coordinate conventions — do not deviate

- ARKit camera looks down −Z, +Y up, right-handed.
- Venue frame: +X east along the stage, +Y up, +Z out from the stage. Origin on
  the floor below the center of the primary marker.
- Configuration is `worldAlignment = .gravity`. Never `.gravityAndHeading` —
  that pulls in the magnetometer, which is off by tens of degrees indoors.
  Gravity fixes pitch and roll; the marker fixes yaw.
- Wire poses are already in venue frame: position `[x,y,z]` in metres plus
  quaternion `[x,y,z,w]`. The phone converts; the server never should.
- Every pose carries: server-clock timestamp, `trackingState`, `confidence`,
  `lastCorrectionAge`, and which marker last corrected it.

## Markers

`ARReferenceImage` + `ARImageAnchor` are the shared-origin mechanism. On first
sighting, call `session.setWorldOrigin(relativeTransform:)` so every subsequent
ARKit pose is already venue-frame.

Marker sightings are **continuing pose corrections, not just initial
calibration**. Operators walk, so ARKit drift accumulates; every re-sighting is
a fix. Handle `didAdd` and `didUpdate` for `ARImageAnchor` as first-class
events, and reject any correction that disagrees with the current estimate by
more than the configured threshold.

`physicalWidth` must be the true measured width in metres or all scale is wrong.

## Depth

`DepthSource` protocol, two implementations:

- `LiDARDepthSource` — ARKit `frameSemantics = .sceneDepth`, Pro devices only.
- `ServerDepthSource` — frames uploaded, VGGT-Ω depth returned from the server.

Both return metric depth in the venue frame. **VGGT-Ω depth is
scene-normalized, not metres.** `ServerDepthSource` must apply a scale factor
fitted from the known metric ARKit baselines between the frames in the chunk.
Test that scale-fitting math against synthetic data with a known ground-truth
scale.

Do not branch UI or session logic on device class. Branch only at
`DepthSource`.

## Tracking state and recovery

State machine: `idle → permissions → calibrating → tracking → degraded → lost →
recalibrating`.

- `.limited(.relocalizing)`, `.limited(.insufficientFeatures)`,
  `.notAvailable`, `sessionWasInterrupted` and `sessionInterruptionEnded` all
  drive transitions. Confidence decays while tracking is degraded.
- Poses older than 5 s are flagged stale so the dashboard can grey the cone
  rather than draw it confidently in the wrong place.
- `CMDeviceMotion` is a *fallback signal only* — "did this person move while
  tracking was lost." Never integrate step counts into a position estimate.
  Pedestrian dead reckoning heading error compounds; 20° over 10 m is ~3.4 m
  lateral and never recovers.

## Latency budget — hard target, end to end under 300 ms

The web prototype measures ~1000 ms median. That is fatal for the "look left"
directive: people turn, see nothing, and read it as broken.

```
capture→encode  30ms
encode→send     20ms
network         30ms
server queue    50ms
inference      100ms
paint           30ms
```

Emit a timestamped stage trace on every frame. A regression past budget fails
the gate. **Backpressure drops, never queues** — if more than N frames are in
flight, discard the next one and increment a counter. A queue that grows is a
phone reporting where it was thirty seconds ago.

## Known ARKit traps

- Never retain an `ARFrame` beyond the delegate callback; it stalls the session.
  Copy out what you need and release.
- Reuse a single `CIContext`. Allocating one per frame drops you to ~3 fps.
- `frame.capturedImage` is `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`.
  Convert and downscale on a serial background queue with drop-if-busy.
- `frame.timestamp` is in the `CACurrentMediaTime()` domain — per-device
  uptime. Useless across phones without clock sync. Gate 2 exists for this.
- `session(_:didUpdate:)` fires at 60 Hz. Throttle: pose at ~10 Hz, JPEG at
  1–2 fps, depth chunks at 0.2–0.5 Hz.
- Set `UIApplication.shared.isIdleTimerDisabled = true`.
- Watch `ProcessInfo.processInfo.thermalState` and shed frame rate at
  `.serious`. ARKit plus streaming for 30 minutes will cook a phone.
- ARSession pauses on backgrounding. Detect and re-enter `recalibrating`.

## Info.plist — silent failures if missing

`NSCameraUsageDescription`, `NSLocalNetworkUsageDescription` plus
`NSBonjourServices` (iOS local-network permission bites everyone when the
orchestrator is on the LAN), `NSMotionUsageDescription`.

## Privacy

Search targets are objects, or a specific consenting person enrolled from a
reference photo and matched by appearance embedding. **No facial
identification.** Frames are discarded after inference. This is a stated
commitment in the pitch — do not add a face-recognition path.
