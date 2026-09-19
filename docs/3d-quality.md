# Live 3D quality test

Built from `live-3d-scan-and-vision` at `e08c9fc3e38d9113602013f938b51433a533dd5a` in the separate `larris/live-3d-quality` worktree. Existing reconstruction experiments and Owen's worker on port 8765 are unchanged. The test worker uses **8766**, with local SSH forwarding on **18766**.

## What changed

- The worker exports a **surface mesh** instead of disconnected dots. It checks each predicted depth against overlapping views, excludes discontinuities, fuses accepted depths with Open3D TSDF, removes small disconnected fragments, and limits the result to 300k triangles.
- Neighbor selection uses actual projected overlap. Physical proximity alone was discarding useful views of the same wall.
- Gravity remains the preferred leveling reference. Without gravity, a low horizontal plane can correct camera tilt. Floor detection is a heuristic; `floorBy` explicitly identifies the lower-bound fallback. Yaw follows the retained first keyframe, avoiding unstable shortest-arc rotations near upside-down camera coordinates.
- GLB vertex colors are converted from photograph sRGB into glTF's linear color space. The viewer displays captured colors without adding another layer of lighting.
- Standard Draco compression uses 14-bit positions and lossless byte colors. Its position error is much smaller than a fusion voxel. `KHR_materials_unlit` makes colors portable to other glTF viewers too.
- While scanning, phones send one 768px-wide JPEG at quality .88 per second. Other video frames retain the old resolution/quality. The hub retains each scan frame with its own pose/orientation snapshot. Old phone clients still work.
- The viewer frames the actual scan, offers top/cutaway views and an optional search heat overlay, applies manual fit changes immediately, and replaces completed scans atomically. It keeps the user's viewpoint on later batches and cancels animation when hidden. The scan's captured colors are the default; the heat overlay can be enabled explicitly.

The binary worker request/response contract is unchanged. `points` now counts mesh vertices; new fields include `faces`, `representation`, `colorSpace`, `compression`, `floorBy`, filter/fusion timing, and supported pixel counts. `--representation points` retains the original output path. Deploy the updated viewer before enabling surface output.

## Live visual frame selection

The hub now selects inputs using images instead of requiring a tapped position, heading,
or SLAM pose. Standard camera mode can contribute reconstruction frames while walking.
This does **not** add automatic movement to the phone markers. Without registration,
the map uses camera-height-based estimated scale and the dashboard labels it accordingly.

- Each phone retains at most four sharp capture candidates, expiring after 2.5 seconds.
  Approximately every two seconds the selector chooses its sharpest eligible candidate.
  Preview traffic cannot replace mapping candidates; older clients retain a preview fallback.
- Small grayscale copies (640px longest side) undergo exposure, blur, and texture checks.
  SIFT matches verified with homography/epipolar RANSAC establish overlap; matching points must span
  multiple image regions. Nearly identical views are rejected. Original JPEGs go to VGGT.
  These are conservative heuristics, not semantic foreground rejection or proof of accuracy.
- New phones must overlap the retained map. Phone and dashboard hints explain blur, duplicate
  views, missing overlap, and acceptance. No-overlap candidates expire rather than accumulating.
- The archive holds at most 96 connected accepted views. It protects the reference and the
  preceding batch, evicts redundant removable views, and retains connecting views. If a chain
  cannot be shortened safely, new additions are declined rather than disconnecting the map.
- Each worker batch contains at most 32 views: shared references, new views balanced across
  phones, and older coverage. Shortest paths through matching views preserve connections.
  This is view-based coverage, not a measured global spatial coverage guarantee.
- Six new views trigger a build. Once at least six views exist, smaller pending updates flush
  after ten seconds. One request runs at a time; selection continues during GPU work. Failed
  requests retain pending frames and back off ten seconds. There is no unbounded job queue.
- CPU selection runs off the WebSocket event loop. Selection latency is exposed as `selectionMs`.
  The archive, graph, and pending IDs persist with saved maps; descriptors are regenerated on load.

