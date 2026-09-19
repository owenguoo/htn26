# Beacon inference

A standalone Python service that finds candidate matches for a reference person in phone camera frames.
It supports pretrained YOLO-World, YOLOE, and SAM 3 through one HTTP contract.
Phones send frames to your team's orchestrator, which calls this service and combines detections with positioning and target confirmation.

## What is implemented

- Reference-photo registration, versioned in-memory targets, and people-only appearance matching.
- Three selectable detector backends with text prompts and consistent pixel-coordinate bounding boxes.
- An authenticated FastAPI service with model warmup, health/readiness endpoints, and OpenAPI docs.
- One model worker, small batches, bounded uploads and queues, and replacement of stale pending frames from each phone.
- Image inference, annotated previews, warm-inference benchmarks, and sequential comparison across backends.
- Locked dependencies, automated tests, CI, and a GPU container definition.

The people-only pipeline uses YOLOE to detect people and OSNet to compare their appearance against a reference photo.
Results are ranked candidate matches, not confirmed identities.
OSNet describes visible appearance, including clothing, so changed clothes, occlusion, lighting, and similar outfits can cause errors.
VLM confirmation, phone capture, positioning, and orchestration belong to the other team components.

## Try it from your phone

Run `uv run --no-sync beacon demo --device cpu --port 8765` after installing the YOLO and re-identification extras.
The demo lets you upload a reference photo, choose a person, and send live camera frames for matching.
It prints an access code and serves the page at `http://localhost:8765/demo`.
Use an HTTPS tunnel to open the camera on your phone.
See [camera demo setup and testing](docs/camera-demo.md).

## Match a reference person

Install the people pipeline with `uv sync --frozen --extra yolo --extra reid`.
No training or gated account is needed.
OSNet downloads the authors' pinned pretrained MSMT17 checkpoint, approximately 17.3 MB, on first use.
YOLOE also downloads its detector and text encoder as described below.

```sh
uv run --no-sync beacon match artifacts/bus.jpg artifacts/bus.jpg \
  --reference-box 50 398 247 903 --similarity-threshold 0.7 --device cpu \
  --output artifacts/person-match.json --annotated artifacts/person-match.jpg
```

Replace the two image paths with your reference photo and a phone frame.
Omit `--reference-box` when the reference contains exactly one detected person.
Otherwise supply the intended person's `[left, top, right, bottom]` box in upright image pixels.
The pipeline detects people, crops each person, creates normalized 512-dimensional OSNet embeddings, and ranks their cosine similarity to the reference.
`detection_score` measures detection confidence; `similarity` measures appearance similarity and is not an identity probability.
The required `--similarity-threshold` controls whether the best candidate produces `matched=true`.
The example value `0.7` is an illustrative threshold, not a calibrated production setting.
Evaluate same-person and different-person pairs from your actual phones before choosing it.

For the people API, start with:

```sh
export SWARM_API_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
export SWARM_BACKEND=yoloe
export SWARM_ENABLE_REID=true
export SWARM_DEVICE=cpu
uv run --no-sync beacon serve
```

From another terminal using the same key, register a reference, then submit frames:

```sh
curl --fail-with-body -X PUT \
  -H "Authorization: Bearer $SWARM_API_KEY" -H 'Content-Type: image/jpeg' \
  --data-binary @artifacts/bus.jpg \
  'http://127.0.0.1:8001/v1/targets/demo?box=50&box=398&box=247&box=903'
curl --fail-with-body \
  -H "Authorization: Bearer $SWARM_API_KEY" -H 'Content-Type: image/jpeg' \
  --data-binary @artifacts/bus.jpg \
  'http://127.0.0.1:8001/v1/match?target_id=demo&phone_id=phone-1&frame_id=frame-1&captured_at=1750000000&similarity_threshold=0.7'
curl --fail-with-body -X DELETE \
  -H "Authorization: Bearer $SWARM_API_KEY" \
  'http://127.0.0.1:8001/v1/targets/demo'
```

