# DEVICE_CHECKLIST.md

Everything below is a claim the automated suite **cannot** make.

ARKit does not run in the iOS Simulator, so no line of positioning code in this
repo has ever executed. `swift test` exercises SwarmCore against recorded
trajectories through `MockPoseProvider`; `xcodebuild` proves the app target
compiles. Neither proves the phone knows where it is.

Work top to bottom. Items 1–12 are the twenty-minute pass; 13–18 need a longer
run and can happen in parallel with everything else. **Anything that fails in
1–6 stops the demo**, so do those first and do them in the actual room if you
can get into it.

## Before you start

- [ ] Developer Mode on every phone (Settings → Privacy & Security → Developer
      Mode; needs a restart). Do this the night before — the restart is the part
      people forget.
- [ ] Markers printed on matte stock, high contrast, non-repetitive. No glossy
      paper.
- [ ] **At least two markers on the same wall**, close enough together to be in
      frame at once (about 1.5 m apart works at normal viewing distance).
      Co-visible markers are what make averaging worth anything: two independent
      detection errors partly cancel, and a misdetection shows up as
      disagreement rather than being applied. Markers on separate walls can
      never do that for each other.
- [ ] **Every marker measured with a tape after printing** and the measured width
      typed into `Fixtures/venue.json`. Printers scale. A marker declared 2 cm
      wider than it is makes every distance in the venue wrong by that ratio,
      and it will look like "positioning is a bit off" rather than like a
      measurement error.
- [ ] `venue.json` on each phone. Either rebuild, or AirDrop it into the app's
      Documents directory — `UIFileSharingEnabled` is set, and the app prefers
      the Documents copy over the bundled one. The second route is the one to
      use on the day.
- [ ] Orchestrator reachable. Set the URL in the app's `orchestratorURL`
      preference; the default is `ws://192.168.1.10:8765/device`.

---

## 1. Local-network permission actually prompts

The one that bites everyone.

1. Delete the app from the phone (the prompt only appears once per install).
2. Launch it. **A system alert asking to find devices on the local network must
   appear.** Tap Allow.
3. Confirm the status pill shows `net online`.

If no prompt appears and the socket never connects, `NSLocalNetworkUsageDescription`
or `NSBonjourServices` is missing from `Resources/Info.plist` and the connection
fails silently with no error anywhere.

- [ ] Prompt appeared, was allowed, socket connected.
- [ ] Camera permission prompt appeared and was allowed.
- [ ] Motion permission prompt appeared and was allowed.

## 2. The marker establishes the origin at all

1. Stand 1.5 m from the primary marker, pointing at it.
2. Watch the status pill go `calibrating` → `tracking`, and `fix never` → `fix 0s`.

- [ ] Reached `tracking` within 5 seconds.
- [ ] `fix` is a number, not `never`. **If it says `never`, nothing this phone
      reports can be fused with anyone else's** — the app deliberately sends no
      poses at all in that state.

## 3. The origin is where we think it is

The single most likely silent failure, and the one nothing in the test suite can
catch: `MarkerConvention` in `Packages/SwarmCore/Sources/SwarmCore/Venue.swift`
asserts that an `ARImageAnchor`'s **+Y axis points out of the printed surface**,
with the image in the anchor's local x–z plane and image-up along local −Z.
`venue.json` states every marker pose in that same convention. If ARKit
disagrees, everything is mirrored or rotated 90°, and the dashboard will look
plausible while being wrong.

1. Sight the primary marker, then stand on the floor directly below its centre.
2. Read the reported position off the dashboard.

- [ ] Position is within ~15 cm of `(0, ~1.5, 0)` — the venue origin is on the
      floor below the primary marker's centre, and the phone is at chest height.
- [ ] Walk 2 m toward the audience. **+Z must increase.** If it decreases, the
      marker's quaternion in `venue.json` is 180° out.
- [ ] Walk 2 m to your right as you face the stage. Check which of ±X that is
      and that it matches the dashboard. If X and Z are swapped, the anchor
      convention is wrong — fix `MarkerConvention`, not the venue file.

## 4. Marker detection range and angle

Walk away from a marker in a straight line, sighting it, and note where
`fix` stops resetting.

- [ ] Maximum detection distance, head-on: ______ m *(expect 3–5 m for an A4
      marker; under 2 m means the print or the lighting is the problem)*
- [ ] Maximum angle off the marker normal at 2 m: ______ ° *(expect 45–60°)*
- [ ] Repeat under **show lighting**, not room lighting. Stage wash and slide
      changes are the usual killers.
- [ ] If the numbers are much worse than this, put up more markers rather than
      trying to tune anything.
