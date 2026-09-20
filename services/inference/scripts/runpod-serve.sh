#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
set -a
source .env
set +a
export OMP_NUM_THREADS=2 MKL_NUM_THREADS=2
export SWARM_BACKEND=yoloe SWARM_ENABLE_REID=true SWARM_DEVICE=cuda:0
export SWARM_MODEL_CACHE="$PWD/.cache/models"
export HF_HOME="$PWD/.cache/huggingface"
export YOLO_CONFIG_DIR="$PWD/.cache/ultralytics"
exec .venv/bin/beacon serve --host 127.0.0.1 --port 8002
