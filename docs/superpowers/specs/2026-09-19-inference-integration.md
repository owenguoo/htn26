# YOLOE + OSNet integration design

Status: implemented and locally verified; physical-phone accuracy and cloud-GPU capacity remain unverified.
Baseline: htn26 commit d8392f5; inference service commit 51bc388.

## Outcome

The operator selects one reference person in the existing console.
Existing phones keep streaming to the hub.
YOLOE detects people and OSNet ranks their appearance against that reference.
Phones and the console show likely matches with source-frame metadata.
An operator confirms a sighting before the mission treats it as a confirmed visual find.

## Architecture

Keep the hub, a lightweight bridge, and the inference server as three independently restartable processes in one repository.
The bridge consumes the existing `/ws/frames` endpoint, calls the inference server's authenticated `/v1/match`, and posts results to the hub's `/api/detections`.
The bridge lives in the hub's Python environment and contains no model dependencies.
The inference service lives under `services/inference/` with its own Python 3.12 environment, lockfile, tests, and Dockerfile.
This avoids blocking the hub and preserves an HTTP boundary for moving the inference server to a GPU host.
A separate bridge process reuses the existing subscriber protocol and can reconnect without changing the hub's dual-server startup, which currently disables ASGI lifespan handling.

## Constraints

- People only: YOLOE plus OSNet; no SAM 3, general object matching, or face recognition in this integration.
- One active reference search per room for the first version.
- Keep phone camera, calibration, SLAM, coverage, planner, and simulator flows intact.
- Keep model weights, photos, tokens, and virtual environments out of Git.
- Keep the inference API key server-side; phones talk only to the hub.
- Retain separate detection confidence and appearance similarity fields.
- No model execution on the hub event loop.
- At most one pending frame per phone, one in-flight request per phone, and four global in-flight requests initially.
- Default inference sampling is one frame per second per phone, independent of the console's eight-FPS focused feed.
- Drop results older than 1500 ms, from old phone connections, old search revisions, or superseded result sequences.
- A newer captured frame alone must not invalidate every older result; require monotonic accepted results plus bounded age.
- No exact target map coordinates or responder dispatch inferred from a single image bounding box.

## Existing integration points and gaps

`swarm/hub.py` exposes `/ws/frames` with `{phoneId, seq, t, pose}` plus JPEG bytes using `swarm/protocol.py`.
Its `/api/detections` accepts normalized `{x,y,w,h}` boxes and sends a `detections` command to the phone.
`web/phone.js` already renders these boxes using `frameToScreen`, accounting for the camera's cover fit.
The endpoint currently strips extra result fields and does not track sequence, reference version, or result age.
`FrameSubscriber` attaches the phone's current pose at send time, rather than preserving a frame-associated pose snapshot.
Phone reconnects reuse IDs and can restart sequence numbers.
`swarm/target.py` explicitly models a mock candidate at known room coordinates and declares it found from camera-cone geometry.
`swarm/mission.py` can place that mock candidate and change phases; real visual evidence must remain distinguishable from simulation.
Both projects currently use the distribution name `beacon`, and their Python version requirements differ.
No test suite is present in the inspected htn26 checkout.

## Real sightings versus simulated targets

Retain the mock flow behind an explicit simulation mode.
In real-search mode, store visual sightings separately with phone ID, source frame, reference revision, similarity, box, observation time, and available frame-associated pose.
Initial automatic status is `likely`, never confirmed identity.
Confirmation marks a specific current sighting as operator-confirmed and can pause scanning via the existing phase controls.
It must not call `Target.on_found`, invent `Target.pos`, dispatch responders, or count the finder as physically at the person.
Localization and responder guidance need a separate position estimate or an operator-selected map location.
Mission Control receives structured sighting summaries and the unknown-position state, not invented coordinates.
