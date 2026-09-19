"""Fake phones for load-testing the hub and rehearsing without an audience.

Run:  uv run python -m swarm.sim --n 30
Each fake phone sits at a random seat and sweeps its heading back and forth. It turns
toward the sector the planner assigns it, and walks to a found candidate when it's
dispatched as a responder. It streams generated JPEG frames, answers clock-sync pings,
and turns its frames the flash color when the dashboard flashes it.
"""
from __future__ import annotations

import argparse
import asyncio
import io
import json
import math
import random
import ssl
import time

import websockets
from PIL import Image, ImageDraw, ImageFont

from .protocol import now_ms, pack

W, H = 320, 240
FONT_BIG = ImageFont.load_default(size=40)
FONT_SMALL = ImageFont.load_default(size=16)
BG = [(16, 22, 44), (24, 16, 40), (12, 30, 34), (34, 22, 16), (20, 20, 20)]


def render(index: int, heading: float, color: str | None, bg: tuple[int, int, int]) -> bytes:
    img = Image.new("RGB", (W, H), color or bg)
    d = ImageDraw.Draw(img)
    # the stage slides across the view as the heading changes (heading 0 = facing stage)
    rel = (heading + 540) % 360 - 180
    sx = W / 2 - rel * (W / 55)
    d.rectangle([sx - 110, 80, sx + 110, 130], fill=(43, 58, 110))
    d.text((sx, 105), "STAGE", fill=(200, 210, 255), font=FONT_SMALL, anchor="mm")
    for i in range(6):  # rows of seats ahead
        y = 150 + i * 16
        d.line([(0, y), (W, y)], fill=(40, 48, 80), width=2)
    d.text((12, 10), f"SIM #{index}", fill=(255, 255, 255), font=FONT_BIG)
    d.text((12, H - 26), time.strftime("%H:%M:%S") + f"  {heading:5.1f}°", fill=(180, 190, 220), font=FONT_SMALL)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=70)
    return buf.getvalue()


