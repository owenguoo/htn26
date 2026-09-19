Beacon iOS — Build Plan

Read CLAUDE.md first. It contains the constraints. This file contains the sequence.

Why this shape

ARKit does not run in the iOS Simulator, so an unattended agent cannot execute a single line of positioning code. The repo is therefore split so that ~95% of the work lives in a pure-Swift package the agent can build and test in seconds, behind a protocol that the real ARKit session plugs into by hand in the morning.

Beacon/
├── Packages/SwarmCore/              # pure Swift. no ARKit, no UIKit.
│   ├── Sources/SwarmCore/
│   │   ├── PoseProvider.swift       # protocol: THE ARKit seam
│   │   ├── DepthSource.swift        # protocol: LiDAR vs server depth
│   │   ├── Geometry.swift           # simd transforms, quats, venue frame
│   │   ├── Calibration.swift        # marker → world origin, corrections
│   │   ├── DepthScaleFit.swift      # VGGT-Ω normalized depth → metres
│   │   ├── Wire.swift               # Codable message types
│   │   ├── ClockSync.swift          # RTT offset estimation
│   │   ├── Transport.swift          # WebSocket, reconnect, backpressure
│   │   ├── LatencyTrace.swift       # per-frame stage timing
│   │   └── SessionMachine.swift     # state machine, throttling, staleness
│   └── Tests/SwarmCoreTests/
├── Beacon.xcodeproj             # thin app target
│   ├── ARKitPoseProvider.swift      # ONLY file that imports ARKit
│   ├── LiDARDepthSource.swift
│   ├── FrameEncoder.swift           # CVPixelBuffer → JPEG
│   └── UI/                          # SwiftUI overlay
├── Fixtures/trajectory-*.json       # recorded real ARKit poses
├── (tools/mock-orchestrator/ retired: the real hub lives at ../swarm, see Scripts/e2e-hub.sh)
└── DEVICE_CHECKLIST.md              # written by the agent, run by a human
Gate 1 — Wire protocol and transport

Message types in Wire.swift: Hello, PoseUpdate, FrameChunk, DepthChunk, Command, Ping, Pong. Round-trip Codable tests for each.

Transport actor over URLSessionWebSocketTask with exponential-backoff reconnect and in-flight accounting.

Must test: backpressure drops. Simulate a socket that accepts 1 msg/sec while the producer emits 10/sec; assert the in-flight count stays bounded, the drop counter rises, and delivered messages are the newest, not the oldest. Assert reconnect resumes without duplicating or replaying stale frames.

Match the existing web prototype's protocol. If it differs, conform to it.

Gate 2 — Clock sync

frame.timestamp is per-device uptime. Without sync, cross-phone pose fusion on the server is meaningless.

Ping/pong RTT, minimum-RTT offset estimate, rolling window.

Must test: two simulated clocks with 4 s skew and 80 ms jitter converge to within 20 ms. Assert behaviour under asymmetric latency and under a step change (device sleeps and wakes).

Gate 3 — Calibration and corrections

Given a marker's known venue-frame pose and an observed ARImageAnchor transform, compute the relativeTransform for setWorldOrigin.

Must test: synthetic transforms with known answers; multi-marker averaging; rejection of an observation disagreeing beyond threshold; that a correction applied mid-trajectory reduces accumulated error in the replayed fixture rather than causing a visible jump larger than the configured limit.

Gate 4 — Session state machine (highest value — operators walk)

Drive entirely from MockPoseProvider replaying the fixture with injected .limited(.relocalizing), .limited(.insufficientFeatures), .notAvailable, interruption and resume events.

Must test: confidence decays correctly while degraded; re-lock on next marker sighting; lastCorrectionAge and staleness flagging; throttle rates hold (pose ~10 Hz, frames 1–2 fps, depth 0.2–0.5 Hz) regardless of the 60 Hz input; no unbounded memory growth over a 30-minute replay.

Gate 5 — Depth scale fitting

DepthScaleFit takes VGGT-Ω scene-normalized depth for a 4–8 frame chunk plus the known metric ARKit poses for those frames, and recovers the scale factor.

Must test: synthetic depth maps scaled by a known factor, recovered to within 2%. Robustness to 20% outlier depths. Graceful failure (returns nil, does not guess) when the camera baseline within the chunk is near zero — a stationary phone gives no parallax and no scale.

Gate 6 — Frame encoding

CVPixelBuffer (YCbCr biplanar) → JPEG on a serial background queue, drop-if-busy, reused CIContext. 3–5 phones means you can afford better than 640px; make resolution a config value and measure.

This one is partly device-only. Test what is testable (the queue policy, the drop accounting, config plumbing) and write the rest into DEVICE_CHECKLIST.md.

Gate 7 — Latency instrumentation

LatencyTrace stamps each stage per frame. Emit to the server alongside the frame. Assert in tests that the trace is complete and monotonic, and add a failing test if any stage exceeds the CLAUDE.md budget in a replay.

Gate 8 — UI shell

SwiftUI overlay: full-screen color flash, directional arrow driven by venue-frame target bearing, status pill showing tracking state, connection, in-flight count, drop count, thermal state, seconds-since-correction. CoreHaptics sharp transient on command — the thing the web client could never do.

