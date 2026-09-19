# Person search deployment and verification

The hub, bridge, and YOLOE + OSNet worker are three independent processes.
The root project requires Python 3.11 or newer and has no Torch dependency.
The worker has its own Python 3.12 environment and lockfile under `services/inference`.
YOLOE detects people; OSNet compares appearance, not face identity.
The initial 0.70 similarity threshold is a test setting, not calibrated identity confidence.
An operator confirms a specific current sighting in `/console`.
Confirmation leaves the person's location unknown and does not dispatch responders.
Rehearsal remains an explicit separate console mode.

## Local CPU setup

Run every command below from the repository root, including the worker launch.
The worker reads `.env` from its process working directory; `uv --project` selects a project without changing that directory.
Add these entries to the root gitignored `.env`, substituting independently generated long random secrets.
`SWARM_API_KEY` and `SWARM_INFERENCE_API_KEY` must have the same value.
Do not put these values in browser JavaScript or URLs.

```dotenv
SWARM_API_KEY=replace-with-worker-secret
SWARM_INFERENCE_API_KEY=replace-with-worker-secret
SWARM_BRIDGE_KEY=replace-with-different-bridge-secret
SWARM_OPERATOR_CODE=replace-with-operator-login-code
SWARM_INFERENCE_URL=http://127.0.0.1:8001
SWARM_HUB_URL=http://127.0.0.1:8000
SWARM_BACKEND=yoloe
SWARM_ENABLE_REID=true
SWARM_DEVICE=cpu
```

Install both environments and generate the development camera certificate once:

```bash
uv sync --frozen
uv sync --frozen --project services/inference --extra yolo --extra reid
./scripts/make-cert.sh
```

Start each command in its own terminal, from the repository root:

```bash
# Terminal 1: worker, port 8001, first launch downloads model weights
HF_HOME="$PWD/.cache/huggingface" SWARM_MODEL_CACHE="$PWD/.cache/models" OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 uv run --project services/inference --no-sync swarm-sight serve --host 127.0.0.1 --port 8001

# Terminal 2: hub, HTTP 8000 and development HTTPS 8443
uv run python -m swarm.hub

# Terminal 3: bridge, connects to hub and worker over private service endpoints
uv run python -m swarm.inference
```

Wait for `curl --fail http://127.0.0.1:8001/readyz` to succeed.
Open `http://localhost:8000/console`, log in with the operator code, upload a reference, select exactly one detected person, and register it.
Join phones through the dashboard QR code over HTTPS, with camera permission.
The bridge samples each phone at one FPS; focused console video can run at eight FPS.
The bridge permits four global requests, at most one in flight and one latest pending frame per phone, with a default 64-phone admission bound (`SWARM_MAX_PHONES`, maximum 256).
Accepted results must be less than 1500 ms old and match the stream, search revision, reference version, dimensions, and monotonic result sequence.
A 30-phone fake-worker test does not establish 30-phone model capacity.

## GPU worker and persistent cache

Keep hub and bridge launch commands unchanged and set their `SWARM_INFERENCE_URL` to the private worker address.
Use HTTPS across untrusted networks and restrict the worker to hub/bridge access.
Build the worker from its own Docker context, then mount a named volume for model caches:

```bash
docker build -t swarm-inference services/inference
docker volume create swarm-model-cache
docker run --rm --gpus all --name swarm-inference -p 8001:8001 --mount source=swarm-model-cache,target=/data --env-file .env -e SWARM_BACKEND=yoloe -e SWARM_ENABLE_REID=true -e SWARM_DEVICE=cuda:0 swarm-inference
```

This requires a compatible NVIDIA GPU, driver, and container runtime.
For CPU Docker development, omit `--gpus all` and use `-e SWARM_DEVICE=cpu`.
The image runs as UID 1000; bind-mounted cache directories must be writable by that user.
The `/data` volume retains detector weights, Hugging Face weights, and Ultralytics configuration.
References and frames stay ephemeral in process memory and are not restored from that cache.
A worker restart loses the active reference; the operator must upload it again.
A hub restart also clears references, stream identities, and operator sessions.
The bridge reconnects with bounded backoff after transport loss.
Authenticated reference-health polling continues without frames and while paused; a silent bridge becomes unavailable after ten seconds.
A missing reference invalidates the hub reference rather than recreating it.

## Teammate API contract

`/ws/phone`, the phone page, and the read-only projector remain available without service keys.
Private frame subscribers use `Authorization: Bearer <SWARM_BRIDGE_KEY>` on `/ws/frames?fps=1`.
The same bearer is required for `POST /api/detections`, `POST /api/pose`, and bridge search/status calls.
Operators use same-origin HTTP-only session cookies for console controls.
The hub sends the worker key only to the configured inference service.

A frame packet retains the existing uint32-big-endian JSON-length, JSON-header, JPEG encoding.
Its header includes `phoneId`, `streamId`, `seq`, `t` (milliseconds), `width`, `height`, `searchRevision`, and the captured frame's `pose`.
Echo the frame identity exactly; `targetVersion` comes from authenticated `GET /api/search`.
Example detection callback body:

```json
{
  "phoneId": "phone-1", "streamId": "stream-token", "seq": 42,
  "t": 1789824000123, "width": 480, "height": 640,
  "searchRevision": "revision-token", "targetVersion": "worker-version",
  "boxes": [{"x": 0.1, "y": 0.2, "w": 0.3, "h": 0.5,
             "label": "person", "detectionScore": 0.91, "similarity": 0.78}],
  "queueMs": 0.0, "inferenceMs": 110.0, "matchingMs": 2.0
}
```

