# REVIEW — what the green gates do not show

Reviewed at `b97745d`, 2026-09-19. Read in full: every file under
`Packages/SwarmCore/Sources`, the app target, `tools/fixture-gen`, and the tests
that touch fixtures. **Nothing here was run on a device.** Device-side findings
are reasoned from the code and from ARKit's documented behaviour; where I am
estimating a magnitude I say so.

Ranking is by blast radius: how much of the demo goes wrong, multiplied by how
quietly. Each finding is tagged with which of your three categories it is:

- **[WORDS]** stated intent the implementation does not honour
- **[UNREACHED]** written and tested, never executed in the field
- **[FIXTURE]** passes because of something the generator does that ARKit won't

## What I changed

One commit, `77e4fef`, 4 small hunks in `SessionMachine.swift` (+16/−3) and one
new test file, `FieldBehaviourTests.swift`. Each test failed before, passes
after. Gates after: `swift test` 187/187, `xcodebuild` simulator build succeeded.

| | Defect | Was hidden by |
|---|---|---|
| F1 | Unbroken `.limited` tracking flapped `degraded → lost → degraded` every 4 s: `lost` returned to `degraded` on the next limited pose and restarted the timer. Seven "losses" in 30 s; final state `degraded`. | `degradedFixtureDrivesTheWholeStateMachine` asks only `states.contains(.lost)`. |
| F2 | 84 poses and 12 frame tickets were emitted while `recalibrating` (degraded fixture), confidence up to 1.0, not stale. `hasVenueFramePose` returned true for it. DEVICE_CHECKLIST item 8 and the `ARKitPoseProvider` DEVICE-VERIFY both say none are sent. | [FIXTURE] the generator keeps one world frame `S` across the interruption, so those poses were *correct* in replay. `recalibratingRequiresAMarkerBeforeTrackingResumes` asserts only that some correction ever happened — true from second zero. |
| F3 | `.interrupted` left `quality` at its last value. Real ARKit delivers no frames during an interruption, so that value is `.normal`, and confidence stayed 1.0 (non-stale for 5 s, then stale at 1.0). | [FIXTURE] the generator keeps emitting samples through the interruption window with `notAvailable`, which is what drove confidence down in replay. |

Side effect of F2 worth knowing: `latestVenuePose()` is now nil while
recalibrating, so a tracked arrow hides until a marker is re-seen. That is the
behaviour the overlay already has for a stale pose.

`Beacon.xcodeproj/project.pbxproj` was modified in the working tree during
my session (not by me — it looks like Xcode rewriting build configurations). I
left it alone and out of the commit. The simulator gate passed with it as-is.

---

## Findings, ranked

### 1. The socket sends binary frames; the protocol doc says text — [WORDS]
`Transport.swift:455` sends `.data(data)`. `Wire.swift:11` says "one JSON object
per WebSocket **text** message", and the `FrameChunk.jpeg` comment says to
"switch `Transport.send` to `.data` *if* the server accepts them", i.e. the
author believed it was currently text. The mock orchestrator ignores the opcode,
so it cannot tell. A real server that calls `receive_text()` (FastAPI/Starlette
raises on a binary frame) or checks `typeof msg === 'string'` receives nothing,
ever.
**Demo day:** phones show `online`, the dashboard shows no devices. Thirty-second
check against the real orchestrator; CLAUDE.md says the server wins, so I did
not touch it. The fix is `.string(String(decoding: data, as: UTF8.self))`.

