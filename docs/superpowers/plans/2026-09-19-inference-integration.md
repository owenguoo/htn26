# YOLOE + OSNet Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Integrate the tested person matching pipeline with htn26's existing phone streams, console, and mission state.

**Architecture:** Preserve the hub and browser applications.
Import the tested inference server into an isolated subproject and add a bounded asynchronous bridge using the existing frame WebSocket and detection callback.
Use one active search per room, version every result, and keep visual confirmation separate from map localization.

**Tech Stack:** Existing FastAPI, websockets, and browser JavaScript; HTTPX for bridge/control requests; isolated Python 3.12, Ultralytics YOLOE, PyTorch, and OSNet for inference.

**Spec:** `docs/superpowers/specs/2026-09-19-inference-integration.md`.

## Global constraints

All requirements in the spec apply to every task.
Tasks 1-6 are implemented; see docs/inference.md for verification commands and outstanding physical-phone and GPU trials.
Keep the root Python requirement unchanged and use Python 3.12 for the inference subproject.
Start with one sampled frame per second per phone, four global in-flight requests, and a 1500 ms result-age limit.
The initial similarity threshold of 0.70 is a configurable test setting, not calibrated identity confidence.
Do not require GPUs in ordinary CI.

## Task 1: Import the working model service as an isolated subproject

**Files:** Create `services/inference/` from `/Users/brianan/Documents/code/swarm-sight/`; update root `.gitignore` and `README.md`.
Copy `src/swarm_sight/`, tests, `pyproject.toml`, `uv.lock`, `.python-version`, Dockerfile, and relevant source/license notices.
Do not copy `.git`, `.env`, `.venv`, model caches, credentials, downloaded binaries, or experimental artifacts.
The separate camera demo may remain as a diagnostic tool but is not the main app UI.

**Interface:** Preserve `PUT /v1/targets/{target_id}`, `DELETE /v1/targets/{target_id}`, `POST /v1/detect`, and `POST /v1/match`.

- [ ] Rename the nested distribution to `swarm-sight-inference`, retaining the existing `swarm_sight` import package and CLI entry point, and regenerate its lockfile.
- [ ] Install only `yolo` and `reid` extras for the default deployment; preserve other backends as optional existing code.
- [ ] Run the imported unit tests and build its wheel, checking that the OSNet architecture/license and static demo assets are packaged.
- [ ] Run the existing opt-in real person test with the public sample image on CPU.
- [ ] Verify root `uv sync` does not install PyTorch or change the hub's environment.
- [ ] Commit the independently working subproject.

Commands from the repository root:

```sh
uv sync --project services/inference --extra yolo --extra reid
uv run --project services/inference --no-sync pytest services/inference/tests -q
uv build --project services/inference
```

Run sample-dependent model tests from `services/inference/` after downloading the README fixture there.
Use port 8001 for inference so it does not conflict with the hub's port 8000.

## Task 2: Define frame identity, search state, and result validation

**Files:** Modify `swarm/hub.py`, `swarm/protocol.py`, and `web/phone.js`; create `swarm/detection.py`, `tests/test_detection.py`, and `tests/test_protocol.py`.

**Interfaces:** Add a server-generated `streamId` on every phone connection and a corresponding `searchRevision` on reference or threshold changes.
Preserve existing subscriber fields and add the new ones compatibly.
The hub stores a frame-associated pose snapshot when it receives a frame; this uses the frame's orientation plus the nearest available position estimate and is not claimed to be exact capture-time positioning.
Carry frame dimensions from phone capture and validate actual decoded dimensions against inference results.

Result payload proposed for `/api/detections`:

```json
{
  "phoneId": "phone-uuid",
  "streamId": "connection-uuid",
  "seq": 42,
  "t": 1750000000123,
  "searchRevision": "search-uuid",
  "targetVersion": "inference-reference-uuid",
  "width": 480,
  "height": 640,
  "boxes": [{"x": 0.1, "y": 0.2, "w": 0.3, "h": 0.6,
             "label": "person", "detectionScore": 0.91, "similarity": 0.82}],
  "queueMs": 10,
  "inferenceMs": 70,
  "matchingMs": 15
}
```