The model still reconstructs each batch from scratch and replaces the mesh. Persistent geometry
fusion, robust rejection of poorly aligned completed batches, and person masks remain future work.
The existing alignment smoothing remains in place; it is not a correctness gate.

For a repeatable test through the hub's binary frame ingestion and actual GPU worker, with two
replayed phone identities and no positions/headings:

```sh
python gpu/quality/replay_live.py --url http://127.0.0.1:18766 \
  --input .runtime/capture-4220-4241 --output .runtime/live-replay-new
```

Use a fresh output directory. This replay stores its own map and report and does not replace
`web/models/live`. It simulates phone arrivals using saved photos; real multi-phone Safari testing
is still necessary. Sparse photos with big viewpoint jumps can be rejected: live users should pan
slowly and capture intermediate overlapping views, especially when joining an existing scan.

## Run it

Deploy `gpu/vggt_worker.py`, `gpu/surface.py`, and `gpu/mesh_glb.py` together. Install `gpu/requirements-surface.txt` **inside a separate worker environment** that already has VGGT-Omega and its dependencies. Do not install into someone else's running experiment environment.

```sh
VGGT_ROOT=/path/to/vggt-omega OMP_NUM_THREADS=8 OPENBLAS_NUM_THREADS=8 \
  python gpu/vggt_worker.py --checkpoint /path/to/model.pt --port 8766
```

On the laptop, forward that worker and start this checkout:

```sh
ssh -N -i ~/.ssh/id_ed25519 -p 15429 \
  -L 18766:127.0.0.1:8766 root@154.54.102.55
MAP_WORKER_URL=http://127.0.0.1:18766 uv run python -m swarm.hub --host 127.0.0.1 --port 8110
```

The direct SSH host/port above were verified on Owen during this test and can change after a pod restart. The user-provided gateway `8xo3s1cf6q7ai8-6441209b@ssh.runpod.io` also works interactively with `ssh -tt`; it requires a PTY. The hub additionally supports `MAP_WORKER_LOCAL_PORT` so multiple checkouts do not compete for one tunnel port.

Open `/console`, select **3D**, and turn on **Live 3D scan** for new phone captures. iPhone camera capture still requires HTTPS. The local saved comparison is `/web/quality.html`.

## Reproduce the comparison

Input JPEGs and generated models are deliberately ignored by git. Keep originals unchanged. For the local test, `.runtime/capture` contains the previously converted IMG_4202–4217 photos.

```sh
python gpu/quality/replay.py --url http://127.0.0.1:18766 \
  --input .runtime/capture --output web/models/quality --batches 8,12,16
```

This saves each actual worker response, SHA-256, frame/triangle counts, worker timings, and laptop round-trip timings in `replay.json`. Upload/download time is included only in `roundTripSeconds`.

For a controlled geometry comparison, `gpu/quality/cache_baseline.py` takes a **saved copy of the original worker**, checkpoint, input directory, and output directory. It saves the prediction arrays plus original GLB. Its diagnostic cache write adds to timing; use `--no-cache` for a clean baseline timing. `gpu/quality/fuse_cached.py prediction.npz output-prefix` rebuilds surfaces from those exact predictions without another inference.

Place the baseline GLB/JSON at `web/models/quality/baseline.{glb,json}` and the chosen surface at `surface.{glb,json}` to populate the comparison page. Both sides use the same viewer, so it compares geometry/color rather than exaggerating the old viewer's shading problem.

To keep a new capture separate, use `--output web/models/quality/<capture-name>`, copy its `batch-N.glb` and `batch-N.json` to `surface.glb` and `surface.json` in that same folder, then open `/web/quality.html?scan=<capture-name>`. This shows the new capture on its own and preserves the original comparison and dashboard scan.

## Verification

Measured on Owen's A100 80GB with the 16 supplied room photos (September 19, 2026):

| Batch | Inference | Whole worker | Laptop round trip | GLB |
| --- | ---: | ---: | ---: | ---: |
| 8 views | 0.639 s | 3.244 s | 4.719 s | 623 KB |
| 12 views | 0.414 s | 4.832 s | 7.272 s | 683 KB |
| 16 views | 0.575 s | 7.056 s | 10.191 s | 673 KB |