### 2. A frame is paired with a pose from a different instant — [WORDS]
`FrameChunk.pose` is documented as "the pose the frame was captured at"
(`Wire.swift:142`). What happens: `SessionMachine.emitFrameIfDue` stamps the
ticket with `lastPose`; the ticket crosses an unbounded `AsyncStream` to the
`@MainActor` consumer (`AppCoordinator.swift:137`), which shares that actor with
the 30 Hz overlay ticker and SwiftUI; only then does
`CoreImageFrameEncoder.encode` call `takePending()`, which returns **whatever
buffer was staged most recently** (`FrameEncoder.swift:46-61`). Nothing carries
a timestamp from the buffer to the ticket. When emission is driven by `tick()`
rather than a pose, same thing.
The skew is the hop latency — my estimate is 1–4 frames normally, more when the
main thread is busy. Operators sweep; at 60–90°/s, 50 ms is 3–4.5°, which is
25–40 cm at 5 m, signed by sweep direction.
**Demo day:** target pins smear left when sweeping left and right when sweeping
right. Still phones look perfect, so it reads as "inference is noisy".
The `.capture` trace stamp has the same error (it is the pose's time, not the
buffer's). Fix shape: carry `frame.timestamp` in `PixelBufferHandoff`, have the
provider keep a short pose ring, and let the encoder return the timestamp of the
buffer it actually used so the chunk is stamped with the matching pose.

### 3. A bad first fix, or one ARKit jump, locks a phone out of correction for good — [FIXTURE]
`CalibrationEngine.evaluate` (`Calibration.swift:192-200`): the first sighting
is applied unclamped and unvalidated; afterwards anything implying >1.5 m / 25°
is rejected. There is no way back. If the first detection is wrong, or ARKit
relocalises with a jump larger than the threshold (common in a crowded,
feature-poor hall), every subsequent *correct* sighting is rejected forever,
while ARKit reports `.normal` and confidence recovers to 1.0.
Rejections are also invisible: `AppCoordinator.swift:146` drops
`.correctionRejected`, and `StatusPill` has no field for it. The operator sees
`fix 45s` climbing and nothing else.
The replay can never show this: the largest disagreement after the first fix in
the 2-minute walk is **4.8 cm / 0.6°** (measured). The reject threshold and the
0.25 m clamp are never approached by any fixture; only hand-built unit cases
reach them.
**Demo day:** one phone is confidently metres off until someone force-quits it.
Fix shape: N consecutive rejections that agree *with each other* re-establish
the origin; show the rejected count on the pill.

### 4. The marker sets pitch and roll as well as yaw — [WORDS] [FIXTURE]
CLAUDE.md: "Gravity fixes pitch and roll; the marker fixes yaw."
`Calibration.worldOriginTransform` hands `setWorldOrigin` the full 6-DoF
`observed · markerVenue⁻¹`, so every sighting re-tilts a world that gravity had
already levelled. For a wall marker the axes ARKit estimates worst are the two
out-of-plane tilts, and a wall marker's *yaw* is one of them.
The generator's only rotational noise is `rot_y(gauss(0, 0.004))` in the
marker's local frame (`generate_trajectories.py:330`) — 0.23° about the marker
**normal**, the one axis ARKit gets right. Out-of-plane noise is zero.
Combined with the 2 cm / 0.5° no-change band and the 0.5 s minimum interval, a
marker in view at 3 m will plausibly trigger a fresh `setWorldOrigin` twice a
second, each rotating the world about the origin by that sighting's tilt error.
2° at 8 m from the origin is 28 cm, and floor height goes with it.
**Demo day:** cones near the stage look fine; cones at the back of the room bob
and swing whenever their phone can see a marker, and are steadier when it can't.
**Do not fix this before the axis measurement** — see "Geometric conventions"
below: projecting to yaw-only would convert a loud convention failure into a
silent one. After the measurement: keep only the twist about +Y of the
correction, re-solve translation so the marker centre still lands, and low-pass.

### 5. The 300 ms budget is not measured by anything that runs — [WORDS] [UNREACHED]
- `replayedFramesStayInsideTheLatencyBudget` takes tickets from the replay and
  feeds them to a `PipelineSimulator` whose stage durations are constants chosen
  inside the budget. It asserts the constants are inside the budget. The
  companion "regressed" test does the same with constants outside it. Neither
  touches the encoder, the transport, or a clock.
- `FrameAssembly.chunk` is called with `encodedAt: clock()` and `sentAt: clock()`
  on adjacent lines (`AppCoordinator.swift:169-172`), *before*
  `transport.send`. `.sent` is documented as "handed to the WebSocket"; it is
  actually "about to enter the perishable buffer". Encode→send is therefore
  ~0 µs by construction and can never regress; time spent waiting behind two
  in-flight messages is billed to "network".
- `Command` has no trace field, nothing ever stamps `.painted`, and
  `LatencyStatistics` / `violations()` are referenced only from tests. "A
  regression past budget fails the gate" is true of no gate that exists.
**Demo day:** if "look left" is late you have no number that says which stage.

### 6. Multi-marker averaging can still fail to fire on a device — [UNREACHED] [FIXTURE]
The batching rule in `SessionMachine.handle` closes the batch on *any* pose
event. In `ARKitPoseProvider.forward` each sighting is a separate
`await provider.ingest(sighting:)` inside one Task; the actor is free to run a
frame Task's `ingest(sample:)` between them. When it does, marker A is flushed
alone, marker B arrives 0 s later and is discarded by `minimumInterval`.
Separately, a marker's first appearance arrives via `didAdd` and the others via
`didUpdate` — two callbacks, two `CACurrentMediaTime()` values, never equal to
1e-6.
`MockPoseProvider` emits same-timestamp sightings contiguously with nothing
between them, which is why `simultaneousSightingsInTheReplayAreAveraged` passes.
(7 of 115 batches in the walk are multi-marker.)
**Demo day:** the checklist item "one correction naming both" intermittently
shows one marker. Fix shape: one actor hop carrying `[MarkerSighting]`, one
`.markers([…])` event, and batch by ARKit frame rather than by timestamp
equality.

### 7. First-launch clock sync can be seconds wrong for ~15 s — [WORDS]
`runClockSync` stamps `t0` when it *enqueues* the ping, and pings whether or not
the socket is up. Control messages queue while disconnected. On first launch the
local-network prompt holds the connection open for as long as the operator takes
to tap Allow; the ten fast pings all queue, then the interval drops to 5 s. On
connect they flush with `t0` stale by D seconds, each giving offset error ≈ D/2.
`isSynchronized` needs 3 samples, so poses start flowing on that offset. The
first fresh pong then differs by >0.5 s, so `ClockSync` treats it as a *step
candidate* and wants three in agreement — at 5 s apart.
**Demo day:** for the first ~15 s after joining, `serverNow` runs ahead, so any
command with `expiresInMs` shorter than the error is discarded as already
expired, and pose timestamps disagree with every other phone. Fix shape: only
ping while `.connected`, stamp `t0` at send, and refuse samples whose round trip
is absurd.

### 8. `AsyncStream(.bufferingNewest(8))` at the ARKit seam can drop the events that matter — [FIXTURE]
`ARKitPoseProvider.start` buffers 8 events and discards the oldest. At 60 Hz
that is 133 ms of slack. Poses, marker sightings, `.interrupted` and
`.interruptionEnded` share the buffer, so a stall in the session actor (it
awaits `setWorldOrigin` inline) evicts whichever is oldest, including a
sighting or an interruption edge. A dropped `.interruptionEnded` means the
origin is never invalidated. `MockPoseProvider` is deliberately lossless
(`bufferingOldest` + retry), so no test can observe a drop.
Related: each delegate callback spawns an unstructured `Task`; nothing orders
them, so two poses can be ingested out of order and `lastPose` keeps the older.
Fix shape: coalesce poses (latest-wins slot) and send control events on a
separate unbounded path.

### 9. Drop-if-busy in `FrameEncodePipeline` cannot trigger; poses queue behind encodes instead — [UNREACHED] [WORDS]
The only caller awaits `pipeline.submit` inline in the single `for await` loop
over session events (`AppCoordinator.swift:143`). There is never a second submit
while one is in flight, so `droppedBusy` is structurally 0 — DEVICE_CHECKLIST
item 9 asks you to confirm it is "non-zero under load". Meanwhile every pose
behind that ticket waits for the JPEG on an `.unbounded` stream, which is the
queue CLAUDE.md forbids, then arrives at the transport in a burst where
latest-wins discards all but one.
**Demo day:** the cone stutters at the frame rate (a ~30–60 ms hole every
0.67 s). Fix shape: run the encode in its own Task so the loop keeps draining.

### 10. Server depth matches cameras by array index and assumes no frame was dropped — [WORDS]
`DepthScaleNegotiator.reply` requires `inbound.frames.count ==` the recorded
count and pairs them by position, never by `frameID`. Frames are perishable by
design (buffer depth 1, latest-wins), so a chunk naming six frames will often
reach the server as five. If the server reconstructs what it received, the phone
calls it `malformedEstimate` and counts it under `unscalable`, whose doc says
"no parallax". A reordered reply fits silently against the wrong pairs.
`everyChunkFromTheReplayedWalkIsAnswered` builds the server reply *from the
phone's own positions divided by 11.4*, so count, order and geometry agree by
construction.
Also unreached: `ServerDepthSource.depth(for:)` and its `estimates` closure are
still never called by anything; only `.scale(_:against:)` is, via the
negotiator, with `maps: []`.

### 11. LiDAR chunks pair "latest depth" with six older frame refs — [WORDS]
`LiDARDepthSource.depth` returns whatever depth map is newest at the time the
ticket is handled and **discards its pose and timestamp**; `FrameAssembly`
attaches that map to a chunk whose `frames` are up to 4 s old. The wire has no
field saying which pose the map belongs to, and no intrinsics for the 256×192
map. CLAUDE.md's "both return metric depth in the venue frame" holds for
neither source: this one is camera-frame, the server one returns no depth at
all to the phone.
Cost: 49 152 floats plus confidence as JSON text is roughly 600 KB per chunk
through the same two-in-flight socket as poses.
Also: `ARKitPoseProvider` copies the depth and confidence buffers on the
delegate queue at 60 Hz regardless of whether a chunk is due.

### 12. "Motion while lost" measures walking while *tracked*, from ARKit, and CoreMotion is never used — [WORDS] [UNREACHED]
`transition(to: .lost)` calls `consumeMotionSinceLastQuery()` once, on entry, so
it reads the distance accumulated since the previous query — i.e. all the
walking done while tracking was fine (27 m in a 40 s probe). Motion during the
loss is not read until the *next* loss. The provider computes it from ARKit
camera positions, which are exactly what is unavailable or untrustworthy while
lost; CLAUDE.md specifies `CMDeviceMotion`. Nothing imports CoreMotion, so
`NSMotionUsageDescription` is unused and the motion prompt the DEVICE-VERIFY
note tells you to look for will never appear. The value reaches no UI.
Similarly `permissionsGranted()` is called unconditionally from
`AppCoordinator.start`; the `permissions` state is never waited in.

### 13. `sound` commands do nothing — [UNREACHED]
`OverlayModel` sets `pendingSound`; `hapticsAndSoundsAreConsumedOnce` tests it;
`AppCoordinator` never calls `consumeSound()` and the app target has no audio
code. CLAUDE.md lists sound among the four commands.

### 14. `lastCorrectionAge` climbs while a phone is staring at a marker that agrees — [WORDS]
`.noChangeNeeded` (within 2 cm / 0.5°, or inside the 0.5 s interval) updates
neither `lastCorrectionTime` nor confidence. A confirmation is as good as a
correction, but the pill flips to "needs attention" at 30 s and the dashboard
sees an ageing fix. In the walk fixture 39 of 115 batches become corrections.
If finding 4 is fixed and corrections get rarer, this gets worse.

### 15. Smaller divergences
- **`framesSuppressedAfterOriginChange`** is documented as "frames to skip" and
  `framesSuppressedForOriginChange` as a frame count; both count *pose ticks*
  (`emitFrameIfDue` decrements before the due check). 2 means 200 ms, not two
  frames. 78 "suppressed" against 165 frames requested in the walk.
- **Frames keep flowing in `lost`** until the 5 s staleness limit (8 tickets in
  the degraded fixture), posed with `notAvailable` tracking.
- **`setRates` with a missing field** resets that field to the compiled default
  (`poseHz ?? 10`), not to the current value.
- **A correction while `.limited` from `calibrating`** enters `degraded` with
  `degradedSince == nil`, so that episode never times out to `lost`. ARKit
  starts every session in `.limited(.initializing)`, so this is the normal
  first-fix path; it self-heals on the first `.normal`.
- **Marker timestamps** are `CACurrentMediaTime()` at callback time, poses are
  `frame.timestamp`; the machine's `now` runs ahead of pose time by the
  difference. Harmless today, but `ARImageAnchor.isTracked` is never checked, so
  the last-known transform of a marker that has left view is still evaluated on
  the `isTracked` flip.
- **`isUpdate` and `estimatedPhysicalWidth`** are carried end to end and read by
  nothing. The latter is filled from `referenceImage.physicalSize` — the
  configured width, not an estimate — and automatic scale estimation is off.
- **JPEGs are sent in sensor (landscape) orientation.** Geometry is
  self-consistent, but a portrait-held phone's picture is sideways on the feed
  wall unless the server rotates it.
- **ATS:** `ws://<ip>` is exempt; `ws://macbook.local` needs
  `NSAllowsLocalNetworking`, which Info.plist does not set.
- **`syntheticFixturesAreLabelledAsSuch`** is "loud on purpose" via
  `#expect(synthetic.count == synthetic.count, …)`. A passing expectation prints
  nothing. CLAUDE.md, PLAN.md and `Trajectory.swift` all still describe the
  fixtures as "real recorded ARKit output".
- **`framesDoNotStarvePosesUnderReplay`** grants one permit per event, so the
  socket keeps up; it passes under strict priority too. The test that would have
  caught the original transport bug is `aContinuousPoseStreamDoesNotStarveFrames`.

---

## Geometric conventions: every site, and how each fails

You are about to measure the `ARImageAnchor` axes. Here is what depends on it.

### The `ARImageAnchor` axis convention (+Y out of the print, image-up = −Z)

| Site | Role | If the assumption is wrong |
|---|---|---|
| `Fixtures/venue.json` (and any `Documents/venue.json` AirDropped to a phone) — every marker `quaternion` | **The only runtime carrier of the convention.** | Must be regenerated. |
| `tools/fixture-gen/generate_trajectories.py:149` `marker_matrix()` | Produces those quaternions *and* every `markerEvents[].transform` in the fixtures. | Change here, regenerate venue + fixtures. Tests stay green either way: generator and venue always agree with each other. |
| `Venue.swift:54` `MarkerConvention` | **Read by nothing.** Three unused constants. | Changing it changes nothing. |
| `DEVICE_CHECKLIST.md:83-99` | Says "fix `MarkerConvention`, not the venue file." | **Backwards** — see above. Following it leaves the bug in place with a green build. |
| `Calibration.swift`, `CalibrationTests.swift` | Convention-free. Pure composition; the tests put a wall marker at identity orientation, which under the stated convention is a marker lying on the floor. | Nothing to change. Also means no test exercises the convention. |
| `tools/marker-gen` print sheet | Which edge of the print is "up". A label under each marker implies it. | A marker mounted rotated fails like a convention error for that marker only. |

**Loud or silent?** Nothing on the phone checks. The first sighting is applied
unvalidated, so the world is rotated about the primary marker's centre by the
conjugated error `M·E·M⁻¹`:

- *Normal/up swapped (90° class):* the floor stands on end. Heights vary by
  metres as people walk. Loud on the dashboard, silent on the phone.
- *Image-up is +Z rather than −Z (180° about the normal):* for the primary
  marker at (0, 1.6, 0) facing +Z this maps (x, y, z) → (−x, 3.2 − y, z). A
  phone at chest height 1.48 m reports **1.72 m**. X is mirrored, Z is correct,
  heights are plausible. **This is the silent one.** World-up is now physical
  down, so `relativeBearing`'s sign flips and every arrow points the wrong way.
  Checklist item 3 as written can miss it: "within ~15 cm of (0, ~1.5, 0)" is
  borderline at 1.72, "+Z must increase" passes, and the X check only works if
  the person knows which sign to expect.
- *Either way*, secondary markers on other walls then disagree by more than the
  threshold and are rejected — invisibly (finding 3).

**The cheapest discriminator, no code needed:** after the first fix, raise the
phone 50 cm. Reported Y must go **up** by 0.5. Add it to item 3.

**The tripwire worth adding after you have measured:** with
`worldAlignment = .gravity` both frames share an up axis, so a correct
`relativeTransform` is a rotation about +Y plus a translation, whatever the
marker's mounting. Reject (loudly, on the pill) any origin whose
`R · (0,1,0)` is more than ~15° from `(0,1,0)`. That catches every convention
error except a pure yaw one, needs no knowledge of the convention, and is the
reason not to do finding 4's yaw-only projection first: the projection would
throw away exactly the evidence this check uses.

### `setWorldOrigin(relativeTransform:)` means "new origin in current world coordinates" (p ↦ R⁻¹p)

Assumed independently in four places, which agree with each other and with
Apple's documentation but have never met ARKit:
`Calibration.worldOriginTransform` (`R = observed · markerVenue⁻¹`),
`MockPoseProvider.setWorldOrigin` (`offset = R⁻¹ · offset`),
`SessionMachine.remapBufferedFrames`, and the generator's docstring.
The mock *implements* the assumption and the tests verify against the mock, so
the replay is circular on this point. If it were inverted, the first fix would
land the phone somewhere arbitrary and every later sighting would be rejected:
loud-ish (pose nowhere near the marker on checklist item 3.1).

### Camera looks down −Z; bearing positive = right

`Geometry.swift:26` `CameraAxis.forward`, used by `Pose.forward`, `Geometry.yaw`,
`relativeBearing`. Restated independently in `generate_trajectories.py:312`
(`forward = (−sin yaw·cos pitch, …)`) and `camera_pose`, and assumed by the
dashboard's cone renderer, which I cannot see. `ArrowView` relies on SwiftUI
rotation being clockwise-positive to avoid a sign flip. `OverlayTests` pins the
sign with hand-built poses, so this one is well covered *given* a right-way-up
world.

### Quaternion order x,y,z,w and column-major matrices

`Wire.swift:375`, `Venue.swift:37`, `SessionMachine.swift:672`,
`PoseUpdate.venuePose`, `Trajectory.matrix(from:)`, and in Python
`quat_from_matrix` / `column_major`. Consistent everywhere I looked. A mismatch
with the real server's order would be silent (a valid but different rotation);
worth one eyeball of a known pose on the dashboard.

### Intrinsics

`ARKitPoseProvider.intrinsics(of:)` → ticket → `FrameEncoder` rescales by the
JPEG factor. Correct for the sensor-orientation image that is sent. Would become
silently wrong the moment anyone rotates the JPEG to fix the feed wall without
also swapping fx/fy and cx/cy.

---

## Load-bearing properties of the synthetic fixtures

What the generator does that ARKit will not, and which assertions become
meaningless against a real recording.

| Generator property | Real ARKit | Assertions that lean on it |
|---|---|---|
| Drift is a continuous random walk: ~3 cm and ~0.6° over two minutes, x/z/yaw only. | Grows with distance walked, and arrives as **jumps** on relocalisation. Y, pitch and roll drift too. | `correctionsReduceAccumulatedDriftOverTheReplayedWalk`: `finalError < 0.30` passes with **no corrections at all** — measured: the uncorrected replay ends 5.5 cm out, 11 cm at worst; `largestAppliedStep ≤ 0.25` is never tested because no step exceeds 5 cm. Rejection and clamping are exercised only by hand-built unit cases. |
| Marker noise: 4–10 mm position; rotation only about the marker normal, σ 0.23°. | Out-of-plane tilt is the noisy axis, degrees not tenths, growing with range and obliquity. | The "corrected beats uncorrected" comparison is decided by this noise model. Finding 4 is invisible. `averagingReducesIndependentMarkerError` is fine (own synthetic noise, honestly labelled). |
| One session frame `S` for the whole file, including across the interruption. | After an interruption ARKit either relocalises or restarts in a new frame. | Anything about poses after `recalibrating` (F2). `aCorrectionRestoresConfidenceImmediately` — which also only checks that *a* correction followed *a* dip, not what confidence did. |
| Samples continue through the interruption as `notAvailable`. | No frames at all. | F3; also the `lost`-before-`recalibrating` ordering in `degradedFixtureDrivesTheWholeStateMachine` comes from those samples as much as from the `.interrupted` event. |
| Timestamps are exactly `t0 + i/60`; a marker event's `t` equals a sample's `t` to the bit; co-visible markers share a `t`; sightings are contiguous in the event stream. | `frame.timestamp` jitters and drops; marker time is callback time; `didAdd`/`didUpdate` are separate callbacks; events interleave. | `simultaneousSightingsInTheReplayAreAveraged` (finding 6). `replayedPosesCarryConsistentServerTimestamps` (`spread < 1e-6`) is a property of `ClockSync` being a constant here, not of the recording. The throttle-rate tests are fine: they measure rates over a window and would survive jitter. |
| Tracking state is a step function: normal → limited for exactly N s → normal. | Flickers between `.normal` and `.limited` at frame rate near the edge of a feature-poor area. | The state-sequence tests. Flicker resets `degradedSince` on every `.normal` frame, so a phone that is limited 90% of the time may never reach `lost`. Untested. |
| Sightings are throttled to one batch per 0.25 s, only within 4.5 m, a 28° half-angle and 55° obliquity. | 60 Hz `didUpdate` while tracked; detection envelope unknown until checklist item 4. | `posesCarryTheAgeOfTheLastCorrection`: `ages.max() < 60` is a statement about the walk path and marker layout in the generator. |
| Session origin has y = 0 and no tilt; camera height 1.48 m ± 2 cm. | ARKit's origin is wherever the phone was at launch. | Nothing directly; the first fix is unclamped. |
| The mock's `setWorldOrigin` takes effect on the very next event and the stream is lossless. | Frames already in flight are in the old frame; the seam buffer drops (finding 8). | `minimumInterval` and the two-tick frame suppression are the only protection and are untested against in-flight data. |
| `groundTruth` exists. | It won't. | `correctionsReduce…` uses `try #require(trajectory.groundTruth)`, which **fails** rather than skips — `Trajectory.swift` promises a skip. Dropping in a real recording turns the suite red, which is a standing incentive to keep the synthetic file. |

One thing to get right when recording: `MockPoseProvider` applies its own origin
offset to the recorded marker transforms, so the recording must come from a
session that **never calls `setWorldOrigin`** — the throwaway recorder in
PLAN.md, not this app.

---

## Tests that pass for a weaker reason than their name

- `recalibratingRequiresAMarkerBeforeTrackingResumes` — only asserts
  `!corrections.isEmpty`, true from the first second. (Superseded by F2's test.)
- `aCorrectionRestoresConfidenceImmediately` — passes if any correction follows
  any dip, or if the final confidence is high. Never reads confidence after the
  correction.
- `degradedFixtureDrivesTheWholeStateMachine` — `contains` checks; blind to
  flapping. (Superseded by F1's test.)
- `replayedFramesStayInsideTheLatencyBudget` / `aRegressedPipelineIsCaught…` —
  assert on simulator constants (finding 5).
- `everyChunkFromTheReplayedWalkIsAnswered` — server reply derived from the
  phone's own data (finding 10).
- `framesDoNotStarvePosesUnderReplay` — no starvation occurs in it.
- `syntheticFixturesAreLabelledAsSuch` — tautology.
- `hapticsAndSoundsAreConsumedOnce` — the sound half tests a path nothing calls.
