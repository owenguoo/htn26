"""Stream every vision look as it happens, one line per look.

    uv run python scripts/watch_vision.py          # watch (turn Vision on in the console, or press V)
    uv run python scripts/watch_vision.py --on     # also turn Vision on while this runs, off on exit
"""
import argparse
import asyncio
import json
import time

import websockets

RED, YEL, DIM, RESET = "\033[31m", "\033[33m", "\033[2m", "\033[0m"


async def main(url: str, turn_on: bool) -> None:
    async with websockets.connect(url, max_size=None) as ws:
        if turn_on:
            await ws.send(json.dumps({"type": "vision", "enabled": True}))
        print(f"{DIM}watching vision looks at {url} (ctrl-c to stop){RESET}")
        try:
            async for raw in ws:
                if not isinstance(raw, str):
                    continue  # video thumbnails
                ev = json.loads(raw)
                if ev.get("type") != "look":
                    continue
                tag = ""
                if ev["urgent"]:
                    tag += f" {RED}⚠ URGENT: {ev['reason']}{RESET}"
                if ev["target"]:
                    tag += f" {YEL}TARGET {round(ev['confidence'] * 100)}%{RESET}"
                if ev["hint"]:
                    tag += f" {DIM}(checking a {round(ev['hint'] * 100)}% detection){RESET}"
                print(f"{DIM}{time.strftime('%H:%M:%S')}{RESET}  #{ev['index']:<2} {DIM}{ev['ms'] / 1000:.1f}s{RESET}  "
                      f"{ev['sees']}{tag}", flush=True)
        finally:
            if turn_on:
                await ws.send(json.dumps({"type": "vision", "enabled": False}))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="ws://localhost:8000/ws/console?thumb_fps=0.1")
    ap.add_argument("--on", action="store_true", help="turn Vision on while watching")
    a = ap.parse_args()
    try:
        asyncio.run(main(a.url, a.on))
    except KeyboardInterrupt:
        pass
