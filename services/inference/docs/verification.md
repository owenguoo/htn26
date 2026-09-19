# Verification record

Verified locally on an Apple Silicon Mac using Python 3.12 and the committed uv lockfile.
No cloud resources were provisioned and no NVIDIA GPU was available.

## People matching verification

The people-only YOLOE + OSNet pipeline was verified on CPU with actual pretrained weights.
The full opt-in suite passes 63 tests; the gated SAM 3 test is skipped.
The regular suite passes 58 tests with warnings treated as errors, with six model tests skipped.
The real-model suite emits four upstream TorchScript deprecation warnings and does not suppress them.

The HTTP integration test registers a reference crop, matches a complete frame, checks an absent-target frame, deletes the reference, and verifies subsequent matching returns 404.
On the official bus sample, the beige-coated reference person scores 0.9952 cosine similarity, versus 0.5025 for the next candidate.
A crop containing a different person scores 0.3462 and returns `matched=false` at the illustrative threshold of 0.7.
This is a same-image integration check, not a measurement of cross-camera recognition accuracy.
Artifacts `person-match.json`, `person-match.jpg`, and `person-absent-match.json` preserve the local results.

Deterministic tests cover reference ambiguity, crop validation, finite embeddings and thresholds, capacity, authentication, shared upload bounds, immutable target versions during replacement/deletion, and cancelled inference retaining its model slot.
Review identified and fixed queue-key collisions across detection and matching routes.
Combined real-model testing identified Ultralytics' global Pillow patch converting invalid uploads into an optional HEIF dependency failure.
The service selects its JPEG/PNG decoders explicitly, with a regression test and passing combined HTTP tests.
The wheel includes the pinned OSNet architecture and MIT license.
The people-specific cloud GPU and container runtime have not been exercised; the container checks below cover the earlier detector service.

## Detector baseline checks

- Core/API/worker/CLI suite, including the installed SAM 3 postprocessor adapter: 24 passed, 4 opt-in pretrained-model tests skipped.
- Opt-in pretrained tests: YOLO-World, YOLOE, and persistent YOLO configuration passed (3 tests); SAM 3 skipped because model access is unavailable.
- Real-model checks include a two-image batch, a detected bus, bounded coordinates, and changing the vocabulary to person-only.
- A live Uvicorn process using real YOLO-World handled 50 concurrent HTTP requests with correct phone/frame metadata and a bus detection in every response.
- That one CPU burst completed in approximately 1.7 seconds after warmup; it is not a sustained capacity test.
- Ruff lint, Ruff formatting, dependency-lock consistency, and Python wheel/source-distribution builds passed.
- Linux ARM64 and AMD64 Docker images built successfully.
- The AMD64 image imported PyTorch, YOLO-World, YOLOE, and SAM 3 under emulation; its PyTorch build reports `2.10.0+cu128` and CUDA runtime `12.8`, with no GPU available on this host.
- The ARM64 image ran as the non-root `swarm` user, became ready, and detected a bus through its HTTP endpoint.
- A fresh-container warning exposed missing YOLO configuration-directory creation; a failing real-model test reproduced it, and the fix passes both the test and container verification.
- Shutdown testing verifies that the active batch finishes while waiting and late frames are rejected.
- A separate code review identified unnecessary SAM 3 mask allocation; the implementation uses the official detection-only postprocessor, with a regression test on original-image coordinate scaling and scores.
- Image-reference cleanup is tested both after completed inference and when a waiting request is cancelled during another active inference.

Local detailed outputs are under `artifacts/` and are intentionally ignored by git.
`http-smoke.json` records per-request timings from the live burst.
`comparison.json` and the individual backend reports preserve successful comparisons and the SAM 3 failure status.
`world-detect.jpg` is an annotated real detection preview.

## SAM 3 follow-up

After Hugging Face login, the actual SAM 3 checkpoint downloaded and ran successfully on CPU.
Its pretrained integration test passed, including two-image batches, coordinate bounds, and person-only prompt switching.
Text, visual exemplar, and SAM 3 plus OSNet experiments are recorded in [SAM 3 evaluation](sam3-evaluation.md).
The earlier gated-access failure recorded above is resolved.

## Not verified

CUDA execution, GPU memory headroom, and sustained 50-100 frames/second were not tested here.
Docker Desktop was started for the local container checks.
Docker's credential helper stalled on public base-image pulls; an isolated temporary Docker configuration without credentials allowed the build without changing the user's settings.
The Dockerfile and GPU verification commands are supplied in the README for execution on the cloud host.
The model download links and cloud driver compatibility must be reachable/compatible on that host.

Actual person-matching accuracy remains unmeasured until the team supplies reference photos and phone frames with varied viewpoints, lighting, occlusions, similar clothing, and absent-target scenes.
The bus sample verifies integration, not rescue suitability or target identity.

## Dependency notes

CLIP is pinned to a specific upstream git commit rather than allowing Ultralytics to install an unpinned dependency at inference time.
The lockfile selects PyTorch 2.10 and Torchvision 0.25 for both YOLO and SAM 3.
The dev environment uses HTTPX2 for Starlette's test client and bounds AnyIO below 4.15 to avoid Starlette 1.6's deprecated BlockingPortal alias.
Real YOLO smoke tests emit upstream TorchScript deprecation warnings while loading CLIP/MobileCLIP; the calls succeed, and warnings are not globally suppressed.
Core tests pass with warnings treated as errors.
