"""Search planner: decides where each phone looks (and who should walk where), then steers it there.

From Bayesian search theory (how the Coast Guard plans searches): every option is scored by how much probability of finding the candidate it's expected to buy per
  second. An option is "turn to face heading h" or "walk to spot s, then look". Its value is the
  probability mass in the view it would give times the chance that view would spot the candidate,
  using the same detection model the probability map is updated with (coverage.look_quality),
  divided by the time it takes: turning, walking (people sit, so walking costs extra), dwelling.
  Phones are assigned greedily, the best (phone, option) pair first, and each pick discounts the
  probability it covers so the next phone goes somewhere else. The objective is submodular, so
  this greedy assignment is guaranteed at least half as good as the best possible one.

Several times a second each assigned phone is told how far to turn, using its live heading.
"""
from __future__ import annotations

import math
import string
from collections import deque

from .coverage import POD_MAX, look_quality
from .protocol import now_ms

SECTOR = 2.5            # sector size in meters
DONE_FRACTION = 0.85    # a sector is done once this share of the part a phone can see has been looked at
PLAN_EVERY_MS = 1000
GUIDE_EVERY_MS = 200
MIN_REASSIGN_MS = 4000  # don't pull a phone off its look sooner than this
MAX_PITCH = 65
HEADINGS = 16            # candidate directions to face (every 22.5°)
UPDATES_PER_S = 5        # the probability map is updated this often (hub coverage loop)
DWELL_S = 3.0            # a look lasts about this long
TURN_DEG_PER_S = 90
WALK_M_PER_S = 0.8
WALK_OVERHEAD_S = 8.0    # getting up, excusing yourself past people: walking has to be worth it
SWITCH_MARGIN = 1.3      # a new option must beat the current one by 30% (no dithering)
DONE_SHARE = 0.25        # a look is used up once it has bought 75% of what it promised
MIN_WALK_GAIN = 0.05     # asking someone to walk has to buy at least a 5% chance of finding them