Boxes use normalized image coordinates; detector score and appearance similarity remain separate.
An empty `boxes` array clears the current overlay.
`POST /api/pose` retains `{phoneId, x, y, heading?, confidence?, source?}` for independently estimated phone position.
This does not estimate the target person's position.
The read-only worker `GET /v1/targets/active` requires its worker bearer and returns only target ID/version, or 404 when lost, 503 when matching/worker unavailable, and 401 for incorrect credentials.

## Reproducible checks

Ordinary CI separates lightweight hub/browser tests from lightweight inference API tests.
The manually dispatched `pretrained-models` job opts into model downloads and a persistent CI cache.
Local commands:

```bash
uv run python -m pytest tests -q
node --test tests/browser-inference.test.cjs
(cd services/inference && uv run python -m pytest -m 'not model' -q && uv run ruff check src tests)
```

The automated socket tests start isolated HTTP/WebSocket servers, avoid Mission Control calls, and cover phone-to-console delivery, reconnect identity, reference rotation/loss, idle and paused health, bad credentials, bridge stop/restart, and 30 concurrent phones against a deliberately slow fake model.
They assert queue bounds, fairness, newest-frame replacement, and hub responsiveness.
Use `uv run python -m pytest tests/test_integration.py -q -s` to print measurements.

Replay locally supplied images without changing the default generated simulator:

```bash
uv run python -m swarm.sim --n 1 --fps 2 --image /absolute/target-present.jpg --image /absolute/target-absent.jpg --image-seconds 3
```

For a real pretrained worker replay, start only the worker with the documented configuration.
The test launches an isolated hub and bridge and deletes its temporary `active` reference afterward, so use a dedicated worker with no operator search in progress.
Supply a reference, a target-present frame, a target-absent frame, and the reference person's pixel crop:

```bash
SWARM_REAL_E2E_URL=http://127.0.0.1:8001 SWARM_REAL_KEY=replace-with-worker-secret SWARM_REAL_REFERENCE=/absolute/reference.jpg SWARM_REAL_PRESENT=/absolute/present.jpg SWARM_REAL_ABSENT=/absolute/absent.jpg SWARM_REAL_BOX=50,398,247,903 uv run python -m pytest tests/test_integration.py -k pretrained_phone_replay -q -s
```

No photos or weights are checked into Git.
Same-image reference/replay checks validate plumbing only.
Real-world accuracy and GPU capacity require the separate trials below.

## Physical phone and GPU acceptance record

Physical-phone and cloud-GPU trials were not available during implementation and remain unverified.
For a physical trial, photograph a consenting participant for the reference, then use a distinct live camera frame with changes in viewpoint, lighting, distance, clothing occlusion, and background.
Include lookalikes, crowded frames, empty frames, and the participant leaving/re-entering view.
Record hardware, model versions, threshold, ground truth, detector score, similarity, misses, false matches, end-to-end frame age, and whether the correct phone and exact analyzed frame appear in the console.
Repeat at several thresholds before selecting a deployment threshold; do not report calibrated accuracy from same-image crops.
Confirm one current sighting and verify that the console reports unknown position without responder guidance.
Rotate the reference and reconnect the phone with sequence zero; ensure stale evidence cannot confirm the new search.

For GPU throughput, run the container on the actual deployment GPU, register the reference, then replay distinct real frames on 30 phones for at least five minutes with the simulator command above using `--n 30`.
Capture GPU memory/utilization with `nvidia-smi --query-gpu=timestamp,name,memory.used,utilization.gpu --format=csv -l 1`.
Collect capture/sampled/completed/accepted frame counts and p50/p95/p99 queue, inference, matching, and capture-to-accepted age from frame metadata and detection callbacks.
Report dropped-frame rate separately for unsampled, replaced, rejected stale, and failed requests, plus per-phone accepted rates and hub request latency.
Stop/restart the model and bridge independently and record time to unavailable and recovery, including explicit reference re-upload after model restart.
Do not infer GPU throughput, memory needs, or audience capacity from Mac CPU timings or the slow-fake-model test.

## Recorded local verification (2026-09-19)

On the development Mac, 30 real WebSocket clients sent 2,100 generated JPEG frames to the real hub and bridge against a fake HTTP model delayed by 350 ms per request.
The run issued 84 model requests, held at most 30 pending frames and four in-flight requests, sampled every phone two or three times, and measured a worst hub search response of 11.90 ms.
These are scheduling and responsiveness measurements, not model-capacity estimates.

A separate real CPU YOLOE + OSNet worker completed the automated full socket replay using a 480-pixel-wide resized public Ultralytics bus image and a target-absent crop.
The reference and present frame used the same image, so this establishes plumbing only.
The best appearance similarities were 0.991604 for present and 0.337989 for absent at threshold 0.70.
Capture-to-phone accepted ages were 151.59 ms and 891.16 ms, respectively, including bridge sampling delay.
The test also verified source phone/stream/revision identity, matching console evidence, and a fresh stream identity after phone reconnection.
Temporary hub/bridge test servers shut down automatically and the temporary worker reference was deleted.

Recovery verification kept a paused search healthy for more than ten seconds without any phone frames, then exercised worker-key failure/recovery, reference loss, reference rotation, bridge silence and restart, and explicit deletion.
Unit regressions additionally reject late health responses from a superseded search generation.
Real-browser console upload, person selection, focus/exact-frame preview, confirmation, unknown-position presentation, and explicit rehearsal reset were checked separately during integration.
The Node browser tests exercise logic and do not substitute for those browser checks.
An existing upstream Starlette/AnyIO deprecation warning remains visible in root tests; it does not affect test outcomes.