Registration stores only the embedding, with up to 32 targets per process.
Replacing a reference returns a new `target_version`; in-flight matches retain the version they started with.
The orchestrator should reject results whose version no longer corresponds to its search.
Targets disappear on server restart and must be registered again.
Matching returns ranked `candidates`, `matched`, `similarity_threshold`, image dimensions, phone/frame metadata, and timing fields.
All candidates are returned even when none reaches the threshold.
The shared request bounds and deadlines below cover registration and matching too.
Timed-out OSNet work holds its model slot until it finishes, preventing an unbounded backlog of background inference threads.

## Local setup

Install [uv](https://docs.astral.sh/uv/getting-started/installation/) if needed, then run from this directory:

```sh
uv sync --frozen --extra yolo --extra reid
mkdir -p artifacts
curl -fL https://raw.githubusercontent.com/ultralytics/assets/main/im/bus.jpg -o artifacts/bus.jpg
uv run --no-sync beacon detect artifacts/bus.jpg \
  --backend yolo-world --device cpu --labels bus person \
  --output artifacts/detections.json --annotated artifacts/detections.jpg
```

Python 3.12 is selected automatically.
The first inference downloads the selected checkpoint and text encoder.
YOLO-World and YOLOE need no account or training.
The two detector checkpoints are approximately 25 MB each, with additional CLIP and MobileCLIP downloads of approximately 338 MB and 572 MB respectively.
Dependency installation, including PyTorch, requires additional disk space.
Use `--device cuda:0` on the GPU server or explicit `--device mps` to experiment on Apple Silicon.
`auto` selects CUDA when available and otherwise CPU; it does not silently fall back when you explicitly request CUDA.

For just API development without ML dependencies, use `uv sync --frozen` and `uv run pytest`.
Use `uv run --no-sync` after installing all extras to preserve that environment.

## Run the API

```sh
export SWARM_API_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
export SWARM_BACKEND=yolo-world
export SWARM_DEVICE=cpu
uv run --no-sync beacon serve
```

Use `SWARM_BACKEND=yoloe` or `SWARM_BACKEND=sam3` to select another model.
The service loads and warms up the selected model before accepting traffic.
Startup intentionally fails when model weights, dependencies, or the requested device are unavailable.
The initial warmup also downloads YOLO's text encoder, avoiding that download on the first real request.

- `GET /healthz`: the HTTP process is responding.
- `GET /readyz`: the initialized model worker is running.
- `GET /docs`: interactive API documentation with bearer authorization.
- `POST /v1/detect`: a raw JPEG or PNG body.

From another terminal, set the same API key and send a frame:

```sh
curl --fail-with-body \
  -H "Authorization: Bearer $SWARM_API_KEY" \
  -H 'Content-Type: image/jpeg' \
  --data-binary @artifacts/bus.jpg \
  'http://127.0.0.1:8001/v1/detect?phone_id=phone-1&frame_id=frame-42&captured_at=1750000000.123&labels=bus&labels=person&confidence=0.25'
```

`captured_at` is the phone's capture timestamp in Unix seconds; the server echoes it without assuming synchronized phone clocks.
The orchestrator must retain the corresponding sensor snapshot and query identity with each frame.
Use unique frame IDs and repeat `labels` for multiple prompts.
IDs allow ASCII letters, digits, underscore, period, colon, and dash, with a maximum of 128 characters.
Prompts are trimmed, deduplicated in order, and limited to 16 labels of 80 characters each.

Example response:

```json
{
  "phone_id": "phone-1",
  "frame_id": "frame-42",
  "captured_at": 1750000000.123,
  "backend": "yolo-world",
  "width": 810,
  "height": 1080,
  "detections": [
    {"label": "bus", "score": 0.89, "box": [15, 225, 798, 741]}
  ],
  "queue_ms": 10.2,
  "inference_ms": 43.8
}
```

Boxes are `[left, top, right, bottom]` in pixels of the upright, EXIF-corrected image, clipped to the returned width and height.
For phone frames captured from a canvas, these are the canvas coordinates.
`inference_ms` is the duration of the entire batch containing that frame, including prompt updates and result conversion; it is not a per-frame amortized time.
`queue_ms` starts after image decoding.
The API does not write received frames to disk and clears the predictor's retained image references after each call.
Memory allocators may retain freed storage; this is not cryptographic memory erasure.
CLI annotated images are intentionally written only when requested.

## Multiple phones and overload

Use one server process per GPU allocation, with one model instance per process.
Do not increase Uvicorn worker count to scale a single GPU; each process would load another model.
The worker batches frames only when their ordered labels and confidence threshold match.
Repeated common search prompts therefore batch best.
Keep the vocabulary order stable across phone requests.

The worker holds at most one waiting frame per phone plus the active inference batch.
A newer arrival replaces a waiting frame while preserving that phone's position in the queue.
An active GPU inference cannot be cancelled safely, so it finishes even if the HTTP request times out.
Replacement is by server arrival order, not client timestamps; the orchestrator should discard late or stale results using frame IDs.
Avoid blindly retrying stale frames.

| HTTP status | Meaning | Client action |
| --- | --- | --- |
| 200 | Inference completed, possibly zero detections | Consume matching frame metadata |
| 401 | Missing or incorrect bearer token | Fix credentials |
| 409 | A newer pending frame replaced this one | Drop this frame |
| 413 | Upload exceeds the byte limit | Resize/compress before sending |
| 415 / 422 | Unsupported media or invalid input | Fix payload/query |
| 429 | Upload or queue capacity reached | Back off, then send a fresh frame |
| 503 | Inference failed | Inspect server logs and send a fresh frame |
| 504 | Upload, decoding, or inference exceeded the deadline | Drop the stale result |

The API accepts at most 64 simultaneous requests by default and 2 MB / 4 million pixels per frame.
For the demo, resize phones' long edge to approximately 640 pixels and send 1-2 fps.
GPU scheduling and image decoding run off the event loop.
The service key belongs in the trusted orchestrator, not public phone JavaScript.
Expose the service through your cloud provider's HTTPS/private-network gateway with request size and rate limits.
No CORS policy is enabled because the intended caller is the server-side orchestrator.

Configuration uses `SWARM_*` environment variables or a local `.env` file:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SWARM_API_KEY` | required, at least 16 characters | Service bearer secret |
| `SWARM_BACKEND` | `yolo-world` | `yolo-world`, `yoloe`, or `sam3` |
| `SWARM_DEVICE` | `auto` | `cpu`, `mps`, `cuda:0`, or `auto` |
| `SWARM_ENABLE_REID` | `false` | Enable people matching; requires `yoloe` |
| `SWARM_REID_MODEL` | pinned author checkpoint | Trusted local OSNet checkpoint override |
| `SWARM_MODEL` | backend checkpoint | Trusted model override |
| `SWARM_BATCH_SIZE` | `4` | Maximum frames per inference batch |
| `SWARM_QUEUE_CAPACITY` | `64` | Maximum pending phones |
| `SWARM_MAX_UPLOADS` | `64` | Maximum concurrent requests |
| `SWARM_MAX_BYTES` | `2000000` | Compressed upload limit |
| `SWARM_MAX_PIXELS` | `4000000` | Decoded image limit |
| `SWARM_TIMEOUT_SECONDS` | `30` | Request deadline |
| `SWARM_MODEL_CACHE` | `.cache/models` | YOLO detector checkpoint cache |

Start SAM 3 with `SWARM_BATCH_SIZE=1` and increase only after measuring GPU memory usage.
SAM 3 reuses vision embeddings across labels, but each extra label still adds inference work.
The server emits boxes only; it avoids materializing full-resolution segmentation masks.

## SAM 3 access

SAM 3 has been downloaded and tested locally with text and visual prompts.
See the [evaluation results](docs/sam3-evaluation.md) for examples, CPU timings, reference-matching limits, and reproduction commands.

1. Request/accept access at [facebook/sam3](https://huggingface.co/facebook/sam3) using your Hugging Face account.
2. Create a read token with access to that gated repository.
3. Set `HF_TOKEN` in the shell or your cloud secret manager, or run `.venv/bin/hf auth login` locally.
4. Run a real test:

```sh
uv run --no-sync beacon detect artifacts/bus.jpg \
  --backend sam3 --device cuda:0 --labels bus person \
  --output artifacts/sam3.json --annotated artifacts/sam3.jpg
```

A token alone is insufficient until the account has model access.
Do not put tokens in source control or Docker build arguments.
SAM 3 uses Transformers' `Sam3Model` and `Sam3Processor`; no research-repository checkout is needed.

## Cloud GPU deployment

Deploy the hosted worker with the [Baseten CLI instructions](../../docs/baseten.md), or use the generic Docker setup below.
Use an NVIDIA Linux GPU host with a compatible driver and NVIDIA Container Toolkit.
The locked Linux PyTorch build supplies CUDA libraries; confirm driver compatibility on the selected host.
Check actual available memory before raising batch size or running multiple services.

```sh
docker build -t beacon .
docker run --rm --gpus all --entrypoint python beacon \
  -c 'import torch; print(torch.__version__, torch.version.cuda); assert torch.cuda.is_available(); print(torch.cuda.get_device_name())'
docker run --rm --gpus all -p 127.0.0.1:8001:8001 \
  -e SWARM_API_KEY -e SWARM_BACKEND=yoloe -e SWARM_ENABLE_REID=true \
  -v beacon-data:/data beacon
```

The image runs as a non-root user and defaults to `cuda:0`.
The `/data` volume persists detector weights, text encoders, and Hugging Face downloads across restarts.
For SAM 3, add `-e SWARM_BACKEND=sam3 -e SWARM_BATCH_SIZE=1 -e HF_TOKEN` to the run command.
Bind through the provider's secure ingress when calling remotely.
Linux ARM64 and AMD64 images were built locally.
The ARM64 image was tested with real CPU inference as the non-root user.
CUDA execution still requires a cloud GPU; see [verification](docs/verification.md).

## Compare models and validate

Run every backend sequentially on the same images, freeing process GPU memory between backends:

```sh
uv run --no-sync beacon compare artifacts/bus.jpg \
  --labels bus person --device cuda:0 --batch-size 1 --warmup 2 --runs 20 \
  --output artifacts/comparison.json
```

Use `--backends yolo-world yoloe` when SAM 3 access is not yet available.
The command writes an individual report for each successful backend and an aggregate report, and exits nonzero if any backend fails.
Reports include versions, cold model load time, warm batch p50/p95, throughput, and sample detections.
Prompt encoding for the selected labels occurs during warmup, outside the measured warm latency.
These measurements exclude networking, queueing, decoding, and VLM confirmation.
They do not establish detection accuracy or promise support for 50 phones.
Use representative room images, small/occluded targets, empty scenes, and confusing distractors before choosing the final model or threshold.
Scores are model-specific and are not interchangeable calibrated probabilities.

```sh
uv run --no-sync ruff check .
uv run --no-sync ruff format --check .
uv run --no-sync pytest -q -W error
SWARM_TEST_MODELS=yolo-world,yoloe SWARM_TEST_DEVICE=cpu \
  uv run --no-sync pytest tests/test_models.py -q
SWARM_TEST_REID=1 uv run --no-sync pytest tests/test_osnet.py tests/test_person_models.py -q
# After SAM 3 authorization, set SWARM_TEST_MODELS=yolo-world,yoloe,sam3 on the GPU host.
```

Normal tests use deterministic inference at the model boundary and exercise real HTTP handling, decoding, queueing, and response serialization.
The optional SAM adapter test uses the installed Transformers postprocessor with synthetic model outputs; it is not pretrained SAM 3 validation.
The real-model suite downloads/loads actual weights and checks detections, batches, coordinates, and prompt changes on the bus image.

## Model sources and licenses

- [YOLO-World](https://docs.ultralytics.com/models/yolo-world/): `yolov8s-worldv2.pt`.
- [YOLOE](https://docs.ultralytics.com/models/yoloe/): `yoloe-11s-seg.pt`.
- [OSNet](https://huggingface.co/kaiyangzhou/osnet): OSNet x1.0 trained on MSMT17; vendored architecture includes its MIT license and pinned provenance in [implementation notes](docs/osnet-implementation.md).
- [SAM 3 through Transformers](https://huggingface.co/docs/transformers/model_doc/sam3): `facebook/sam3`.

Ultralytics code/weights and Meta's gated weights retain their respective upstream license terms.
Review those terms before distributing or commercializing the project.