class Planner:
    def __init__(self, room: dict, coverage) -> None:
        self.room = room
        self.coverage = coverage
        self.range = room["coneLength"]
        self.half_fov = room["cameraFovDeg"] / 2
        self.cols = math.ceil(room["width"] / SECTOR)
        self.rows = math.ceil(room["depth"] / SECTOR)
        self.x0 = -room["width"] / 2
        self.enabled = False
        self.walk_requests: list[tuple[str, float, float, str]] = []  # (phone id, x, y, label) for the hub
        self.walking: dict[str, dict] = {}  # phone id → the walk option it was sent on (until it's back in view)
        self._cone_cache: dict[tuple, list[tuple[int, float]]] = {}
        self.assignments: dict[str, dict] = {}  # phone id → {sector, t, onTarget, left, progress_t}
        self.log: deque[dict] = deque(maxlen=30)
        self.last_plan = 0.0
        self.last_guide = 0.0
        # sector name → [(cell index, x, y)] for every coverage cell inside it
        self.sector_cells: dict[str, list[tuple[int, float, float]]] = {}
        for i in range(len(coverage.looked)):
            row, col = divmod(i, coverage.cols)
            x = coverage.x0 + (col + 0.5) * coverage.cell
            y = (row + 0.5) * coverage.cell
            name = self.sector_name(int((x - self.x0) // SECTOR), int(y // SECTOR))
            self.sector_cells.setdefault(name, []).append((i, x, y))

    # ---- geometry ----------------------------------------------------------
    def sector_name(self, col: int, row: int) -> str:
        return f"{string.ascii_uppercase[col]}{row + 1}"

    def sector_center(self, name: str) -> tuple[float, float]:
        col, row = string.ascii_uppercase.index(name[0]), int(name[1:]) - 1
        return self.x0 + (col + 0.5) * SECTOR, (row + 0.5) * SECTOR

    def unsearched_from(self, name: str, x: float, y: float) -> float:
        """Share of the sector's cells within camera range of (x, y) that nobody has looked at."""
        looked = self.coverage.looked
        in_range = [i for i, cx, cy in self.sector_cells[name]
                    if self.coverage.cell <= math.hypot(cx - x, cy - y) <= self.range]
        if not in_range:
            return 0.0
        return sum(not looked[i] for i in in_range) / len(in_range)

    def bearing_to(self, x: float, y: float, tx: float, ty: float) -> float:
        # heading convention: 0 = toward the stage (-y), clockwise
        return math.degrees(math.atan2(tx - x, -(ty - y))) % 360

    def reachable(self, x: float, y: float) -> dict[str, float]:
        """Sectors this phone can still usefully search → share of its visible part unsearched."""
        out = {}
        for name in self.sector_cells:
            cx, cy = self.sector_center(name)
            if math.hypot(cx - x, cy - y) > self.range + SECTOR:
                continue
            left = self.unsearched_from(name, x, y)
            if left > 1 - DONE_FRACTION:
                out[name] = left
        return out

    # ---- main loop ---------------------------------------------------------
    def tick(self, viewers: dict[str, tuple[float, float, float, float | None]], now: float) -> list[tuple[str, dict]]:
        """viewers: phone id → (x, y, heading, pitch). Returns (phone id, command) pairs to send."""
        out: list[tuple[str, dict]] = []
        for pid in [p for p in self.assignments if p not in viewers or not self.enabled]:
            del self.assignments[pid]
            out.append((pid, {"cmd": "guide", "clear": True}))
        if not self.enabled:
            return out

        if now - self.last_plan >= PLAN_EVERY_MS:
            self.last_plan = now
            self.plan(viewers, now)

        if now - self.last_guide >= GUIDE_EVERY_MS:
            self.last_guide = now
            for pid, a in self.assignments.items():
                x, y, heading, pitch = viewers[pid]
                delta = (a["heading"] - heading + 540) % 360 - 180
                a["onTarget"] = abs(delta) < self.half_fov * 0.6
                tilted = pitch is not None and abs(pitch) > MAX_PITCH
                out.append((pid, {
                    "cmd": "guide", "sector": a["sector"], "delta": round(delta, 1),
                    "onTarget": a["onTarget"] and not tilted,
                    "text": "Hold your phone up" if tilted
                            else f"Scanning {a['sector']}…" if a["onTarget"]
                            else f"Turn {'right' if delta > 0 else 'left'} {abs(round(delta))}°",
                }))
        return out

    # ---- Bayesian planning -----------------------------------------------------
    def view(self, x: float, y: float, heading: float) -> list[tuple[int, float]]:
        """Cells a look from (x, y) toward heading covers, with the chance that look (a DWELL_S dwell)
        would spot the candidate if it were there: 1 - (1 - POD per update)^(updates in the dwell)."""
        key = (round(x * 4), round(y * 4), round(heading) % 360)
        hit = self._cone_cache.get(key)
        if hit is None:
            if len(self._cone_cache) > 4000:
                self._cone_cache.clear()
            n = DWELL_S * UPDATES_PER_S
            hit = [(c, 1 - (1 - POD_MAX * look_quality(d, off, self.half_fov)) ** n)
                   for c, d, off in self.coverage.cone(x, y, heading)]
            self._cone_cache[key] = hit
        return hit

    def options(self, x: float, y: float, heading: float) -> list[dict]:
        """What a phone standing at (x, y) facing heading could do next: face one of HEADINGS
        directions, or walk to a sector center out of its reach and look from there."""
        out = []
        for i in range(HEADINGS):
            h = i * 360 / HEADINGS
            turn = abs((h - heading + 540) % 360 - 180)
            out.append({"kind": "look", "heading": h, "x": x, "y": y,
                        "seconds": turn / TURN_DEG_PER_S + DWELL_S, "cells": self.view(x, y, h)})
        for name in self.sector_cells:
            cx, cy = self.sector_center(name)
            d = math.hypot(cx - x, cy - y)
            if d <= self.range:
                continue  # in reach already: turning covers it
            # from the sector center, face back the way you came (most of the sector is then in view)
            h = self.bearing_to(cx, cy, x, y) if d > 0 else 0.0
            out.append({"kind": "walk", "heading": (h + 180) % 360, "x": cx, "y": cy, "sector": name,
                        "seconds": WALK_OVERHEAD_S + d / WALK_M_PER_S + DWELL_S, "cells": self.view(cx, cy, (h + 180) % 360)})
        return out

    @staticmethod
    def value(option: dict, prob: list[float]) -> float:
        """Probability of finding the candidate this option is expected to buy."""
        return sum(prob[c] * p for c, p in option["cells"])

    def plan(self, viewers: dict, now: float) -> None:
        prob = list(self.coverage.prob)  # residual: discounted as options are claimed
        for pid in [p for p in self.walking if p in viewers]:
            del self.walking[pid]  # arrived (or gave up): back to looking
        walk_to = set()  # never send two people walking to the same spot
        for o in self.walking.values():  # people on their way will look there: count it as claimed
            walk_to.add(o["sector"])
            for c, p in o["cells"]:
                prob[c] *= 1 - p
        phones = {}
        for pid, (x, y, heading, pitch) in viewers.items():
            a = self.assignments.get(pid)
            if a and a.get("manual"):
                continue  # operator assignments stick until the sector is done
            phones[pid] = self.options(x, y, heading if heading is not None else 0.0)
        # how much the phone's current look is still worth (for hysteresis and "used up")
        current = {}
        for pid, a in self.assignments.items():
            if pid in phones and a.get("heading") is not None:
                x, y, _, _ = viewers[pid]
                cur = {"kind": "look", "heading": a["heading"], "seconds": DWELL_S, "cells": self.view(x, y, a["heading"])}
                current[pid] = (cur, self.value(cur, prob))
        chosen: dict[str, tuple[dict, float]] = {}
        while len(chosen) < len(phones):
            best = None
            for pid, opts in phones.items():
                if pid in chosen:
                    continue
                for o in opts:
                    if o["kind"] == "walk" and (o["sector"] in walk_to or self.value(o, prob) < MIN_WALK_GAIN):
                        continue
                    rate = self.value(o, prob) / o["seconds"]
                    if best is None or rate > best[0]:
                        best = (rate, pid, o)
            if best is None or best[0] <= 0:
                break
            rate, pid, o = best
            cur = current.get(pid)
            a = self.assignments.get(pid)
            if cur and a:
                cur_rate = cur[1] / cur[0]["seconds"]
                young = now - a["t"] < MIN_REASSIGN_MS
                used_up = cur[1] < a["gain"] * DONE_SHARE
                if not used_up and (young or rate < cur_rate * SWITCH_MARGIN):
                    o, rate = cur[0], cur_rate  # keep going: not worth switching yet
            chosen[pid] = (o, rate)
            if o["kind"] == "walk":
                walk_to.add(o["sector"])
            for c, p in o["cells"]:  # whoever looks there next expects less from it
                prob[c] *= 1 - p
        for pid, (o, rate) in chosen.items():
            a = self.assignments.get(pid)
            gain = sum(self.coverage.prob[c] * p for c, p in o["cells"])
            if o["kind"] == "walk":
                self.assignments.pop(pid, None)
                self.walk_requests.append((pid, o["x"], o["y"], o["sector"]))
                self.walking[pid] = o
                self.note(f"→ walk to {o['sector']} ({gain * 100:.0f}% chance to find there)", pid)
                continue
            if a and a.get("heading") == o["heading"]:
                continue
            sector = self.sector_at(viewers[pid][0], viewers[pid][1], o["heading"])
            self.assignments[pid] = {"sector": sector, "heading": o["heading"], "t": now, "onTarget": False,
                                     "gain": gain, "left": 1.0, "progress_t": now}
            self.note(f"→ {sector} ({gain * 100:.1f}% chance to find)", pid)

    def sector_at(self, x: float, y: float, heading: float) -> str:
        """Name of the sector a look toward heading is mostly about (a few meters out)."""
        d = self.range * 0.6
        px = max(self.x0 + 0.01, min(-self.x0 - 0.01, x + d * math.sin(math.radians(heading))))
        py = max(0.01, min(self.rows * SECTOR - 0.01, y - d * math.cos(math.radians(heading))))
        return self.sector_name(int((px - self.x0) // SECTOR), min(self.rows - 1, int(py // SECTOR)))

    def assign(self, pid: str, sector: str, x: float, y: float, now: float) -> None:
        """Operator override: send this phone to a sector regardless of the greedy plan."""
        self.assignments[pid] = {"sector": sector, "t": now, "onTarget": False, "manual": True,
                                 "left": self.unsearched_from(sector, x, y), "progress_t": now}
        self.note(f"→ {sector} (operator)", pid)

    def is_sector(self, name: str) -> bool:
        return name in self.sector_cells

    def note(self, text: str, pid: str | None = None) -> None:
        self.log.append({"t": now_ms(), "text": text, "phoneId": pid})

    def reset(self) -> None:
        self.walking.clear()
        self.assignments.clear()
        self.log.clear()

    def snapshot(self) -> dict:
        return {
            "enabled": self.enabled, "mode": "bayes", "sectorSize": SECTOR,
            "cols": self.cols, "rows": self.rows,
            "assignments": {pid: {"sector": a["sector"], "onTarget": a["onTarget"], "heading": a.get("heading"),
                                  "gain": round(a["gain"], 3) if a.get("gain") is not None else None}
                            for pid, a in self.assignments.items()},
            "log": list(self.log),
        }
