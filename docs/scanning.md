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
