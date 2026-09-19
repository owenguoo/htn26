# Swarm Sight

Audience phones stream their cameras into one hub. A command-center dashboard shows every
live feed and a floor plan with each phone's position and view cone.

## Run

```bash
uv sync
./scripts/make-cert.sh          # once: self-signed HTTPS so iPhones allow the camera on your Wi-Fi
uv run python -m swarm.hub      # dashboard: http://localhost:8000/dashboard
```

Phones: scan the QR code on the dashboard (or open `https://<laptop-ip>:8443/`), tap through the
certificate warning (Show Details → visit this website), tap **Join with camera**, allow camera +
motion, tap your spot on the map, then point at the stage and tap **calibrate**.

Fake phones for load testing: `uv run python -m swarm.sim --n 30` (Ctrl-C to stop; they vanish after 30 s).

### When the Wi-Fi blocks phone → laptop traffic (campus / venue networks)

Use a tunnel instead of the LAN URL:

```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:8000
uv run python -m swarm.hub --public-url https://<printed>.trycloudflare.com
```

You can also paste the URL into the join box on the dashboard; the QR code updates.

## Phone page options

`/?fps=2&w=480&q=0.6` sets frames/sec, frame width, and JPEG quality. `/?fake` sends a test
pattern instead of the camera (for laptops without a webcam).

## Interfaces for teammates

| Endpoint | Direction | Payload |
|---|---|---|
| `ws /ws/phone` | phone ↔ hub | JSON `hello`, `orient`, `seat`, `pong`; binary frames; hub sends `welcome`, `ping`, `command` |
| `ws /ws/frames?fps=5` | hub → inference / positioning | bridge bearer required; latest JPEG + versioned frame identity and captured pose (see inference guide) |
| `ws /ws/dashboard` | hub ↔ dashboard | `hello`, `state` at 10 Hz, binary thumbnails; accepts `command` |
| `POST /api/pose` | positioning → hub | bridge bearer required; `{phoneId, x, y, heading?, confidence?, source?}`; overrides the seat for 5 s |
| `POST /api/detections` | inference → hub | bridge bearer required; versioned source frame, reference, timing, and normalized scored boxes (see inference guide) |
| `GET /api/state` | anyone | current snapshot of all phones |

Binary frame format: `[uint32 big-endian header length][JSON header][JPEG]`. See `swarm/protocol.py`.

Coordinates: meters, stage at the top of the map. `x = 0` is stage center, `y = 0` is the stage
edge, `+y` goes toward the back. Heading is degrees, `0` = facing the stage, clockwise.
Room size lives in `room.json`.

Frames are held in memory only (latest per phone) and never written to disk.

## Inference service

Person search uses three processes: the hub, lightweight bridge, and isolated Python 3.12 YOLOE + OSNet worker.
Follow [deployment and verification](docs/inference.md) to configure the matching worker keys, operator login, cache, and CPU/GPU settings.
After that setup, run these in separate terminals from the repository root:

```bash
HF_HOME="$PWD/.cache/huggingface" SWARM_MODEL_CACHE="$PWD/.cache/models" OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 uv run --project services/inference --no-sync swarm-sight serve --host 127.0.0.1 --port 8001
uv run python -m swarm.hub
uv run python -m swarm.inference
```

Open `/console`, authenticate, upload a reference and select one person.
Likely matches carry separate detection scores and appearance similarities.
Operator confirmation establishes a visual sighting with unknown target position, without responder dispatch.
Use the explicit rehearsal control for simulated targets.
The 0.70 default is a test threshold, not calibrated identity confidence.
Physical-phone accuracy and cloud-GPU capacity remain unverified; reproducible acceptance steps are in the deployment guide.
