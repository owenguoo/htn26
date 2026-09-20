"""Rescue simulator: play out a search of a scanned building before anyone walks into it.

An environment is a floor plan on a grid (walls, furniture, doors, entries), usually traced from
a 3D scan. A run drops a casualty somewhere on the floor, sends a team in through an entry, and
steps the world forward: rescuers walk (around walls), look (not through them), and the same
Bayesian search map the live hub keeps (swarm/coverage.py) decides where each of them goes next,
with the same objective the live planner uses (swarm/planner.py): probability of a find bought
per second, assigned greedily so rescuers spread out instead of piling onto one room.

The live Coverage and Planner assume one open hall. This is their model with walls in it: looks
are cut off by line of sight, walking costs the length of the real path, and rescuers move at a
walk instead of being seated audience members. The detection constants are imported from the live
modules, so tuning the hub retunes the simulator.

Run one:    uv run python -m swarm.simulator run --env apartment --rescuers 3
Run many:   uv run python -m swarm.simulator batch --env eng-floor --rescuers 1,2,4,6 --runs 40
"""
from __future__ import annotations

import argparse
import heapq
import json
import math
import os
import re
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .coverage import HEAT_LEVELS, POD_FALLOFF_M, POD_MAX
from .planner import DONE_SHARE, DWELL_S, HEADINGS, TURN_DEG_PER_S, UPDATES_PER_S

ROOT = Path(__file__).resolve().parent.parent
ENVS = ROOT / "web" / "sim" / "envs"
USER_ENVS = ENVS / "user"          # created in the console (scan imports, edits); not in git

FREE, LOW, WALL, VOID, FIRE, SMOKE, DOOR = 0, 1, 2, 3, 4, 5, 6  # LOW = furniture: you walk around it but see over it
# VOID = not part of the building (or not scanned). Hazards are drawn in the plan editor:
# FIRE nobody walks through; SMOKE you can cross, slowly, and can barely see into or out of.
# DOOR is open floor that marks a doorway: it is what divides the plan into rooms (swarm/command_sim.py).
GRID_CHARS = {".": FREE, "o": LOW, "#": WALL, " ": VOID, "f": FIRE, "s": SMOKE, "d": DOOR}
SMOKE_SLOW = 2.5                   # crossing smoke takes this many times longer (crouched, feeling along a wall)
SMOKE_POD = 0.3                    # a look into or out of smoke is this much as likely to spot someone
MAX_CELLS = 40_000                 # a floor bigger than this needs a coarser cell
ANCHOR_M = 2.0                     # vantage points to walk to are spread about this far apart
WALK_M_PER_S = 1.2                 # a careful walk through an unfamiliar building
FACE_DEG_PER_S = 240               # turning to face where you're walking
ARRIVE_M = 1.0                     # a responder this close to the casualty has reached them
MIN_VALUE = 1e-5                   # a look expected to buy less than this isn't worth planning
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")


def look_quality(d: np.ndarray, off_deg: np.ndarray, half_fov: float) -> np.ndarray:
    """swarm.coverage.look_quality over arrays (tests hold the two to the same numbers)."""
    edge = np.minimum(1.0, np.abs(off_deg) / half_fov)
    return np.exp(-d / POD_FALLOFF_M) * (0.3 + 0.7 * np.cos(edge * np.pi / 2))


def turn_between(a: float, b) -> np.ndarray | float:
    """Signed degrees from heading a to heading b, in -180..180."""
    return (b - a + 540) % 360 - 180


