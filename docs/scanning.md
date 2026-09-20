# Room scanning

Run the hub with `uv run python -m swarm.hub`.
The console’s map card contains Start scan, Rebuild, and Reset scan controls.

Configure either `MAP_WORKER_URL` or `MAP_WORKER_SSH`, `MAP_WORKER_SSH_PORT`, and `MAP_WORKER_PORT` in the root `.env`, then restart the hub.
The SSH option forwards a local port to the GPU worker’s loopback listener.
Keep direct worker URLs on a trusted private connection; the worker has no authentication.

The GPU pod needs `/workspace/swarm-map-test/venv`, the VGGT-Omega source at `/workspace/swarm-map-test/vggt-omega`, and its checkpoint at `/workspace/swarm-map-test/model.pt`.
Install `gpu/requirements-surface.txt` in that worker environment alongside its existing VGGT dependencies.
Run `scripts/gpu_worker.sh start`, then `scripts/gpu_worker.sh status` to check readiness.
This service is separate from the Baseten person detector.

Join with the native iPhone app, leave Lobby, and select Start scan.
Move slowly around the room with overlapping views of textured walls and furniture.
Native iPhone frames are sampled at most twice per second.
Simulated cameras are excluded by default.
After six new accepted views, the hub requests reconstruction and the 3D mode loads the returned room geometry.
Rebuild requests an update using the current overlapping views.
Reset scan clears the active map and its view archive.

Selected images and generated geometry are saved under `web/models/live/` and restored when the hub restarts.
They are excluded from Git.
Scale is estimated from camera height or available phone positions, so reconstructed geometry is approximate.

## Waiting sweep sequences

Unmatched clear frames are also compared with up to eight neighboring waiting
views (pair results are cached). Connected waiting sequences stay eligible while
new matching views arrive: 20 seconds of component inactivity, with a hard
90-second age cap per image. The buffer holds at most 64 images; older components
are evicted first, with oversized components subject to the same bound. A sequence
still needs a verified visual connection to the accepted map before admission.
No pose-only or unconditional image admission is used. This preserves connecting
views through longer sweeps without admitting unrelated rooms or unbounded queues.
Expired images are not recoverable from the accepted-frame archive; testing this
change on a previously stalled area requires capturing that sweep again.

## Recovering a stalled first scan

Before a map exists, a seed with fewer than six accepted views can be replaced
by a waiting group of at least six distinct, visually connected views. The group
must pass the same sharpness, feature matching, geometry and spatial coverage
checks. Near-duplicates do not count toward the six views. Original seed views
stay in the bounded waiting buffer for a later bridge; disconnected groups are
never combined for reconstruction. This fallback is disabled while inference is
running or once a map/anchors exist.

`scan.selection.overlapChecks` counts uncached image-pair checks by failure
reason (descriptor matches, geometry, spatial coverage) and successful overlap.
These are pair counts, not rejected-frame counts. `scan.selection.bootstrap`
reports the replacement group's size and how many old views were deferred.
