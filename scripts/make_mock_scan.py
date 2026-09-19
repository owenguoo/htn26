"""Make a stand-in for the VGGT reconstruction: a colored point cloud of the room, saved as GLB.

The real scan will come from VGGT (in its own coordinates; room.json's "scene" transform lines it
up). This one is built straight in room meters so the 3D console view has something to show:
floor, walls, the stage with a screen, rows of chairs with an aisle, a few round tables at the back.
A little noise, patchy density and holes make it look like a reconstruction rather than a model.

    uv run python scripts/make_mock_scan.py        # writes web/models/mock-room.glb

glTF axes: X = room x (right), Y = up, Z = room y (away from the stage), in meters.
"""
from __future__ import annotations

import json
import math
import random
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROOM = json.loads((ROOT / "room.json").read_text())
OUT = ROOT / "web" / "models" / "mock-room.glb"
WALL_H = 4.0
rng = random.Random(7)

points: list[tuple[float, float, float]] = []
colors: list[tuple[int, int, int]] = []


def add(x: float, h: float, y: float, rgb: tuple[int, int, int], jitter: float = 0.012, shade: int = 14) -> None:
    """One point at room (x, y), height h. Reconstructions are noisy and uneven: jitter both."""
    points.append((x + rng.gauss(0, jitter), h + rng.gauss(0, jitter), y + rng.gauss(0, jitter)))
    s = rng.randint(-shade, shade)
    colors.append(tuple(max(0, min(255, c + s)) for c in rgb))


def patch(n: int, sample, rgb, keep: float = 0.9, **kw) -> None:
    """Sample n points from a surface; drop some in clumps (holes where VGGT had no views)."""
    hole_seed = rng.random() * 100
    for _ in range(n):
        x, h, y = sample()
        if math.sin(x * 1.7 + hole_seed) * math.cos(y * 1.3 + h * 2.1 + hole_seed) > keep:
            continue
        add(x, h, y, rgb, **kw)


W, D = ROOM["width"] / 2, ROOM["depth"]
SW, SD = ROOM["stage"]["width"] / 2, ROOM["stage"]["depth"]
u = rng.uniform

# floor: carpet, a little darker toward the walls
patch(38000, lambda: (u(-W, W), 0.0, u(0, D)), (74, 62, 70), keep=0.97, shade=10)
# walls
patch(9000, lambda: (-W, u(0, WALL_H), u(-SD, D)), (150, 146, 138))
patch(9000, lambda: (W, u(0, WALL_H), u(-SD, D)), (150, 146, 138))
patch(9000, lambda: (u(-W, W), u(0, WALL_H), D), (140, 136, 130))
patch(8000, lambda: (u(-W, W), u(0, WALL_H), -SD), (120, 116, 112))
# windows on the right wall
for wy in (3, 7, 11):
    patch(900, lambda: (W - 0.02, u(1.2, 2.8), u(wy - 0.8, wy + 0.8)), (185, 205, 225), keep=1.1, shade=8)
# doors at the back
for dx in (-7, 7):
    patch(700, lambda: (u(dx - 0.9, dx + 0.9), u(0, 2.2), D - 0.02), (96, 70, 52), keep=1.1)
# stage: platform top and front face, 0.8 m high, plus a projection screen on the wall behind it
patch(9000, lambda: (u(-SW, SW), 0.8, u(-SD, 0)), (58, 44, 36), shade=8)
patch(3000, lambda: (u(-SW, SW), u(0, 0.8), 0.0), (40, 32, 28), shade=6)
patch(4000, lambda: (u(-3, 3), u(1.6, 3.6), -SD + 0.03), (205, 215, 235), keep=1.1, shade=6)
# a lectern
patch(500, lambda: (u(2.6, 3.2), u(0.8, 1.9), u(-0.9, -0.5)), (30, 30, 34), keep=1.1)

# chairs: rows from 2.5 m to 11.5 m, aisle down the middle
CHAIR = (48, 56, 84)
for row_y in [2.5 + i * 1.1 for i in range(9)]:
    x = -W + 1.4
    while x < W - 1.4:
        if abs(x) > 0.9 and rng.random() > 0.06:  # a few chairs missing, as in any real room
            cx, cy = x + rng.gauss(0, 0.03), row_y + rng.gauss(0, 0.03)
            patch(45, lambda: (u(cx - 0.22, cx + 0.22), 0.45, u(cy - 0.2, cy + 0.2)), CHAIR, keep=1.1)
            patch(40, lambda: (u(cx - 0.22, cx + 0.22), u(0.45, 0.9), cy + 0.22), CHAIR, keep=1.1)
            for lx, ly in ((-0.18, -0.16), (0.18, -0.16), (-0.18, 0.18), (0.18, 0.18)):
                patch(6, lambda: (cx + lx, u(0, 0.45), cy + ly), (30, 30, 30), keep=1.1, jitter=0.01)
        x += 0.62

# round tables at the back
for tx in (-6, -2.5, 2.5, 6):
    ty = 13.4
    def top():
        r, a = 0.75 * math.sqrt(rng.random()), rng.uniform(0, 2 * math.pi)
        return tx + r * math.cos(a), 0.75, ty + r * math.sin(a)
    patch(700, top, (225, 222, 215), keep=1.1, shade=8)
    patch(120, lambda: (tx + rng.gauss(0, 0.04), u(0, 0.75), ty + rng.gauss(0, 0.04)), (40, 40, 40), keep=1.1)

# ceiling lights as bright specks along the top of the walls (reconstructions catch these)
for lx in range(-8, 9, 4):
    patch(150, lambda: (lx + rng.gauss(0, 0.15), WALL_H - 0.05, u(1, D - 1)), (255, 244, 210), keep=1.1, shade=4)


def write_glb(path: Path) -> None:
    n = len(points)
    pos = b"".join(struct.pack("<3f", *p) for p in points)
    col = b"".join(struct.pack("<4B", *c, 255) for c in colors)
    lo = [min(p[i] for p in points) for i in range(3)]
    hi = [max(p[i] for p in points) for i in range(3)]
    gltf = {
        "asset": {"version": "2.0", "generator": "swarm-sight mock scan"},
        "scene": 0, "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "mock-scan"}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "COLOR_0": 1}, "mode": 0}]}],
        "buffers": [{"byteLength": len(pos) + len(col)}],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": len(pos)},
                        {"buffer": 0, "byteOffset": len(pos), "byteLength": len(col)}],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3", "min": lo, "max": hi},
            {"bufferView": 1, "componentType": 5121, "count": n, "type": "VEC4", "normalized": True},
        ],
        "extras": {"units": "meters", "frame": "room", "note": "mock stand-in for the VGGT scan"},
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    binary = pos + col
    binary += b"\0" * (-len(binary) % 4)
    body = (struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(binary), 0x004E4942) + binary)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)
    print(f"wrote {path.relative_to(ROOT)}: {n:,} points, {path.stat().st_size / 1e6:.1f} MB")


write_glb(OUT)