# ---------------------------------------------------------------- environment
class Environment:
    """A floor plan. Meters, origin at the top-left corner of the plan: +x right, +y down the page.
    Headings as everywhere else in Beacon: degrees, 0 = up the page (-y), clockwise."""

    def __init__(self, spec: dict) -> None:
        self.spec = spec
        self.id = spec["id"]
        self.name = spec.get("name", self.id)
        self.cell = float(spec["cell"])
        rows = spec["grid"]
        self.rows, self.cols = len(rows), len(rows[0]) if rows else 0
        if not self.rows or not self.cols or any(len(r) != self.cols for r in rows):
            raise ValueError("grid must be a non-empty rectangle of rows")
        if self.rows * self.cols > MAX_CELLS:
            raise ValueError(f"grid is over {MAX_CELLS} cells: use a larger cell size")
        if not 0.1 <= self.cell <= 2:
            raise ValueError("cell size must be between 0.1 and 2 m")
        try:
            self.grid = np.array([[GRID_CHARS[ch] for ch in row] for row in rows], np.uint8)
        except KeyError as e:
            raise ValueError(f"grid has an unknown cell {e.args[0]!r}: use . o # d f s or a space") from None
        self.width, self.depth = self.cols * self.cell, self.rows * self.cell
        self.range = float(spec.get("rangeM", 5.0))
        self.fov = float(spec.get("fovDeg", 55.0))
        self.smoke = (self.grid == SMOKE).ravel()
        self.clear = ((self.grid == FREE) | (self.grid == DOOR)).ravel()
        self.walkable = self.clear | self.smoke
        self.opaque = self.grid == WALL
        self._neighbors = self._build_neighbors()
        self.entries = []
        for e in spec.get("entries") or []:
            c = self.nearest_walkable(float(e["x"]), float(e["y"]))
            if c is not None:
                self.entries.append({"name": e.get("name", "Entry"), "cell": c, "x": e["x"], "y": e["y"]})
        if not self.entries:
            raise ValueError("an environment needs at least one entry on walkable floor")
        # the floor that counts: what someone walking in through an entry can reach
        reach = np.zeros(self.rows * self.cols, bool)
        for e in self.entries:
            reach |= np.isfinite(self.field(e["cell"]))
        self.floor = reach
        self.floor_idx = np.flatnonzero(reach)
        self._vis: dict[int, tuple[np.ndarray, np.ndarray, np.ndarray]] = {}
        self.anchors = self._build_anchors()
        self._anchor_looks: tuple | None = None
        self._anchor_dist: np.ndarray | None = None

    # ---- geometry
    def xy(self, c: int) -> tuple[float, float]:
        r, col = divmod(int(c), self.cols)
        return (col + 0.5) * self.cell, (r + 0.5) * self.cell

    def cell_at(self, x: float, y: float) -> int:
        col = min(self.cols - 1, max(0, int(x / self.cell)))
        r = min(self.rows - 1, max(0, int(y / self.cell)))
        return r * self.cols + col

    def nearest_walkable(self, x: float, y: float, among: np.ndarray | None = None) -> int | None:
        idx = np.flatnonzero(self.walkable) if among is None else among
        if not len(idx):
            return None
        r, c = np.divmod(idx, self.cols)
        d = ((c + 0.5) * self.cell - x) ** 2 + ((r + 0.5) * self.cell - y) ** 2
        return int(idx[int(np.argmin(d))])

    def _build_neighbors(self) -> list[list[tuple[int, float]]]:
        """Walkable 8-neighbors of every walkable cell. Diagonals can't cut a corner."""
        rows, cols, ok = self.rows, self.cols, self.walkable
        out: list[list[tuple[int, float]]] = [[] for _ in range(rows * cols)]
        diag = self.cell * math.sqrt(2)
        for i in np.flatnonzero(ok):
            r, c = divmod(int(i), cols)
            for dr, dc in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
                rr, cc = r + dr, c + dc
                if not (0 <= rr < rows and 0 <= cc < cols) or not ok[rr * cols + cc]:
                    continue
                if dr and dc and not (ok[r * cols + cc] and ok[rr * cols + c]):
                    continue
                slow = SMOKE_SLOW if self.smoke[rr * cols + cc] else 1.0
                out[i].append((rr * cols + cc, (diag if dr and dc else self.cell) * slow))
        return out

    def field(self, target: int) -> np.ndarray:
        """Walking distance (m) from every cell to `target`; inf where there's no way through.
        A meter of smoke counts as SMOKE_SLOW meters, so routes go round it unless that's much longer."""
        cache = self.__dict__.setdefault("_fields", {})
        hit = cache.get(target)
        if hit is not None:
            return hit
        if len(cache) > 600:
            cache.clear()
        dist = [math.inf] * (self.rows * self.cols)
        dist[target] = 0.0
        heap = [(0.0, target)]
        nbrs = self._neighbors
        while heap:
            d, i = heapq.heappop(heap)
            if d > dist[i]:
                continue
            for j, w in nbrs[i]:
                nd = d + w
                if nd < dist[j]:
                    dist[j] = nd
                    heapq.heappush(heap, (nd, j))
        out = np.array(dist, np.float32)
        cache[target] = out
        return out

    def line_walkable(self, a: tuple[float, float], b: tuple[float, float], through_smoke: bool = True) -> bool:
        """Can you walk straight from a to b? (Sampled finely, with a little shoulder room.)"""
        ok = self.walkable if through_smoke else self.clear
        n = max(2, int(math.hypot(b[0] - a[0], b[1] - a[1]) / (self.cell * 0.25)) + 1)
        t = np.linspace(0, 1, n)
        x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
        m = self.cell * 0.3
        for ox, oy in ((0, 0), (m, 0), (-m, 0), (0, m), (0, -m)):
            c = np.clip(((x + ox) / self.cell).astype(int), 0, self.cols - 1)
            r = np.clip(((y + oy) / self.cell).astype(int), 0, self.rows - 1)
            if not ok[r * self.cols + c].all():
                return False
        return True

    def path(self, start: int, target: int) -> list[tuple[float, float]]:
        """Waypoints from start to target: down the distance field, then pulled straight."""
        f = self.field(target)
        if not math.isfinite(f[start]):
            return []
        cells, i = [start], start
        while i != target and len(cells) < self.rows * self.cols:
            i = min(self._neighbors[i], key=lambda n: f[n[0]] + n[1])[0]
            cells.append(i)
        pts = [self.xy(c) for c in cells]
        out, i = [pts[0]], 0
        while i < len(pts) - 1:
            j = len(pts) - 1
            # only straighten over clear floor: a shortcut must not drag the route into smoke it went round
            while j > i + 1 and not self.line_walkable(pts[i], pts[j], through_smoke=False):
                j -= 1
            out.append(pts[j])
            i = j
        return out

    # ---- seeing
    def visible(self, origin: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Floor cells in line of sight of `origin`, within camera range:
        (cell indices, distance m, bearing deg). Walls block; furniture doesn't."""
        hit = self._vis.get(origin)
        if hit is not None:
            return hit
        ox, oy = self.xy(origin)
        r0, c0 = divmod(origin, self.cols)
        reach = int(math.ceil(self.range / self.cell))
        rr, cc = np.meshgrid(np.arange(max(0, r0 - reach), min(self.rows, r0 + reach + 1)),
                             np.arange(max(0, c0 - reach), min(self.cols, c0 + reach + 1)), indexing="ij")
        rr, cc = rr.ravel(), cc.ravel()
        idx = rr * self.cols + cc
        keep = self.floor[idx]
        rr, cc, idx = rr[keep], cc[keep], idx[keep]
        tx, ty = (cc + 0.5) * self.cell, (rr + 0.5) * self.cell
        d = np.hypot(tx - ox, ty - oy)
        keep = d <= self.range
        rr, cc, idx, tx, ty, d = rr[keep], cc[keep], idx[keep], tx[keep], ty[keep], d[keep]
        # walk each sight line in half-cell steps; anything opaque before the far cell blocks it
        t = np.linspace(0, 1, 2 * reach + 2)[1:-1][None, :]
        sc = ((ox + (tx[:, None] - ox) * t) / self.cell).astype(int)
        sr = ((oy + (ty[:, None] - oy) * t) / self.cell).astype(int)
        seen = ~self.opaque[sr, sc].any(axis=1)
        idx, d, tx, ty = idx[seen], d[seen], tx[seen], ty[seen]
        bearing = np.degrees(np.arctan2(tx - ox, -(ty - oy))) % 360
        out = (idx, d.astype(np.float32), bearing.astype(np.float32))
        self._vis[origin] = out
        return out

    def look(self, origin: int, heading: float, updates: float) -> tuple[np.ndarray, np.ndarray]:
        """What a camera at `origin` facing `heading` covers, and the chance `updates` hub updates
        (the hub updates its map UPDATES_PER_S times a second) of that look would spot the casualty
        in each covered cell. The cell you're standing in is always covered."""
        idx, d, bearing = self.visible(origin)
        off = np.abs(turn_between(heading, bearing))
        off = np.where(d < self.cell, 0.0, off)
        m = off <= self.fov / 2
        pod = POD_MAX * look_quality(d[m], off[m], self.fov / 2) * self._smoke_factor(origin, idx[m])
        return idx[m], 1 - (1 - pod) ** updates

    def _smoke_factor(self, origin: int, cells: np.ndarray) -> np.ndarray | float:
        if self.smoke[origin]:
            return SMOKE_POD
        return np.where(self.smoke[cells], SMOKE_POD, 1.0)

    def looks(self, origin: int) -> tuple[np.ndarray, np.ndarray]:
        """Every planning look (HEADINGS of them, one DWELL_S dwell each) from `origin`:
        (cell indices n, detection chance HEADINGS×n; zero outside each look's view)."""
        idx, d, bearing = self.visible(origin)
        headings = np.arange(HEADINGS)[:, None] * (360 / HEADINGS)
        off = np.abs(turn_between(headings, bearing[None, :]))
        off = np.where(d[None, :] < self.cell, 0.0, off)
        pod = POD_MAX * look_quality(d[None, :], off, self.fov / 2) * self._smoke_factor(origin, idx)
        return idx, np.where(off <= self.fov / 2, 1 - (1 - pod) ** (DWELL_S * UPDATES_PER_S), 0.0)

    def _build_anchors(self) -> list[int]:
        """Vantage points: one per ANCHOR_M block of floor, at the floor cell nearest its middle."""
        step = max(1, round(ANCHOR_M / self.cell))
        r, c = np.divmod(self.floor_idx, self.cols)
        block = (r // step) * (self.cols // step + 1) + c // step
        out = []
        for b in np.unique(block):
            members = self.floor_idx[block == b]
            mr, mc = np.divmod(members, self.cols)
            out.append(int(members[int(np.argmin((mr - mr.mean()) ** 2 + (mc - mc.mean()) ** 2))]))
        return out

    def anchor_looks(self) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """All anchors' planning looks flattened for one vectorized valuation:
        (cell index, detection chance, look id = anchor# * HEADINGS + heading#) per entry."""
        if self._anchor_looks is None:
            cells, pods, ids = [], [], []
            for a, anchor in enumerate(self.anchors):
                idx, pd = self.looks(anchor)
                h, n = np.nonzero(pd)
                cells.append(idx[n]); pods.append(pd[h, n]); ids.append(a * HEADINGS + h)
            self._anchor_looks = (np.concatenate(cells), np.concatenate(pods), np.concatenate(ids))
        return self._anchor_looks

    def anchor_distances(self) -> np.ndarray:
        """Walking distance from every cell to every vantage point (anchors × cells), once per floor plan."""
        if self._anchor_dist is None:
            self._anchor_dist = np.stack([self.field(a) for a in self.anchors])
        return self._anchor_dist

    def summary(self) -> dict:
        return {"id": self.id, "name": self.name, "description": self.spec.get("description", ""),
                "source": self.spec.get("source", "layout"), "width": round(self.width, 2),
                "depth": round(self.depth, 2), "cell": self.cell,
                "floorM2": round(float(self.floor.sum()) * self.cell ** 2, 1),
                "entries": [e["name"] for e in self.entries], "hasScan": bool(self.spec.get("scan")),
                "hazards": bool((self.grid == FIRE).any() or self.smoke.any()),
                "builtin": not self.spec.get("user", False)}


_env_cache: dict[str, tuple[int, Environment]] = {}


def env_path(env_id: str) -> Path | None:
    if not ID_RE.match(env_id):
        return None
    for folder in (USER_ENVS, ENVS):
        p = folder / f"{env_id}.json"
        if p.is_file():
            return p
    return None


def load_environment(env_id: str) -> Environment:
    """Parsed floor plans are kept (their sight lines and walking distances are the slow part)."""
    path = env_path(env_id)
    if path is None:
        raise KeyError(env_id)
    stamp = path.stat().st_mtime_ns
    hit = _env_cache.get(env_id)
    if hit and hit[0] == stamp:
        return hit[1]
    spec = json.loads(path.read_text())
    spec["id"] = env_id
    spec["user"] = path.parent == USER_ENVS
    env = Environment(spec)
    _env_cache[env_id] = (stamp, env)
    return env


def list_environments() -> list[dict]:
    out = []
    for folder in (ENVS, USER_ENVS):
        for p in sorted(folder.glob("*.json")) if folder.is_dir() else []:
            try:
                out.append(load_environment(p.stem).summary())
            except (ValueError, KeyError, json.JSONDecodeError) as e:
                out.append({"id": p.stem, "name": p.stem, "error": str(e)})
    return out


# ---------------------------------------------------------------- one run
@dataclass
class Params:
    rescuers: int = 3
    seed: int = 0
    victim: tuple[float, float] | None = None   # None = somewhere random on the floor
    start: str = "entry"                        # "entry" = walk in together; "spread" = already inside
    entry: int = 0
    strategy: str = "bayes"                     # "bayes" = the hub's planner; "frontier" = nearest unsearched
    responders: int = 2                         # how many have to reach the casualty for a rescue
    max_time: float = 600.0
    walk_speed: float = WALK_M_PER_S
    dt: float = 0.2
    record: bool = True

    @classmethod
    def from_dict(cls, d: dict) -> "Params":
        v = d.get("victim")
        return cls(
            rescuers=max(1, min(12, int(d.get("rescuers", 3)))),
            seed=int(d.get("seed", 0)) & 0x7FFFFFFF,
            victim=(float(v["x"]), float(v["y"])) if isinstance(v, dict) else None,
            start="spread" if d.get("start") == "spread" else "entry",
            entry=max(0, int(d.get("entry", 0))),
            strategy="frontier" if d.get("strategy") == "frontier" else "bayes",
            responders=max(1, min(12, int(d.get("responders", 2)))),
            max_time=max(30.0, min(3600.0, float(d.get("maxTime", 600)))),
            walk_speed=max(0.3, min(3.0, float(d.get("walkSpeed", WALK_M_PER_S)))),
            dt=max(0.1, min(1.0, float(d.get("dt", 0.2)))),
            record=bool(d.get("record", True)),
        )


@dataclass
class Rescuer:
    x: float
    y: float
    heading: float
    cell: int
    task: dict | None = None
    path: list = field(default_factory=list)
    walked: float = 0.0
    arrived: bool = False


def move_along(env: Environment, a, dt: float, speed: float) -> None:
    """Walk `a` (anything with x, y, heading, cell, path, walked) along its path for dt seconds."""
    budget = speed * dt / (SMOKE_SLOW if env.smoke[a.cell] else 1.0)
    while a.path and budget > 1e-9:
        tx, ty = a.path[0]
        d = math.hypot(tx - a.x, ty - a.y)
        if d > 1e-6:
            want = math.degrees(math.atan2(tx - a.x, -(ty - a.y))) % 360
            turn = turn_between(a.heading, want)
            a.heading = (a.heading + max(-FACE_DEG_PER_S * dt, min(FACE_DEG_PER_S * dt, turn))) % 360
        step = min(d, budget)
        if d > 1e-6:
            a.x += (tx - a.x) / d * step
            a.y += (ty - a.y) / d * step
        a.walked += step
        budget -= step
        if step >= d - 1e-9:
            a.path.pop(0)
    a.cell = env.cell_at(a.x, a.y)


def turn_toward(a, heading: float, dt: float) -> bool:
    """Turn `a` toward `heading` at a look's pace; True once it's facing that way."""
    turn = turn_between(a.heading, heading)
    if abs(turn) <= 1:
        return True
    a.heading = (a.heading + max(-TURN_DEG_PER_S * dt, min(TURN_DEG_PER_S * dt, turn))) % 360
    return False


class Run:
    def __init__(self, env: Environment, params: Params) -> None:
        self.env, self.p = env, params
        self.rng = np.random.default_rng(params.seed)
        n = env.rows * env.cols
        self.prob = np.zeros(n)
        self.prob[env.floor_idx] = 1 / len(env.floor_idx)
        self.looked = np.zeros(n, bool)
        self.t = 0.0
        self.phase = "search"
        self.events: list[dict] = []
        self.frames: list[list] = []
        self.heat: list[dict] = []
        self.found_at = self.found_by = self.rescued_at = self.coverage_at_find = None
        if params.victim:
            self.victim = env.nearest_walkable(*params.victim, among=env.floor_idx)
        else:
            self.victim = int(self.rng.choice(env.floor_idx))
        self.team = [self._spawn(i) for i in range(params.rescuers)]
        self.responders: list[int] = []

    def _spawn(self, i: int) -> Rescuer:
        env = self.env
        if self.p.start == "spread":
            cell = int(self.rng.choice(env.floor_idx))
        else:
            # walk in together: fan out over the floor cells nearest the door
            entry = env.entries[min(self.p.entry, len(env.entries) - 1)]["cell"]
            near = np.argsort(env.field(entry)[env.floor_idx], kind="stable")
            cell = int(env.floor_idx[near[min(i, len(near) - 1)]])
        x, y = env.xy(cell)
        heading = math.degrees(math.atan2(env.width / 2 - x, -(env.depth / 2 - y))) % 360  # facing in
        return Rescuer(x, y, heading, cell)

    def note(self, kind: str, text: str, agent: int | None = None) -> None:
        self.events.append({"t": round(self.t, 1), "type": kind, "agent": agent, "text": text})

    # ---- deciding
    def plan(self) -> None:
        """Bayesian search, as swarm/planner.py: every idle rescuer scores each thing they could do
        next by the chance of a find it buys per second, and the best (rescuer, option) pair is
        taken first; each pick discounts what it covers, so the next rescuer goes elsewhere."""
        env = self.env
        bayes = self.p.strategy == "bayes"
        # frontier search doesn't weigh anything: every floor cell nobody has looked at is worth the same
        if not bayes and self.looked[env.floor_idx].all():
            self.looked[:] = False  # swept the whole floor and missed them: sweep it again
        worth = self.prob.copy() if bayes else (env.floor & ~self.looked).astype(float)
        idle = []
        for i, a in enumerate(self.team):
            task = a.task
            if task and task["kind"] == "walk" and bayes:
                left = float(worth[task["cells"]] @ task["pd"])
                if left < task["gain"] * DONE_SHARE:   # someone else covered it on the way: call it off
                    a.task, a.path = None, []
                    task = None
            if task is None:
                idle.append(i)
            else:
                worth[task["cells"]] *= 1 - task["pd"]  # already spoken for
        if not idle:
            return
        a_cells, a_pd, a_ids = env.anchor_looks()
        a_dist, a_cell = env.anchor_distances(), np.array(env.anchors)
        n_looks = len(env.anchors) * HEADINGS
        taken = {a.task["anchor"] for a in self.team if a.task and a.task.get("anchor") is not None}
        while idle:
            anchor_value = np.bincount(a_ids, weights=worth[a_cells] * a_pd, minlength=n_looks) \
                .reshape(len(env.anchors), HEADINGS)
            best_h = anchor_value.argmax(axis=1)
            best_v = anchor_value[np.arange(len(env.anchors)), best_h]
            best = None  # (rate, rescuer, option)
            for i in idle:
                a = self.team[i]
                idx, pd = env.looks(a.cell)
                values = pd @ worth[idx]
                seconds = np.abs(turn_between(a.heading, np.arange(HEADINGS) * 360 / HEADINGS)) / TURN_DEG_PER_S + DWELL_S
                h = int(np.argmax(values / seconds))
                if values[h] > MIN_VALUE and (best is None or values[h] / seconds[h] > best[0]):
                    best = (values[h] / seconds[h], i, {"kind": "look", "heading": h * 360 / HEADINGS, "origin": a.cell})
                d = a_dist[:, a.cell]
                # frontier search walks to the nearest vantage point with anything left to see
                rates = best_v / (d / self.p.walk_speed + DWELL_S) if bayes else 1 / (1 + d)
                open_ = (best_v > MIN_VALUE) & np.isfinite(d) & (a_cell != a.cell) & ~np.isin(a_cell, list(taken))
                if open_.any():
                    k = int(np.argmax(np.where(open_, rates, -1)))
                    if best is None or rates[k] > best[0]:
                        best = (float(rates[k]), i, {"kind": "walk", "heading": best_h[k] * 360 / HEADINGS,
                                                     "origin": env.anchors[k], "anchor": env.anchors[k]})
            if best is None:
                # nothing any vantage point can see is worth a look, but the casualty isn't found:
                # what's left is tucked away somewhere, so go and stand on the likeliest spot
                i = idle[0]
                spot = int(np.argmax(np.where(env.floor, worth, -1)))
                if worth[spot] <= 0 or spot == self.team[i].cell:
                    idle.pop(0)
                    continue
                best = (0.0, i, {"kind": "walk", "heading": self.team[i].heading, "origin": spot, "anchor": None})
            _, i, option = best
            self.assign(i, option, worth)
            if option.get("anchor") is not None:
                taken.add(option["anchor"])
            idle.remove(i)

    def assign(self, i: int, option: dict, worth: np.ndarray) -> None:
        env, a = self.env, self.team[i]
        cells, pd = env.look(option["origin"], option["heading"], DWELL_S * UPDATES_PER_S)
        gain = float(worth[cells] @ pd)
        worth[cells] *= 1 - pd
        a.task = {**option, "cells": cells, "pd": pd, "gain": gain, "dwell": DWELL_S}
        if option["kind"] == "walk":
            a.path = env.path(a.cell, option["origin"])[1:]
            x, y = env.xy(option["origin"])
            a.task["to"] = (round(x, 2), round(y, 2))
            if self.p.strategy == "bayes":
                self.note("assign", f"walk to ({x:.1f}, {y:.1f}) · {gain * 100:.1f}% chance of a find there", i)

    # ---- moving
    def walk(self, a: Rescuer, dt: float) -> None:
        move_along(self.env, a, dt, self.p.walk_speed)

    def step_search(self, a: Rescuer, dt: float) -> None:
        task = a.task
        if task is None:
            return
        if a.path:
            self.walk(a, dt)
            return
        turn = turn_between(a.heading, task["heading"])
        if abs(turn) > 1:
            a.heading = (a.heading + max(-TURN_DEG_PER_S * dt, min(TURN_DEG_PER_S * dt, turn))) % 360
            return
        task["dwell"] -= dt
        if task["dwell"] <= 0:
            a.task = None

    def sense(self, dt: float) -> None:
        """Everyone's camera updates the shared map, exactly as Coverage.update does; and if the
        casualty is in somebody's view, that look has its real chance of catching them."""
        for i, a in enumerate(self.team):
            cells, pd = self.env.look(a.cell, a.heading, dt * UPDATES_PER_S)
            self.looked[cells] = True
            self.prob[cells] *= 1 - pd
            at = np.flatnonzero(cells == self.victim)
            if len(at) and self.found_at is None and self.rng.random() < pd[at[0]]:
                self.found(i)
        total = self.prob.sum()
        if total > 0:
            self.prob /= total

    def found(self, i: int) -> None:
        env = self.env
        self.found_at, self.found_by = self.t, i
        self.coverage_at_find = float(self.looked[env.floor_idx].mean())
        self.phase = "respond"
        if self.p.record:
            self.record_heat()
        vx, vy = env.xy(self.victim)
        self.note("found", f"casualty spotted at ({vx:.1f}, {vy:.1f}) after {self.t:.0f} s", i)
        f = env.field(self.victim)
        order = sorted(range(len(self.team)), key=lambda k: float(f[self.team[k].cell]))
        self.responders = order[:min(self.p.responders, len(self.team))]
        for k, a in enumerate(self.team):
            a.task, a.path = None, []
            if k in self.responders:
                a.path = env.path(a.cell, self.victim)[1:]
                a.task = {"kind": "respond", "to": (round(vx, 2), round(vy, 2))}
                self.note("respond", f"responding · {float(f[a.cell]):.0f} m to walk", k)

    def step_respond(self, dt: float) -> None:
        vx, vy = self.env.xy(self.victim)
        for k in self.responders:
            a = self.team[k]
            if a.arrived:
                continue
            near = math.hypot(a.x - vx, a.y - vy) <= ARRIVE_M and self.env.line_walkable((a.x, a.y), (vx, vy))
            if near or not a.path:
                a.arrived, a.path = True, []
                self.note("arrived", "reached the casualty", k)
                continue
            self.walk(a, dt)
        if all(self.team[k].arrived for k in self.responders):
            self.rescued_at = self.t
            self.phase = "rescued"
            self.note("rescued", f"{len(self.responders)} responder{'s' if len(self.responders) != 1 else ''} "
                                 f"with the casualty after {self.t:.0f} s")

    # ---- recording
    def record(self) -> None:
        self.frames.append([round(self.t, 2), [
            [round(a.x, 2), round(a.y, 2), round(a.heading),
             *(a.task["to"] if a.task and a.task.get("to") and (a.path or a.task["kind"] == "respond") else ())]
            for a in self.team]])

    def record_heat(self) -> None:
        p = self.prob[self.env.floor_idx]
        top = float(p.max()) or 1.0
        levels = np.rint((len(HEAT_LEVELS) - 1) * p / top).astype(int)
        self.heat.append({"t": round(self.t, 1), "heat": "".join(HEAT_LEVELS[v] for v in levels),
                          "searched": round(float(self.looked[self.env.floor_idx].mean()), 3)})

    def run(self) -> dict:
        p = self.p
        record_every, heat_every = max(1, round(0.4 / p.dt)), max(1, round(2.0 / p.dt))
        tick = 0
        while self.t <= p.max_time and self.phase != "rescued":
            if self.phase == "search":
                if any(a.task is None for a in self.team) or tick % max(1, round(1.0 / p.dt)) == 0:
                    self.plan()
                for a in self.team:
                    self.step_search(a, p.dt)
                self.sense(p.dt)
            else:
                self.step_respond(p.dt)
            if p.record:
                if tick % record_every == 0 or self.phase == "rescued":
                    self.record()
                if tick % heat_every == 0 and self.phase == "search":
                    self.record_heat()
            tick += 1
            self.t += p.dt
        if self.phase == "search":
            self.note("timeout", f"not found in {p.max_time:.0f} s")
        return self.result()

    def result(self) -> dict:
        env = self.env
        vx, vy = env.xy(self.victim)
        outcome = "rescued" if self.rescued_at is not None else "found" if self.found_at is not None else "timeout"
        summary = {
            "outcome": outcome, "rescuers": len(self.team), "seed": self.p.seed, "strategy": self.p.strategy,
            "victim": {"x": round(vx, 2), "y": round(vy, 2)},
            "foundAt": None if self.found_at is None else round(self.found_at, 1),
            "foundBy": self.found_by,
            "rescuedAt": None if self.rescued_at is None else round(self.rescued_at, 1),
            "searched": round(float(self.looked[env.floor_idx].mean()), 3),
            "searchedAtFind": None if self.coverage_at_find is None else round(self.coverage_at_find, 3),
            "walkedM": [round(a.walked, 1) for a in self.team],
            "elapsed": round(min(self.t, self.p.max_time), 1),
        }
        if not self.p.record:
            return {"summary": summary}
        return {"summary": summary, "events": self.events,
                "trace": {"frames": self.frames, "heat": self.heat, "responders": self.responders}}


def simulate(env: Environment, params: Params) -> dict:
    return Run(env, params).run()


# ---------------------------------------------------------------- many runs
def _percentile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * q
    lo, hi = math.floor(k), math.ceil(k)
    return round(s[lo] + (s[hi] - s[lo]) * (k - lo), 1)


def aggregate(runs: list[dict], max_time: float) -> dict:
    """One team size's runs → the numbers worth comparing. A run that timed out counts as taking
    the whole time limit, so a team that often fails can't look fast by only counting its wins."""
    n = len(runs)
    found = [r for r in runs if r["foundAt"] is not None]
    rescued = [r for r in runs if r["rescuedAt"] is not None]
    find_times = [r["foundAt"] if r["foundAt"] is not None else max_time for r in runs]
    rescue_times = [r["rescuedAt"] if r["rescuedAt"] is not None else max_time for r in runs]
    return {
        "runs": n, "foundRate": round(len(found) / n, 3), "rescuedRate": round(len(rescued) / n, 3),
        "find": {"p10": _percentile(find_times, .1), "median": _percentile(find_times, .5),
                 "p90": _percentile(find_times, .9), "mean": round(statistics.fmean(find_times), 1)},
        "rescue": {"p10": _percentile(rescue_times, .1), "median": _percentile(rescue_times, .5),
                   "p90": _percentile(rescue_times, .9), "mean": round(statistics.fmean(rescue_times), 1)},
        "searchedAtFind": round(statistics.fmean(r["searchedAtFind"] for r in found), 3) if found else None,
        "walkedPerRescuerM": round(statistics.fmean(statistics.fmean(r["walkedM"]) for r in runs), 1),
    }


def _batch_job(job: tuple[str, dict]) -> dict:
    env_id, d = job
    return simulate(load_environment(env_id), Params.from_dict({**d, "record": False, "dt": 0.5}))["summary"]


def batch(env_id: str, base: dict, team_sizes: list[int], runs: int, progress=None, workers: int | None = None) -> dict:
    """Every team size faces the same `runs` casualty placements (seed k puts the casualty in the
    same place whatever the team), so sizes are compared like for like."""
    seed0 = int(base.get("seed", 0))
    jobs = [(env_id, {**base, "rescuers": size, "seed": seed0 + k}) for size in team_sizes for k in range(runs)]
    workers = workers if workers is not None else max(1, min(8, (os.cpu_count() or 2) - 1))
    summaries = []
    if workers > 1 and len(jobs) > 4:
        import multiprocessing
        with multiprocessing.get_context("spawn").Pool(workers) as pool:
            for s in pool.imap(_batch_job, jobs, chunksize=2):
                summaries.append(s)
                if progress:
                    progress(len(summaries), len(jobs))
    else:
        for job in jobs:
            summaries.append(_batch_job(job))
            if progress:
                progress(len(summaries), len(jobs))
    max_time = Params.from_dict(base).max_time
    return {"env": env_id, "runsPerSize": runs, "maxTime": max_time, "strategy": Params.from_dict(base).strategy,
            "sizes": [{"rescuers": size, **aggregate(summaries[i * runs:(i + 1) * runs], max_time)}
                      for i, size in enumerate(team_sizes)],
            "runs": [{"rescuers": s["rescuers"], "x": s["victim"]["x"], "y": s["victim"]["y"],
                      "foundAt": s["foundAt"], "rescuedAt": s["rescuedAt"]} for s in summaries]}


# ---------------------------------------------------------------- command line
def main() -> None:
    ap = argparse.ArgumentParser(description="Beacon rescue simulator")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("run", "batch"):
        sp = sub.add_parser(name)
        sp.add_argument("--env", required=True)
        sp.add_argument("--rescuers", default="3", help="team size; for batch, a comma-separated list")
        sp.add_argument("--seed", type=int, default=0)
        sp.add_argument("--strategy", choices=("bayes", "frontier"), default="bayes")
        sp.add_argument("--start", choices=("entry", "spread"), default="entry")
        sp.add_argument("--responders", type=int, default=2)
        sp.add_argument("--max-time", type=float, default=600)
        sp.add_argument("--json", action="store_true", help="machine output: progress lines, then the result")
    sub.choices["batch"].add_argument("--runs", type=int, default=30)
    sub.choices["batch"].add_argument("--params", help="JSON parameters (overrides the flags); used by the hub")
    args = ap.parse_args()
    base = {"seed": args.seed, "strategy": args.strategy, "start": args.start,
            "responders": args.responders, "maxTime": args.max_time}
    try:
        load_environment(args.env)
    except KeyError:
        sys.exit(f"no environment {args.env!r}: have {', '.join(e['id'] for e in list_environments())}")
    if args.cmd == "run":
        out = simulate(load_environment(args.env), Params.from_dict({**base, "rescuers": int(args.rescuers), "record": False}))
        print(json.dumps(out["summary"], indent=None if args.json else 2))
        return
    if args.params:
        base = {**base, **json.loads(args.params)}
    sizes = [max(1, min(12, int(s))) for s in str(args.rescuers).split(",") if s.strip()]

    def progress(done: int, total: int) -> None:
        if args.json:
            print(json.dumps({"progress": done, "total": total}), flush=True)
        elif done % 10 == 0 or done == total:
            print(f"  {done}/{total} runs", file=sys.stderr)

    out = batch(args.env, base, sizes, max(1, min(200, args.runs)), progress)
    if args.json:
        print(json.dumps({"result": out}), flush=True)
        return
    print(f"\n{load_environment(args.env).name} · {out['runsPerSize']} runs per team size · {out['strategy']}\n")
    print("  team   found   find time, s (p10 / median / p90)   rescue median   searched at find   walked each")
    for s in out["sizes"]:
        f, r = s["find"], s["rescue"]
        print(f"  {s['rescuers']:>4}   {s['foundRate'] * 100:>4.0f}%   {f['p10']:>7} / {f['median']:>6} / {f['p90']:>6}"
              f"          {r['median']:>8} s   {(s['searchedAtFind'] or 0) * 100:>14.0f}%   {s['walkedPerRescuerM']:>8} m")


if __name__ == "__main__":
    main()
