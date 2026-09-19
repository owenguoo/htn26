"""Launch the existing HTTP worker inside Baseten's custom-server container."""

import logging
import os
from pathlib import Path

import uvicorn


def main() -> None:
    os.environ["SWARM_API_KEY"] = Path("/secrets/beacon_worker_key").read_text().strip()
    # Ultralytics resolves its text encoder relative to the working directory.
    os.chdir("/app/data")
    import torch

    if not torch.cuda.is_available():
        raise RuntimeError("This deployment requires a CUDA GPU")
    logging.basicConfig(level=logging.INFO)
    logging.info("Inference GPU: %s", torch.cuda.get_device_name(0))
    uvicorn.run("beacon.api:create_app", factory=True, host="0.0.0.0", port=8001)


if __name__ == "__main__":
    main()
