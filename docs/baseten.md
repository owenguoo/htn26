# Baseten GPU inference

The hub and phones keep running as before; YOLOE and OSNet run together on one Baseten L4 GPU.
The deployment uses the existing REST API through Baseten's `/sync` routes.
Model weights are downloaded when the image builds, and the worker uses its own virtual environment from `services/inference/uv.lock`.

## Deploy with the Baseten CLI

From the repository root, authenticate with `baseten auth login` if needed.
Store the worker's existing `SWARM_INFERENCE_API_KEY` as the Baseten secret `beacon_worker_key` using the interactive prompt:

```sh
baseten org secret set --name beacon_worker_key
baseten model push --dir services/inference --region us --environment production
```

The CLI returns the model ID and deployment ID.
Set replica bounds for each new deployment:

```sh
baseten model deployment update-autoscaling --model-id MODEL_ID --deployment-id DEPLOYMENT_ID --min-replica 1 --max-replica 1
baseten model deployment logs --model-id MODEL_ID --deployment-id DEPLOYMENT_ID --tail
```

Keep exactly one replica: the active reference embedding lives in worker memory.
A restart or redeployment requires uploading the reference again.
The hub rejects responses with an outdated reference version.
One warm replica incurs GPU usage while idle; deactivate the deployment when finished testing.

## Connect the hub

Create a model-scoped `workspace-invoke` API key in Baseten and store it only in the root `.env`.
If your account cannot create workspace keys, use a personal API key with inference access.
Do not commit it or put it in phone configuration.
Keep the worker and bridge keys already configured:

```dotenv
SWARM_INFERENCE_URL=https://model-MODEL_ID-region-us.api.baseten.co/environments/production/sync
SWARM_BASETEN_API_KEY=your-invocation-key
SWARM_INFERENCE_API_KEY=the-worker-secret-stored-in-baseten
```

Restart the hub and bridge to load these settings:

```sh
uv run python -m swarm.hub
uv run python -m swarm.inference
```

The hub sends the Baseten credential in `Authorization` and the worker credential in `X-Swarm-Api-Key`.
`X-Swarm-Content-Type` preserves the image type when the gateway rewrites the standard header.
Phone clients use the hub URL and never contact Baseten directly.
Upload a reference in `/console`, select the person, and connect a phone to verify live matching.
For a local worker, clear `SWARM_BASETEN_API_KEY` and restore `SWARM_INFERENCE_URL=http://127.0.0.1:8001`.

## Stop GPU usage

```sh
baseten model deployment deactivate --model-id MODEL_ID --deployment-id DEPLOYMENT_ID
```

Use `baseten model deployment activate` with the same IDs to resume, then upload the reference again.

## Verified deployment

Deployed with the Baseten CLI on 2026-09-19 in the Hack the North workspace:

- Model: `wgvz266w` (`beacon-yoloe-osnet`).
- Production deployment: `qe9xrz1`, one `L4:4x16` replica in `us`.
- [Deployment dashboard](https://app.baseten.co/models/wgvz266w/deployments/qe9xrz1).
- Hub endpoint: `https://model-wgvz266w-region-us.api.baseten.co/environments/production/sync`.

Real-image validation passed detection, reference registration/read/deletion, positive matching, and a blank-frame negative check.
Four warm matching requests took 98-147 ms round trip from this Mac; detection and OSNet processing in the last sample took about 14 ms and 20 ms respectively.
The first request was slower while additional model paths warmed up.
The phone/bridge/worker/console replay passed, including reconnection and the 1500 ms freshness limit.
A replayed phone frame through the running app returned its match in 127 ms.
These are functional smoke checks, not accuracy or multi-phone capacity benchmarks.

The local hub and bridge use the cloud worker through the ignored root `.env`.
Upload a fresh reference after restarting or redeploying.
The local CPU worker and superseded GPU deployment are stopped.
