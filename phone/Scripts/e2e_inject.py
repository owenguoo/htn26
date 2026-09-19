"""Plays the operator: sends one command to a phone through the hub's own /ws/dashboard.

    uv run python phone/Scripts/e2e_inject.py --port 8077 --phone swarm-replay-e2e flash
    uv run python phone/Scripts/e2e_inject.py --port 8077 --phone swarm-replay-e2e focus   # → rate + hud

The hub accepts dashboard commands from the console origin, so this connects
with the same origin header as the browser console.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import websockets


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--phone", required=True)
    ap.add_argument("what", choices=("flash", "message", "focus", "ping"))
    ap.add_argument("--hold", type=float, default=0.5, help="seconds to keep the socket open")
    args = ap.parse_args()

    origin = f"http://127.0.0.1:{args.port}"
    async with websockets.connect(f"ws://127.0.0.1:{args.port}/ws/dashboard?role=console",
                                  max_size=None, origin=origin) as ws:
        if args.what == "flash":
            msg = {"type": "command", "target": args.phone,
                   "cmd": {"cmd": "flash", "color": "#ff5d73", "text": "e2e", "ttlMs": 1500}}
        elif args.what == "message":
            msg = {"type": "command", "target": args.phone,
                   "cmd": {"cmd": "message", "text": "e2e says hi", "ttlMs": 8000}}
        elif args.what == "ping":
            msg = {"type": "ping", "x": 1.0, "y": 4.0, "label": "e2e"}
        else:
            msg = {"type": "focus", "phoneId": args.phone}
        await ws.send(json.dumps(msg))
        # The hub answers a refused command with {"error": …}; silence would hide it.
        # Bounded by a deadline, not by quiet: the hub streams state at 10 Hz, so
        # waiting for the socket to go quiet waits forever.
        deadline = asyncio.get_running_loop().time() + 0.4
        while (remaining := deadline - asyncio.get_running_loop().time()) > 0:
            try:
                reply = await asyncio.wait_for(ws.recv(), timeout=remaining)
            except asyncio.TimeoutError:
                break
            if isinstance(reply, str) and reply.startswith('{"error"'):
                raise SystemExit(f"hub refused the command: {reply[:200]}")
        # Focus only lasts while this console is connected; hold it open to observe the boost.
        await asyncio.sleep(args.hold)


asyncio.run(main())