These are individual runs, not latency percentiles. The original 16-view point-cloud worker took 4.95 s, producing 150k dots and a 2.4 MB file. The final surface contains 157,185 vertices / 300k triangles. Surface generation costs more CPU, but restores continuous surfaces and sends a smaller file. An earlier uncompressed surface was 6.14 MB; Draco reduced that payload by about 89%. The first surface prototype took 14.6 s of geometry processing; the selected version takes 5.98 s while retaining 3.51M cross-view-supported depth samples. The 16-view run peaked at 7.58 GiB of PyTorch allocations, not total device memory.

```sh
python -m unittest discover -s tests -v
# In the worker environment; no CUDA needed for these geometry tests:
OMP_NUM_THREADS=8 python gpu/quality/test_surface.py
node --check web/scene3d.js
node --check web/phone.js
```

Tests cover mismatched depths, discontinuity bridging, camera coordinate conventions, floor vs. table selection, color conversion, Draco geometry/color round trips, retained capture poses, legacy phone capture, stale frames, and anchor preservation. Browser checks cover actual GLB decoding, orbit/top/cutaway, dashboard fit controls, and switching 2D/3D.

## Limits

This is an observed surface reconstruction, not a watertight or photorealistic model. Moving people, glass, thin objects, and unseen areas can leave holes. It does not invent the missing geometry. Monocular scale still needs the existing phone-position registration or manual fit. The 16-photo check is one room; larger multi-phone captures may need different sampling and performance budgets. This change does not fix phone SLAM tracking or relocalization.

The implementation follows [Open3D RGB-D integration](https://www.open3d.org/docs/release/tutorial/pipelines/rgbd_integration.html) and the [glTF Draco extension](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_draco_mesh_compression).

Visual-selection verification (September 19, 2026): replaying IMG_4220–4241 through two
phone identities without poses accepted 7/22 images. The remaining frames were rejected
for sharpness or insufficient verified overlap. This conservative selection does not claim
full coverage of the original capture. Median selection time was 19.25 ms/frame, maximum
48.2 ms in this small archive. Real worker updates succeeded at 6 views (5.3 s round trip)
and 7 views (6.2 s). These are individual replay measurements, not a crowded live-phone test
or a latency guarantee at the 96-view archive limit.


## Native Beacon client integration

Integrated `origin/main` at `074f89a` (native ARKit/Swift app, latest hub frame identity,
reconnect handling, and inference controls) into the quality branch. Reconstruction and
visual selection remain on this branch.

The native client announces `native: true` and sends ordinary JPEG frame packets plus
separate `slam` pose messages. It does not send the browser-only `scanKeyframe` flag.
The hub now samples native frames into the same short candidate buffers at up to 1 Hz,
retaining the hub pose snapshot and frame heading. This uses the pose available when the
frame arrives, not a newly introduced capture-synchronized 6DoF protocol. Native JPEG
resolution/quality remain controlled by the app (the shared default is a 960px long edge
at quality 0.6). Reconnecting clears old capture buffers and stream identity.

ARKit tracks within a local coordinate frame. The Swift client sends room-relative `slam`
positions only when room alignment exists and the pose is not stale. Until then, images
can still build the visual map, but there is no registered phone marker. Use the native
app's seat/facing-stage calibration or its shared marker alignment, rather than assuming
independent ARKit origins coincide. Browser-only capture hints are not automatically native UI.

### Live capture continuity

Native JPEG candidates are sampled at up to 2 Hz. Every distinct eligible view
in the bounded capture window is considered in capture order, preserving bridge
angles during a sweep. Clear views without a map connection wait in memory for
up to 20 seconds (24 images maximum) and are retried against newly accepted
views. They enter reconstruction only after passing the existing geometric
overlap checks. Held images are discarded on restart/reset.

The console shows cumulative selection outcomes since hub restart/reset and
current overlap-buffer occupancy. `/api/state` → `scan.selection` also contains
the last 100 decisions, with phone IDs and timestamps. No rejected JPEGs are
persisted. This improves capture continuity, not batch alignment or fusion.
