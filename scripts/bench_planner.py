"""Time-to-find benchmark for the search planner, headless (no hub, no phones).

Phones stand at random spots in the room and search for a randomly placed candidate, using the same
probability map, detection model and planner as the hub. Modes:
    none    people look around on their own (heading drifts, now and then turns somewhere new)
    greedy  the original planner: most unsearched floor in camera reach (never asks anyone to walk)
    bayes   the Bayesian planner: most probability of finding per second, walking when it's worth it
"prior" places the candidate near a reported spot and tells the probability map so, like Mission
Control turning "last seen near X" into likelihood.

    uv run python scripts/bench_planner.py bayes uniform 40
    uv run python scripts/bench_planner.py bayes prior 40
"""
import json, math, random, statistics, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # run from anywhere
from swarm.coverage import Coverage, POD_MAX, look_quality
from swarm.planner import Planner

ROOM = json.loads((Path(__file__).resolve().parent.parent / "room.json").read_text())
HZ, CAP_S, PHONES = 5, 150, 5

def run(mode, seed, prior=False):
    rng = random.Random(seed)
    cov = Coverage(ROOM); pl = Planner(ROOM, cov); pl.enabled = mode != "none"; pl.mode = "bayes" if mode == "bayes" else "greedy"
    W, D = ROOM["width"] / 2, ROOM["depth"]
    phones = {f"p{i}": [rng.uniform(-W + 1, W - 1), rng.uniform(2, D - 1), rng.uniform(0, 360), None, 0] for i in range(PHONES)}
    if prior:  # "last seen near X": target within ~2 m of a reported spot, and the map is told so
        hx, hy = rng.uniform(-W + 2, W - 2), rng.uniform(2, D - 2)
        tx, ty = hx + rng.gauss(0, 1.5), hy + rng.gauss(0, 1.5)
        cov.adjust(5.0, hx, hy, 3.0)
    else:
        tx, ty = rng.uniform(-W, W), rng.uniform(0, D)
    half = ROOM["cameraFovDeg"] / 2
    walk = {}  # pid -> [x, y, start_after]
    for step in range(CAP_S * HZ):
        now = step * 1000 / HZ
        viewers = {pid: (p[0], p[1], p[2], 0.0) for pid, p in phones.items() if pid not in walk}
        cov.update(viewers)
        for pid, (x, y, h, _) in viewers.items():  # would this look spot the target?
            d = math.hypot(tx - x, ty - y); off = (math.degrees(math.atan2(tx - x, -(ty - y))) - h + 540) % 360 - 180
            if 0.5 < d <= ROOM["coneLength"] and abs(off) <= half and rng.random() < POD_MAX * look_quality(d, off, half):
                return step / HZ
        if mode == "none":  # wander: drift the heading, now and then turn somewhere new
            for p in phones.values():
                p[2] = (p[2] + (rng.uniform(-90, 90) if rng.random() < 0.03 else rng.gauss(0, 4))) % 360
            continue
        for pid, cmd in pl.tick(viewers, now):
            if cmd.get("cmd") == "guide" and "delta" in cmd:
                phones[pid][3] = cmd["delta"]
        for pid, wx, wy, _ in pl.walk_requests:
            walk[pid] = [wx, wy, now + 8000]
        pl.walk_requests.clear()
        for pid, p in phones.items():
            if pid in walk:
                wx, wy, t0 = walk[pid]
                if now >= t0:
                    d = math.hypot(wx - p[0], wy - p[1]); stepm = 0.8 / HZ
                    if d <= stepm: p[0], p[1] = wx, wy; del walk[pid]
                    else: p[0] += (wx - p[0]) / d * stepm; p[1] += (wy - p[1]) / d * stepm
                continue
            if p[3] is not None:  # turn toward the guide at 90°/s
                turn = max(-90 / HZ, min(90 / HZ, p[3])); p[2] = (p[2] + turn) % 360; p[3] -= turn
    return None

mode = sys.argv[1] if len(sys.argv) > 1 else "bayes"
prior = len(sys.argv) > 2 and sys.argv[2] == "prior"
times = [run(mode, s, prior) for s in range(int(sys.argv[3]) if len(sys.argv) > 3 else 40)]
found = [t for t in times if t is not None]
print(f"{mode:6s} {'with prior' if prior else 'uniform   '}: found {len(found)}/{len(times)}, median {statistics.median(found) if found else float('nan'):.0f}s, "
      f"mean {statistics.mean(found) if found else float('nan'):.0f}s (misses counted as {CAP_S}s: {statistics.mean([t or CAP_S for t in times]):.0f}s)")
