"""Stand-in for the mapping service, so the map UI can be built and rehearsed today.

A hidden "true" room layout (outer walls, a partition, a pillar, tables, a bar) is revealed
wherever phone cameras look: rays are cast across each phone's view cone, and whatever they hit
gets discovered. The result is posted to the hub's /api/map in the same format the real mapper
will use (walls, obstacles, occupancy grid, scan points).

Run:  uv run python -m swarm.mockmap          (alongside the hub and some phones or sims)
"""
from __future__ import annotations

import argparse
import json
import math
import time
import urllib.request
from pathlib import Path

ROOM = json.loads((Path(__file__).resolve().parent.parent / "room.json").read_text())
W, D = ROOM["width"], ROOM["depth"]
RANGE, FOV = ROOM["coneLength"], ROOM["cameraFovDeg"]
RAYS = 15          # rays per phone per scan
PIECE = 0.5        # walls are revealed in pieces this long
CELL = 0.5         # occupancy grid cell size

# the hidden layout (room meters: x left→right, y stage→back)
WALLS = [
    ((-W / 2, 0), (W / 2, 0)), ((W / 2, 0), (W / 2, D)), ((W / 2, D), (-W / 2, D)), ((-W / 2, D), (-W / 2, 0)),
    ((-4, 15), (-4, 10.5)), ((-4, 9), (-4, 6)),            # partition with a doorway at y 9–10.5
]
OBSTACLES = [
    ("pillar", [(1.7, 7.7), (2.3, 7.7), (2.3, 8.3), (1.7, 8.3)]),
    ("table", [(-7.5, 3), (-5.5, 3), (-5.5, 4), (-7.5, 4)]),
    ("table", [(4, 11), (6, 11), (6, 12), (4, 12)]),
    ("bar", [(8.6, 2), (9.6, 2), (9.6, 7), (8.6, 7)]),
]


def pieces(a, b):
    n = max(1, round(math.dist(a, b) / PIECE))
    return [((a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n),
             (a[0] + (b[0] - a[0]) * (i + 1) / n, a[1] + (b[1] - a[1]) * (i + 1) / n)) for i in range(n)]


def edges(poly):
    return [(poly[i], poly[(i + 1) % len(poly)]) for i in range(len(poly))]


# every surface a ray can hit: (segment, kind, index) where kind is "wall" (piece index) or "obstacle"
WALL_PIECES = [p for a, b in WALLS for p in pieces(a, b)]
SURFACES = [(seg, "wall", i) for i, seg in enumerate(WALL_PIECES)]
SURFACES += [(e, "obstacle", i) for i, (_, poly) in enumerate(OBSTACLES) for e in edges(poly)]


def cast(ox, oy, dx, dy):
    """Nearest hit along a ray within RANGE: (distance, kind, index) or None."""
    best = None
    for (a, b), kind, idx in SURFACES:
        ex, ey = b[0] - a[0], b[1] - a[1]
        den = dx * ey - dy * ex
        if abs(den) < 1e-9:
            continue
        t = ((a[0] - ox) * ey - (a[1] - oy) * ex) / den
        u = ((a[0] - ox) * dy - (a[1] - oy) * dx) / den
        if 0.05 < t <= RANGE and 0 <= u <= 1 and (best is None or t < best[0]):
            best = (t, kind, idx)
    return best


def merge_pieces(found: set[int]) -> list[dict]:
    """Join adjacent discovered pieces back into longer wall segments."""
    walls, run = [], None
    for i in sorted(found):
        a, b = WALL_PIECES[i]
        if run and math.dist(run[1], a) < 1e-6:
            run = (run[0], b)
        else:
            if run:
                walls.append(run)
            run = (a, b)
    if run:
        walls.append(run)
    return [{"a": list(a), "b": list(b), "confidence": 0.9} for a, b in walls]


def main() -> None:
    ap = argparse.ArgumentParser(description="Mock mapping service")
    ap.add_argument("--hub", default="http://localhost:8000")
    ap.add_argument("--hz", type=float, default=2)
    args = ap.parse_args()

    cols, rows = round(W / CELL), round(D / CELL)
    occ = ["u"] * (cols * rows)
    found_pieces: set[int] = set()
    found_obstacles: set[int] = set()
    points: list[list[float]] = []
    urllib.request.urlopen(urllib.request.Request(f"{args.hub}/api/map", method="DELETE"))
    print(f"mock mapper → {args.hub} at {args.hz} Hz (Ctrl-C to stop)")

    def mark(x, y, ch):
        c, r = int((x + W / 2) / CELL), int(y / CELL)
        if 0 <= c < cols and 0 <= r < rows and not (ch == "f" and occ[r * cols + c] == "o"):
            occ[r * cols + c] = ch

    while True:
        state = json.load(urllib.request.urlopen(f"{args.hub}/api/state"))
        for p in state["phones"]:
            pose = p.get("pose")
            if not p["connected"] or not pose or pose["heading"] is None:
                continue
            ox, oy = pose["x"], pose["y"]
            for k in range(RAYS):
                ang = math.radians(pose["heading"] - FOV / 2 + FOV * k / (RAYS - 1))
                dx, dy = math.sin(ang), -math.cos(ang)  # heading 0 = toward the stage (-y)
                hit = cast(ox, oy, dx, dy)
                reach = hit[0] if hit else RANGE
                for s in range(int(reach / (CELL / 2))):  # free space along the ray
                    mark(ox + dx * s * CELL / 2, oy + dy * s * CELL / 2, "f")
                if hit:
                    hx, hy = ox + dx * hit[0], oy + dy * hit[0]
                    mark(hx, hy, "o")
                    points.append([round(hx, 2), round(hy, 2)])
                    (found_pieces if hit[1] == "wall" else found_obstacles).add(hit[2])
        body = {
            "mode": "replace", "source": "mock-mapper",
            "walls": merge_pieces(found_pieces),
            "obstacles": [{"polygon": [list(v) for v in OBSTACLES[i][1]], "label": OBSTACLES[i][0], "confidence": 0.8}
                          for i in sorted(found_obstacles)],
            "occupancy": {"cols": cols, "rows": rows, "cell": CELL, "x0": -W / 2, "y0": 0, "cells": "".join(occ)},
            "points": points[-1500:],
        }
        req = urllib.request.Request(f"{args.hub}/api/map", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
        urllib.request.urlopen(req)
        time.sleep(1 / args.hz)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