- [ ] Stand where two markers are both in frame. The dashboard should show one
      correction naming both (`marker-primary+marker-stage-left`), not two
      separate ones. If it never does, they are not actually co-visible — move
      them closer together.

## 5. Re-lock time after walking out and back

Corrections are the whole drift story, so this is the number that decides
whether the demo holds for its full length.

1. Sight a marker. Note `fix 0s`.
2. Walk out of sight of every marker for 60 seconds, sweeping normally.
3. Walk back and point at any marker.

- [ ] Seconds from re-entering view to `fix` resetting: ______ s *(want < 2 s)*
- [ ] The cone on the dashboard **converged** rather than jumping. A visible
      teleport means `maxStepMeters` in `venue.json` is too large.
- [ ] `fix` climbed while away and reset on return — not stuck.

## 6. Drift over a five-minute walk

1. Mark a spot on the floor with tape. Stand on it, sight the primary marker,
   note the reported position.
2. Walk the room for five minutes, sweeping, **without sighting any marker**
   (cover them or avoid them).
3. Return to the taped spot.

- [ ] Reported position error on return: ______ m *(under 0.5 m is good; over
      1.5 m and the venue needs more markers, not different code)*
- [ ] Repeat **with** markers visible. Error on return: ______ m — this must be
      substantially smaller. If it is not, corrections are being rejected;
      check the dashboard for rejected-correction counts and loosen
      `rejectPositionMeters`.

## 7. Backgrounding and resume

1. While tracking, swipe up to the home screen. Wait 10 seconds. Return.

- [ ] Status pill went to `lost`, then `recalibrating`.
- [ ] **No pose was sent while recalibrating.** The origin is invalid after an
      interruption and the app must send nothing until a marker re-establishes it.
- [ ] Sighting a marker returned it to `tracking`.

2. Take a phone call (or trigger any interruption) mid-session.

- [ ] Same sequence. The session did not wedge.

## 8. Staleness is visible

1. While tracking, cover the camera completely for 10 seconds.

- [ ] Within ~5 seconds the pill shows the stale clock badge and goes `lost`.
- [ ] The dashboard **greyed** the cone rather than continuing to draw it
      confidently in the last known place.

## 9. Frame encoding rate and resolution

`FrameEncodingConfiguration.targetLongEdge` defaults to 960 px. Three to five
phones means you can afford better than 640; measure rather than guess.

- [ ] Achieved frame rate at 960 px: ______ fps *(target 1–2)*
- [ ] Mean encode time at 960 px: ______ ms *(budget is 30 ms capture→encode)*
- [ ] Repeat at 1280 px: ______ fps, ______ ms.
- [ ] Repeat at 640 px: ______ fps, ______ ms.
- [ ] Drop count after five minutes: ______ *(drops are correct behaviour under
      load; a drop count that equals the submit count means the encoder never
      keeps up and the resolution is too high)*
- [ ] Pick a resolution from these numbers and write it into the config.

## 10. End-to-end latency against the budget

Hard target is **under 300 ms**. The web prototype measures ~1000 ms median,
which is fatal for the "look left" directive: people turn, see nothing, and read
it as broken.

The trace comes back from the server attached to the command. Read the medians
off the dashboard.

| Stage | Budget | Measured |
|---|---|---|
| capture→encode | 30 ms | ______ |
| encode→send | 20 ms | ______ |
| network | 30 ms | ______ |
| server queue | 50 ms | ______ |
| inference | 100 ms | ______ |
| paint | 30 ms | ______ |
| **end to end** | **300 ms** | ______ |

- [ ] Median end-to-end under 300 ms.
- [ ] p95 recorded: ______ ms.
- [ ] If a stage is over, the trace says which one. Do not guess.

## 11. The arrow points the right way

The sign convention is tested in `OverlayTests`, but only against the maths.
This checks it against a human.

1. Have the orchestrator send an arrow command with a target 3 m to the
   operator's **right**.

- [ ] The on-screen arrow points right and the operator turns right.
- [ ] Turning toward the target rotates the arrow toward vertical.
- [ ] Facing the target shows the "in view" state.
- [ ] Repeat with a target **behind** the operator — the arrow points backwards
      rather than clamping to one side.

If it points the wrong way, fix `Geometry.relativeBearing` and the test that
covers it, not `ArrowView`.

## 12. Haptics and flash

- [ ] A `haptic` command produces a sharp transient you can feel.
- [ ] Backgrounding and returning does **not** kill the haptic engine
      permanently (it stops on interruption; `HapticPlayer` restarts it).
- [ ] A `flash` command fills the whole screen, edge to edge, and is visible
      from across the room.