Convert model pixel coordinates with `x=x1/width`, `y=y1/height`, `w=(x2-x1)/width`, and `h=(y2-y1)/height`.
Convert hub milliseconds to inference Unix seconds with `captured_at=t/1000`; convert back only at the boundary.
Derive match status in the hub from validated similarity and the active threshold rather than trusting arbitrary callback labels.

- [ ] Write failing contract tests for normalization, timestamp units, truncated binary headers, non-finite scores, and malformed boxes.
- [ ] Add `Phone.stream_id` and frame snapshot fields; reset them on reconnect and include them in the welcome and frame subscriber messages.
- [ ] Add `SearchState.accept_result(result, *, now_ms) -> bool` in `swarm/detection.py`; reject wrong revisions, wrong connection, unknown/disconnected phone, old sequence, or age above 1500 ms.
- [ ] Use the stream identity in worker phone/frame IDs and clear expired sightings, including when zero candidates are returned.
- [ ] Retain only the latest result per phone and bounded in-flight frame metadata.
- [ ] Test that sequence zero after reconnect is valid for the new stream and invalid for the old stream.
- [ ] Commit after contract tests pass.

Required temporal acceptance examples:

```python
assert state.accept_result(current_result, now_ms=current_result.t + 200)
assert not state.accept_result(current_result, now_ms=current_result.t + 210)
assert not state.accept_result(old_reference_result, now_ms=now)
assert not state.accept_result(old_connection_result, now_ms=now)
assert not state.accept_result(expired_result, now_ms=expired_result.t + 1501)
```

Test fixtures must initialize an active reference and connected phone matching `current_result`; each rejected fixture differs in exactly the named field.

## Task 3: Add reference control and the bounded inference bridge

**Files:** Create `swarm/inference.py` and `tests/test_inference.py`; extend `swarm/detection.py`, `swarm/hub.py`, root `pyproject.toml`, `uv.lock`, and configuration examples.

**Interfaces:** `python -m swarm.inference` runs a lightweight bridge.
It reads authenticated `/api/search` state and `/ws/frames?fps=1`, calls the model service, and posts authenticated detection results.
The hub provides `POST /api/search/reference/people` to locate reference people, `PUT /api/search/reference?box=...` to register one, `DELETE /api/search/reference`, and a threshold update endpoint.
The hub proxies reference requests to the model service; the browser never receives its bearer key.

- [ ] Write failing bridge tests with a fake inference HTTP boundary and real frame packing: slow inference, newest-frame replacement, fairness, and reconnect.
- [ ] Use one async HTTP client, a single receiver loop that drains the WebSocket, one pending slot per phone, and four processing tasks with per-phone exclusion.
- [ ] Keep a round-robin ready queue; bound it to the configured maximum phone count and configure the WebSocket receive buffer so it cannot become a hidden unbounded queue.
- [ ] Snapshot search revision, target version, frame identity, and pose when dispatching; reject obsolete work on both completion and hub ingestion.
- [ ] Poll search state at most once per second; the hub's callback validation protects transitions between polls.
- [ ] Do not infer outside search mode; changing reference, threshold, or phase clears pending work and visible stale results.
- [ ] Handle 409 by dropping superseded work, 429 by bounded backoff, 504 by dropping the frame, and service outages by reporting unavailable while phones/dashboard continue.
- [ ] On model restart, mark the reference unavailable and ask for re-upload instead of persisting sensitive reference photos for automatic replay.
- [ ] Add a bridge bearer secret for its control reads, frame subscription, and result callback; gate reference mutations with an operator session.
- [ ] The inspected hub has no operator authentication: add a small operator login and enforce it on the existing console command WebSocket as well as new reference controls, so a public phone cannot alter the search through another route.
- [ ] Keep worker networking private or behind authenticated HTTPS, and keep all service secrets out of phone JavaScript and WebSocket URLs.
- [ ] Commit after failure/reconnect and authorization tests pass.

Configuration names: `SWARM_INFERENCE_URL`, `SWARM_INFERENCE_API_KEY`, `SWARM_BRIDGE_KEY`, `SWARM_OPERATOR_CODE`, and `SWARM_HUB_URL`.
Missing model configuration leaves the existing mock rehearsal usable and shows inference as disabled.

## Task 4: Integrate reference selection and overlays into existing pages

