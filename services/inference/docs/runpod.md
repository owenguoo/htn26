# Runpod GPU worker

Run the existing YOLOE + OSNet API in its own Python 3.12 environment on a GPU pod.
The worker listens on loopback port 8002, separately from the 3D mapping workers.

## Install on the pod

Copy this service directory to `/workspace/beacon-inference`, excluding local environments, caches, artifacts, and secrets.
Install uv, then run:

```sh
cd /workspace/beacon-inference
uv sync --frozen --extra yolo --extra reid --no-dev --no-editable
```

Create `.env` with a randomly generated `SWARM_API_KEY` of at least 32 characters, and restrict its permissions with `chmod 600 .env`.
Use the same key as `SWARM_INFERENCE_API_KEY` in the hub's private `.env`.

```sh
nohup bash scripts/runpod-serve.sh > worker.log 2>&1 < /dev/null &
echo $! > worker.pid
```

Models download on first startup and remain under `/workspace/beacon-inference`, primarily in `.cache`.
The process survives SSH disconnects; run the start command again after a pod restart.
Check `worker.log` and `curl --fail http://127.0.0.1:8002/readyz` before switching the hub.
Reference embeddings are in memory and must be uploaded again after restarting the worker.

## Connect the hub

Use the pod's direct TCP SSH address from Runpod's Connect panel.
The basic `ssh.runpod.io` interactive connection is not used for port forwarding.

```sh
ssh -N -L 127.0.0.1:18002:127.0.0.1:8002 \
  -i ~/.ssh/beacon_scan_ed25519 -p 15429 \
  -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
  root@154.54.102.55
```

Set these values in the hub's ignored `.env`:

```dotenv
SWARM_INFERENCE_URL=http://127.0.0.1:18002
SWARM_INFERENCE_API_KEY=<the worker key>
SWARM_BASETEN_API_KEY=
```

The SSH tunnel must remain open while the hub uses Runpod.
Restart the hub and inference bridge after changing their environment.
The phone continues to connect to the hub; no iOS rebuild is required.

## Stop or roll back

Stop only this worker with `kill -TERM "$(cat worker.pid)"` from its directory after checking the PID belongs to Beacon.
Keep other GPU workers running.
To return to Baseten, restore the previous hub `.env` values and restart the local hub and bridge.