Gate 9 — DEVICE_CHECKLIST.md

Everything the agent could not verify, as a numbered list a human executes in under twenty minutes. Marker detection range and angle. Re-lock time after walking out and back. Drift over a 5-minute walk. Thermal behaviour at 10, 20, 30 minutes. Local-network permission prompt. Backgrounding and resume. Measured end-to-end latency against the budget.

Human tasks — in this order

Tonight, before the agent runs:

Request VGGT-Ω checkpoint access. Done. Weights are in the repo. Do not commit a 4.6 GB .pt to git — see "Weights storage" below.
Record the trajectory fixture. Twenty-line throwaway app: start an ARSession, append frame.camera.transform, .intrinsics, .trackingState and frame.timestamp to an array, walk around for two minutes, dump to JSON. Any room works — this is not venue-dependent. Real ARKit motion has drift, dropouts and jitter the agent cannot invent correctly. Without this file the overnight run tests fiction.
Stub the orchestrator at tools/mock-orchestrator/ if the real one can't be pointed at localhost, so integration tests hit something real.
Enable Developer Mode on every phone (Settings → Privacy & Security; needs a restart).

Markers — required either way:

Print markers: matte, high contrast, non-repetitive, no glossy stock. Measure each one with a tape after printing — printers scale. Do not rely on the stage screen alone; glare, brightness and slide changes all break it.
Venue access: assume we don't have it

Positioning does not depend on venue access. One primary marker defines the origin; ARKit tracking is metric, so phone positions, target pins and the floor plan grid all fall out relative to that marker. Gates 1–8 are unaffected. Additional markers buy drift correction as operators walk, and their positions can be tape-measured relative to the primary one in five minutes on the day — no survey, no prior visit.

Plan for Track B and treat Track A as an upgrade.

Track A — if we get the room beforehand

One ~20 minute walk under show lighting, three artifacts:

ARWorldMap (serialize, pre-load onto devices over LAN before demo day — tens of MB).
LiDAR mesh from the Pro phone.
50–100 frame sequence for VGGT-Ω → dense point cloud, Sim(3)-aligned to the venue frame via marker positions. The on-screen 3D room, precomputed so it cannot fail live.
Track B — no access, or access only on the day
Drop ARWorldMap entirely. It was a backup relocalization path, never the primary one. Markers replace it.
Marker positions by tape measure on the day. Primary marker is the origin; measure 3–4 others relative to it and punch the numbers into venue.json. Fifteen minutes of setup. A laser measure makes it five.
Point cloud becomes optional stage candy, not a dependency. Two options: capture it during setup on the day (Pro phone, perimeter walk, run VGGT-Ω while the audience files in), or capture a similar-sized room during the build and label it honestly on screen. If it fails, the existing web dashboard floor plan carries the demo.
Rehearse in a room we can re-enter repeatedly — similar size and lighting, crowded if we can arrange it. The real venue then becomes a config change (venue.json), not a build step.

Agent implication: venue.json — marker IDs, physical widths, and poses relative to the primary marker — is loaded at runtime, never compiled in. Changing venue must require zero code changes and no rebuild. Add a test that loads two different venue.json files and asserts the resulting venue-frame transforms differ correctly.

Server-side notes (not this repo, but constrains it)
Weights storage

The checkpoint is ~4.6 GB fp32. Do not commit it to git. GitHub rejects files over 100 MB, and even via LFS a multi-gigabyte blob makes every clone painful for the rest of the team. Put it outside the repo (or in a gitignored checkpoints/ directory) and reference it by path from config. Add *.pt, *.safetensors and checkpoints/ to .gitignore now, before someone commits it by accident and it's baked into history.

Separately: the FAIR Noncommercial Research License governs redistribution, so a public repo containing the weights is a licensing question as well as a git one. Keep them out of the repo and the question doesn't arise.

Outputs

VGGT-Ω outputs cameras and per-frame depth plus confidence, and register tokens — no point-map head and no tracking head at inference, unlike VGGT. Unproject depth through the cameras to get points.

Throughput sweet spot is 4–8 frame chunks (~24 ms/frame); time grows super-linearly from about N^1.3 toward N^1.7, so 50-frame chunks cost ~2 s. Cast the backbone to bf16 (model.aggregator.bfloat16()) to drop peak memory from ~10.7 GB to ~6.6 GB at 35 frames for ~0.2% depth drift.

Per-chunk output has an arbitrary origin and scale — hence Gate 5.

Do not quote its published benchmark numbers on stage: the authors flagged possible contamination in an ancestor of the released 1B checkpoint, and the headline Sintel figure belongs to the unreleased 10B model.

Target matching: open-vocabulary detector plus VLM confirm for objects. For a specific person, enroll a consenting volunteer from one reference crop and match by CLIP/DINO embedding similarity against detected person crops. This works on the back of a head at 8 m where a face pipeline returns nothing, it is the actual search-and-rescue workflow ("we have a photo of the missing hiker"), and it keeps the privacy line in the pitch intact.