async def fake_phone(i: int, url: str, fps: float, rng: random.Random, ssl_ctx: ssl.SSLContext | None) -> None:
    pid = f"sim-{i:02d}"
    seat = {"x": round(rng.uniform(-8.5, 8.5), 2), "y": round(rng.uniform(3.5, 14), 2)}
    base = -math.degrees(math.atan2(seat["x"], seat["y"])) * 0.6  # roughly toward the stage
    amp, period, phase = rng.uniform(15, 55), rng.uniform(6, 14), rng.uniform(0, math.tau)
    bg = rng.choice(BG)

    # When the planner assigns a sector, turn toward it and scan around it;
    # otherwise sweep back and forth on our own.
    aim = {"heading": base % 360, "target": None, "until": 0.0}
    walk = {"distance": 0.0}  # responding to a found candidate: meters left to walk

    def heading() -> float:
        return aim["heading"]

    def step_heading() -> None:
        t = time.time()
        if aim["target"] is not None and t < aim["until"]:
            goal = aim["target"] + 12 * math.sin(t * 2.5 + phase)
            diff = (goal - aim["heading"] + 540) % 360 - 180
            aim["heading"] = (aim["heading"] + max(-9.0, min(9.0, diff))) % 360
        else:
            goal = base + amp * math.sin(t * math.tau / period + phase)
            diff = (goal - aim["heading"] + 540) % 360 - 180
            aim["heading"] = (aim["heading"] + max(-6.0, min(6.0, diff))) % 360

    while True:
        try:
            async with websockets.connect(url, ssl=ssl_ctx, max_size=None) as ws:
                await ws.send(json.dumps({"type": "hello", "phoneId": pid, "name": f"Sim {i}",
                                          "seat": seat, "sim": True, "ua": "swarm-sim"}))
                welcome = json.loads(await ws.recv())
                index = welcome.get("index", i)
                flash: dict = {"color": None, "until": 0.0}

                async def rx() -> None:
                    async for raw in ws:
                        msg = json.loads(raw)
                        if msg.get("type") == "ping":
                            await ws.send(json.dumps({"type": "pong", "ts": msg["ts"], "tp": now_ms()}))
                        elif msg.get("type") == "command" and msg.get("cmd") == "guide":
                            if msg.get("clear"):
                                aim["target"] = None
                                walk["distance"] = 0.0
                            elif msg.get("kind") in ("look", "go"):
                                if msg.get("heading") is not None:  # sims have no compass: room headings only
                                    aim["target"] = msg["heading"] % 360
                                    aim["until"] = time.time() + 3
                                    # "go": walk there (the hub clears the order on arrival)
                                    walk["distance"] = (msg.get("distance") or 0.0) + 1.0 if msg.get("kind") == "go" else 0.0
                            else:
                                aim["target"] = (aim["heading"] + msg["delta"]) % 360
                                aim["until"] = time.time() + 3
                                responding = msg.get("kind") == "respond"
                                walk["distance"] = (msg.get("distance") or 0.0) if responding else 0.0
                        elif msg.get("type") == "command" and msg.get("cmd") == "flash":
                            flash["color"] = msg.get("color") or welcome.get("color")
                            flash["until"] = time.time() + msg.get("ttlMs", 1500) / 1000

                async def orient() -> None:
                    while True:
                        step_heading()
                        if walk["distance"] > 1.0 and aim["target"] is not None:
                            # walk ~1.2 m/s along the direction the hub is steering us
                            step = min(0.12, walk["distance"] - 1.0)
                            b = math.radians(aim["target"])
                            seat["x"] = round(seat["x"] + step * math.sin(b), 3)
                            seat["y"] = round(seat["y"] - step * math.cos(b), 3)
                            walk["distance"] -= step
                            await ws.send(json.dumps({"type": "seat", "seat": seat}))
                        await ws.send(json.dumps({"type": "orient", "tCapture": now_ms(),
                                                  "heading": heading(), "pitch": 0, "calibrated": True}))
                        await asyncio.sleep(0.1)

                async def frames() -> None:
                    seq = 0
                    await asyncio.sleep(rng.uniform(0, 1 / fps))  # desync the swarm
                    while True:
                        hd = heading()
                        color = flash["color"] if time.time() < flash["until"] else None
                        jpeg = await asyncio.to_thread(render, index, hd, color, bg)
                        header = {"type": "frame", "seq": seq, "tCapture": now_ms(), "heading": hd,
                                  "pitch": 0, "calibrated": True}
                        await ws.send(pack(header, jpeg))
                        seq += 1
                        await asyncio.sleep(1 / fps)

                tasks = [asyncio.create_task(c()) for c in (rx, orient, frames)]
                done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
                for t in pending:
                    t.cancel()
                for t in done:
                    t.result()
        except (OSError, websockets.ConnectionClosed, websockets.InvalidStatus) as e:
            print(f"[{pid}] disconnected ({type(e).__name__}); retrying")
            await asyncio.sleep(1 + rng.random())


async def run(args: argparse.Namespace) -> None:
    ssl_ctx = None
    if args.url.startswith("wss://"):
        ssl_ctx = ssl.create_default_context()
        ssl_ctx.check_hostname = False
        ssl_ctx.verify_mode = ssl.CERT_NONE  # self-signed dev cert
    rng = random.Random(args.seed)
    print(f"Starting {args.n} fake phones → {args.url} at {args.fps} fps (Ctrl-C to stop)")
    await asyncio.gather(*(fake_phone(i + 1, args.url, args.fps, random.Random(rng.random()), ssl_ctx)
                           for i in range(args.n)))


def main() -> None:
    ap = argparse.ArgumentParser(description="Swarm Sight phone simulator")
    ap.add_argument("--n", type=int, default=20, help="number of fake phones")
    ap.add_argument("--fps", type=float, default=2)
    ap.add_argument("--url", default="ws://localhost:8000/ws/phone")
    ap.add_argument("--seed", type=int, default=7)
    try:
        asyncio.run(run(ap.parse_args()))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