- [ ] A `flash` clears itself after its duration.

---

## Longer runs

## 13. Thermal behaviour

ARKit plus streaming for thirty minutes will cook a phone. A thermally throttled
phone drops ARKit tracking, not just frame rate.

Run continuously and record the pill's thermal indicator and frame rate:

- [ ] 10 min: thermal state ______, fps ______, tracking state ______
- [ ] 20 min: thermal state ______, fps ______, tracking state ______
- [ ] 30 min: thermal state ______, fps ______, tracking state ______
- [ ] At `.serious` the frame rate visibly sheds and the **pose rate does not**.
- [ ] The phone did not lose tracking outright.
- [ ] Battery remaining at 30 min: ______ %. Decide now whether phones need to
      be on power during the demo.

## 14. Thirty minutes without a leak

- [ ] Memory flat across a 30-minute run (Xcode memory gauge).
- [ ] Transport drop counter rising is fine. **In-flight count must not grow** —
      if it climbs, backpressure is not working and the phone is reporting where
      it was thirty seconds ago.

## 15. Screen stays awake

- [ ] The screen did not dim or lock during a 30-minute run
      (`isIdleTimerDisabled`).

## 16. LiDAR depth (Pro devices only)

- [ ] `hasLiDAR` true in the hello message on a Pro device, false on a non-Pro.
- [ ] Depth chunks arrive with `source: lidar` and `metricScale: 1`.
- [ ] A measured distance to a wall matches a tape measure within ~5 cm.
- [ ] On a non-Pro device the app behaves identically except that chunks arrive
      with `source: server`. **Nothing in the UI or the session logic should
      differ.**

## 17. Server depth is metric before anything uses it

- [ ] A chunk captured while walking comes back with a fitted `metricScale`.
- [ ] A chunk captured standing still comes back with **no scale**, and the
      dashboard does not draw it. VGGT-Ω depth is scene-normalized; a stationary
      phone gives no parallax and no scale exists to recover.
- [ ] A recovered depth compared against a tape measure: within ~5%.

## 18. Multi-phone agreement

The point of the whole exercise.

1. Three to five phones, all sighting the primary marker.
2. Stand two of them at the same taped spot, one after the other.

- [ ] Both report the same position within ~20 cm.
- [ ] Clock offsets converged: every phone shows a `fix` age and the dashboard
      is not showing cones from the past.
- [ ] Walk all phones for five minutes. They still agree.

---

## What the automated suite already covers

Do not re-check these by hand; they run on every commit:

- Wire protocol round-trips for all seven message types.
- Backpressure drops rather than queues; the newest pose survives; reconnect
  does not replay stale frames.
- Clock sync converges across 4 s skew with 80 ms jitter, handles asymmetric
  latency and a sleep/wake step change.
- Calibration maths, multi-marker averaging, rejection thresholds, correction
  clamping, and that corrections reduce drift over a replayed walk.
- The state machine, throttle rates, staleness flagging, confidence decay,
  thermal rate shedding, and thirty minutes of replay with flat internal storage.
- Depth scale fitting, outlier robustness, and refusing to guess without
  parallax.
- Encoder queue policy, drop accounting and resolution/intrinsics scaling.
- Latency budget checks, including a deliberately regressed pipeline to prove the
  check can fail.
- The arrow's sign convention and the status pill's contents.

## Known unverified assumptions

Listed so nobody mistakes them for tested facts:

1. **`ARImageAnchor` axis convention** (item 3). Everything geometric depends on
   it and nothing here has confirmed it on hardware.
2. **The fixtures are synthetic.** `Fixtures/trajectory-*.json` were generated by
   `tools/fixture-gen/generate_trajectories.py`, not recorded. They approximate
   ARKit's drift, jitter and dropout characteristics; they do not reproduce them.
   Any number derived from them about the *character* of ARKit motion — drift
   rate, re-lock time — is fiction until a real recording replaces them.
   PLAN.md human task 2.
3. **`automaticImageScaleEstimationEnabled` is off**, so marker scale comes
   entirely from the tape-measured width in `venue.json`. If detection turns out
   to be unreliable at range, this is the first knob to try.
4. **The wire protocol is this repo's guess** at what the existing orchestrator
   speaks. If the server disagrees, the server wins: change
   `Packages/SwarmCore/Sources/SwarmCore/Wire.swift` and nothing else.
5. **`setWorldOrigin` timing.** The session suppresses two frames after the
   origin moves, assuming at most a frame or two of ARKit lag. If corrections
   visibly corrupt geometry, raise `framesSuppressedAfterOriginChange`.