**Files:** Modify `web/console.html`, `web/console.js`, `web/phone.js`, and `web/dashboard.js`; create browser-stream regression tests.

**Interfaces:** Reuse the main console's existing black/gray Geist design, existing feed subscriptions, and the phone's `detections` command.
Extend hub state with active search, inference availability, and current sightings for console rendering.
Do not add a second camera stream from phones to inference.

- [ ] Add reference upload, numbered person selection, clear-reference, threshold, and worker status to the existing operator console.
- [ ] Reuse the tested demo's resize/upload and person-selection behavior, adapting its endpoints rather than copying the entire demo UI.
- [ ] Preserve `detectionScore` and `similarity` through the hub callback; show similarity as a decimal, not a probability percentage.
- [ ] Keep phone `frameToScreen` for cover-fit alignment and validate portrait, landscape, rotation, and SLAM rendering paths.
- [ ] Discard old stream IDs and sequences on phones; bound overlay TTL by remaining source-frame freshness rather than restarting a full 1500 ms on late arrival.
- [ ] Add overlay metadata to the focused console feed and an exact analyzed-frame preview when buffered source bytes for that result remain available; never relabel a newer thumbnail as the analyzed frame.
- [ ] Verify reference replacement during inference, zero detections, lost connectivity, and score-threshold changes clear stale highlighting.
- [ ] Commit after desktop and physical-phone checks pass.

## Task 5: Connect real sightings to mission state without fake localization

**Files:** Modify `swarm/hub.py`, `swarm/target.py`, `swarm/mission.py`, `web/console.js`; extend `swarm/detection.py` and tests.

**Interfaces:** `SearchState.confirm(phone_id, stream_id, seq, search_revision) -> bool` confirms only an unexpired, active-revision sighting.
Expose `POST /api/search/confirm` to the authenticated operator.
Keep mock `Target` state separate from actual observations.

- [ ] Write a failing test proving a high similarity alone cannot dispatch responders or assign target map coordinates.
- [ ] Display likely sightings, source phone, age, and similarity in the console; add a confirm action bound to the exact sighting identity.
- [ ] On confirmation, record an operator-confirmed visual sighting and optionally transition to `found`; do not call the simulated `Target.on_found` path.
- [ ] Disable cone-based mock discovery while real-reference mode is active and restore rehearsal mode explicitly when requested.
- [ ] Add sightings to Mission Control's structured context, explicitly reporting location as unknown when only image evidence exists.
- [ ] Test old-result confirmation, search reset, simulator mode, phase transitions, and the absence of automatic guidance commands.
- [ ] Commit after mission-state regressions pass.

## Task 6: Validate the full system and document deployment

**Files:** Extend `swarm/sim.py` with opt-in real-image replay; create `tests/test_integration.py` and `docs/inference.md`; update README and CI.

- [ ] Replay target-present and absent sample images through `/ws/phone`, through the bridge/model API, back to the originating phone and console.
- [ ] Add a physical-phone test using distinct reference and live frames, documenting thresholds and failures rather than claiming accuracy from same-image crops.
- [ ] Use 30 simulated phones with a deliberately slow fake inference service to verify hub responsiveness, bounded queues, newest-frame replacement, and fair sampling.
- [ ] Run a separate measured GPU test for actual throughput, memory, frame age, and dropped-frame rate; do not infer 30-phone capacity from simulator or Mac timing.
- [ ] Stop/restart bridge and model server, disconnect/reconnect phones, rotate references, and ensure recovery or explicit unavailable state.
- [ ] Add separate lightweight hub and inference test jobs; run pretrained weight tests only as an opt-in job with model access/cache.
- [ ] Document the three launch commands, model cache volume, service secrets, CPU development, and GPU deployment.
- [ ] Review and commit the complete integration after all required checks pass.

## Delivery order and acceptance

Tasks 1-3 produce a working backend integration without changing how phones capture video.
Task 4 makes it usable inside the actual app.
Task 5 connects operator confirmation to mission state while preserving the unknown-location boundary.
Task 6 demonstrates that it works end to end and recovers from failure.

Done means an operator uploads a reference in `/console`, an existing phone finds a likely match in its stream, the correct feed displays it, and stale or unrelated results cannot change the search state.
Real-world target localization remains a distinct future positioning integration, not an implied output of OSNet.
