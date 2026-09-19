#!/usr/bin/env bash
# Deploy / run the VGGT worker (gpu/vggt_worker.py) on the RunPod GPU. Reads MAP_WORKER_SSH and
# MAP_WORKER_SSH_PORT from .env (the port changes when the pod restarts: check RUNPOD_TCP_PORT_22).
#   scripts/gpu_worker.sh start    copy the worker up and (re)start it (loads the model, ~25 s)
#   scripts/gpu_worker.sh status   health check
#   scripts/gpu_worker.sh logs     tail its log
#   scripts/gpu_worker.sh stop
set -euo pipefail
cd "$(dirname "$0")/.."
eval "$(grep -E "^MAP_WORKER_[A-Z_]+=" .env | sed "s/^/export /")"
HOST="${MAP_WORKER_SSH:?set MAP_WORKER_SSH in .env}"; PORT="${MAP_WORKER_SSH_PORT:-22}"; WPORT="${MAP_WORKER_PORT:-8765}"
DIR=/workspace/swarm-map-test/swarm-worker
run() { ssh -o BatchMode=yes -o ConnectTimeout=15 -p "$PORT" "$HOST" "$@"; }
case "${1:-status}" in
  start)
    run "mkdir -p $DIR"
    scp -q -o BatchMode=yes -P "$PORT" gpu/vggt_worker.py "$HOST:$DIR/"
    # a pid file, not pkill -f: the pattern would also match this SSH session's own command line
    run "cd $DIR && { [ -f worker.pid ] && kill \$(cat worker.pid) 2>/dev/null; sleep 1; } ; (OMP_NUM_THREADS=8 MKL_NUM_THREADS=8 nohup ../venv/bin/python vggt_worker.py --port $WPORT > worker.log 2>&1 & echo \$! > worker.pid)"
    echo "starting (model load ~25 s)…"
    for _ in $(seq 60); do sleep 2; if run "curl -sf localhost:$WPORT/health" 2>/dev/null; then echo; exit 0; fi; done
    echo "worker didn't come up:"; run "tail -20 $DIR/worker.log"; exit 1 ;;
  status) run "curl -s localhost:$WPORT/health || echo 'worker not running'"; echo ;;
  logs)   run "tail -40 $DIR/worker.log" ;;
  stop)   run "cd $DIR && [ -f worker.pid ] && kill \$(cat worker.pid) 2>/dev/null && rm worker.pid && echo stopped || echo 'not running'" ;;
  *) echo "usage: $0 start|status|logs|stop"; exit 1 ;;
esac
