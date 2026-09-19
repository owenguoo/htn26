# Live 3D scan (VGGT): handoff

## How it works now

- **Hub** (`swarm/mapper.py`):
  - Keeps a phone's frame only when that phone has turned 25° or moved 0.8 m since its last kept
    frame, and no kept frame already has nearly the same view. Sim phones and floor/ceiling shots
    are skipped, and the scan pauses in the Lobby phase.
  - Holds at most 32 frames. When full, it drops the view most similar to another, so run time
    stays flat however long the search runs.
  - After 6 new frames, it sends the whole set to the GPU worker.
  - Places the returned scan in room meters using phone headings and positions (`align()`), and
    keeps successive versions from jumping (`steady()`). The operator can also fit scale and
    rotation by hand from the 3D view.
  - Saves the scan and its frames to `web/models/live/`, so they survive a hub restart.
- **Worker** (`gpu/vggt_worker.py`, deployed to `/workspace/swarm-map-test/swarm-worker/` on the
  pod):
  - Same processing as `reconstruct.py`, but the model stays loaded.
  - Listens only on `127.0.0.1:8765` on the pod. The hub reaches it through an SSH tunnel it opens
    itself.
  - Levels the scene to gravity from the phones' motion sensors.
- **Operating it:** `scripts/gpu_worker.sh start|status|logs|stop`. Settings live in `.env`:
  `MAP_WORKER_SSH`, `MAP_WORKER_SSH_PORT` and `MAP_WORKER_PORT`. The pod's SSH port changes
  whenever it restarts; the current one is in `RUNPOD_TCP_PORT_22` on the pod.

## The contract (please keep it compatible)

```
POST /reconstruct
  body:   [uint32 BE header length][JSON header][JPEG bytes back to back]
  header: {"frames": [{"id": "k12", "size": 23411, "up": [x, y, z] | null}, ...], "maxPoints": 150000}
          up = gravity-up in that camera's axes (x right, y down, z forward), from the phone's motion sensors
  reply:  [uint32 BE header length][JSON metadata][GLB bytes (colored point cloud)]
  metadata: frames, points, inferenceSeconds, totalSeconds, leveledBy, medianDepth,
            cameras: [{id, position: [x, y, z], forward: [x, y, z]}],   <- the hub needs these, per frame id
            bounds
GET /health -> {ready, gpu, busy, runs}
```

Output convention:
- Y is up, leveled to gravity.
- The floor is near y = 0.
- Camera positions and directions must be in the same frame as the points.
- Units can be anything; the hub scales them.

Adding fields is fine: the hub ignores anything it doesn't know.

## Current numbers (A100)

- **Inference:** 0.2–1.2 s for 6–30 frames.
- **A full run:** 1.3–7.8 s. Most of it is point filtering and voxel downsampling on the pod's CPU.
- **Download:** the GLB is 1–2.4 MB and takes about 2 s through the tunnel.
- **GPU memory:** the worker holds about 7 GB.

## What's needed, most important first

1. **Real scale.** This is the biggest open problem. VGGT has no absolute scale. The hub currently
   guesses from camera height (assumes 1.45 m eye height), or from positions when frames come from
   3+ separate places. When people sit at a desk, the guess is 3–4× too big: we saw 18–27× scale
   factors. If the worker can return `metersPerUnit` (from a metric-depth model, a known-size
   object, or anything better), the hub will use it directly.
2. **Floor detection.** The floor is currently taken as the 2nd-percentile height, which picks up
   desks and tables. Fitting a plane to the gravity-leveled points (for example with RANSAC) and
   returning `floorY` would fix both the floor placement and the height-based scale.
3. **Speed.** Moving the filtering and downsampling onto the GPU (torch) should roughly halve a
   run. A smaller GLB would help too (fewer or quantized points), since the download is about 2 s.
4. **A consistent frame between runs.** Each run starts from scratch, so its coordinate frame
   differs from the last one. The hub compensates by lining up views the runs share, but a stable
   anchor frame across runs would remove the jitter entirely.
5. **Input quality.** Frames are currently 480 px wide at JPEG quality 0.5, taken straight from
   the live stream. If a different resolution or quality would help, say so and the phone can send
   a sharper still for each kept frame.
6. **Possible next step: phone positions from the scan.** The per-frame camera poses could place
   phones in the room instead of the tapped seats. That's the positioning work.

## Things to know

- **Level scan:** fixed by using phone gravity (`leveledBy: "gravity"`). Before that, phones
  pointing down tilted the whole scan.
- **`reconstruct.py`:** untouched. The worker is a separate file in its own folder.
