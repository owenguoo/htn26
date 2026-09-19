#!/usr/bin/env bash
# End to end against the real hub in this checkout: no mock, no second clone.
#
# Starts `swarm.hub` on a spare port, replays a recorded walk into it through
# SwarmClient (the same code the app runs, minus ARKit and the camera), and
# asserts what the hub's own /api/state says about the phone.
#
# Proves: protocol, framing, clock/latency, room-frame maths, commands, reconnect.
# Does not prove: anything ARKit. See DEVICE_CHECKLIST.md.
set -euo pipefail

cd "$(dirname "$0")/../.."          # repo root: the hub lives here
PORT="${E2E_PORT:-8077}"
PHONE="swarm-replay-e2e"
LOGS="$(mktemp -d)"
PIDS=()
cleanup() { for pid in "${PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT

swift build --package-path phone/Packages/SwarmCore --product swarm-replay >/dev/null
REPLAY="$(swift build --package-path phone/Packages/SwarmCore --show-bin-path)/swarm-replay"

uv run python -m swarm.hub --port "$PORT" --https-port 0 >"$LOGS/hub.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 40); do curl -sf "localhost:$PORT/api/room" >/dev/null && break; sleep 0.25; done
curl -sf "localhost:$PORT/api/room" >/dev/null || { echo "hub did not start"; cat "$LOGS/hub.log"; exit 1; }

replay() { "$REPLAY" --hub "http://localhost:$PORT/" --phone-id "$PHONE" --name e2e "$@" >"$LOGS/replay.log" 2>&1 & PIDS+=($!); REPLAY_PID=$!; }
assert() { uv run python phone/Scripts/e2e_assert.py --port "$PORT" --phone "$PHONE" "$@"; }
inject() { uv run python phone/Scripts/e2e_inject.py --port "$PORT" --phone "$PHONE" "$@"; }

echo "=== 1/5 marker-aligned phone looks like a slam phone to the hub ==="
replay
assert --alignment marker

echo "=== 2/5 a flash from the dashboard reaches the phone ==="
inject flash
assert --alignment marker --last-command flash

echo "=== 3/5 a console focusing the phone boosts its frame rate and gets its HUD ==="
inject focus --hold 6 &
assert --alignment marker --min-fps 5 --hud --timeout 8
wait $! || true

echo "=== 4/5 a reconnect inside 30 s keeps index and colour ==="
INDEX="$(assert --alignment marker --print-index)"
kill "$REPLAY_PID"; wait "$REPLAY_PID" 2>/dev/null || true
sleep 2
replay
assert --alignment marker --index "$INDEX"
kill "$REPLAY_PID"; wait "$REPLAY_PID" 2>/dev/null || true

echo "=== 5/5 no marker: unaligned sends no position; a seat tap does ==="
PHONE="swarm-replay-e2e-seat"
replay --no-markers
assert --alignment none
kill "$REPLAY_PID"; wait "$REPLAY_PID" 2>/dev/null || true
replay --no-markers --seat 2,6
assert --alignment seat

echo
echo "hub e2e green. None of this involved ARKit — see DEVICE_CHECKLIST.md."
