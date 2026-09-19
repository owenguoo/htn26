"""Greedy search planner: decides which phone looks at which sector, then steers it there.

The room is split into sectors (A1, B1, ...). About once a second the planner gives
each idle phone the reachable sector with the most unsearched floor, spreading phones
across different sectors. Several times a second it tells each assigned phone how far
to turn, using that phone's live heading. A sector is done for a phone once most of
the part that phone can actually see (within camera range) has been looked at.
"""
from __future__ import annotations

import math
import string
from collections import deque

from .protocol import now_ms

SECTOR = 2.5            # sector size in meters
DONE_FRACTION = 0.85    # sector counts as searched once this share of its cells has been looked at
PLAN_EVERY_MS = 1000
GUIDE_EVERY_MS = 200
MIN_REASSIGN_MS = 4000  # don't pull a phone off its sector sooner than this
STALL_MS = 5000         # on target but no new floor seen for this long: move on
MAX_PITCH = 65


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
        self.assignments: dict[str, dict] = {}  # phone id → {sector, t, onTarget, left, progress_t}
        self.skipped: dict[str, set[str]] = {}   # phone id → sectors it stalled on
        self.log: deque[dict] = deque(maxlen=8)
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

    def available(self, pid: str, x: float, y: float) -> dict[str, float]:
        skipped = self.skipped.get(pid, set())
        return {s: left for s, left in self.reachable(x, y).items() if s not in skipped}

    # ---- main loop ---------------------------------------------------------
    def tick(self, viewers: dict[str, tuple[float, float, float, float | None]], now: float) -> list[tuple[str, dict]]:
        """viewers: phone id → (x, y, heading, pitch). Returns (phone id, command) pairs to send."""
        out: list[tuple[str, dict]] = []
        for pid in [p for p in self.assignments if p not in viewers or not self.enabled]:
            del self.assignments[pid]
            out.append((pid, {"cmd": "guide", "clear": True}))
        if not self.enabled:
            return out

        # finished or stalled sectors
        for pid, a in list(self.assignments.items()):
            x, y, _, _ = viewers[pid]
            left = self.unsearched_from(a["sector"], x, y)
            if left < a["left"] - 0.01:
                a["left"], a["progress_t"] = left, now
            if left <= 1 - DONE_FRACTION:
                del self.assignments[pid]
                self.note(f"✓ {a['sector']} searched", pid)
                out.append((pid, {"cmd": "flash", "color": "#7ae582", "text": f"✓ {a['sector']} searched", "ttlMs": 1200}))
            elif a["onTarget"] and now - a["progress_t"] > STALL_MS:
                # the rest of this sector is outside what this phone's camera can take in
                del self.assignments[pid]
                self.skipped.setdefault(pid, set()).add(a["sector"])
                self.note(f"↷ left {a['sector']} ({round(left * 100)}% out of view)", pid)

        if now - self.last_plan >= PLAN_EVERY_MS:
            self.last_plan = now
            self.plan(viewers, now)

        if now - self.last_guide >= GUIDE_EVERY_MS:
            self.last_guide = now
            for pid, a in self.assignments.items():
                x, y, heading, pitch = viewers[pid]
                cx, cy = self.sector_center(a["sector"])
                delta = (self.bearing_to(x, y, cx, cy) - heading + 540) % 360 - 180
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

    def plan(self, viewers: dict, now: float) -> None:
        taken = {a["sector"] for a in self.assignments.values()}
        # phones with the fewest options choose first, so nobody gets stranded
        candidates = []
        for pid, (x, y, heading, pitch) in viewers.items():
            a = self.assignments.get(pid)
            if a and now - a["t"] < MIN_REASSIGN_MS:
                continue
            options = self.available(pid, x, y)
            if options:
                candidates.append((len(options), pid, x, y, heading, options))
        for _, pid, x, y, heading, options in sorted(candidates):
            current = self.assignments.get(pid)
            free = [s for s in options if s not in taken or (current and s == current["sector"])]
            pool = free or options  # every sector taken: doubling up beats idling

            def score(s: str) -> float:
                cx, cy = self.sector_center(s)
                turn = abs((self.bearing_to(x, y, cx, cy) - heading + 540) % 360 - 180)
                return options[s] - turn / 720  # prefer unsearched, then less turning

            best = max(pool, key=score)
            if current and current["sector"] == best:
                continue
            if current:
                taken.discard(current["sector"])
            self.assignments[pid] = {"sector": best, "t": now, "onTarget": False,
                                     "left": options[best], "progress_t": now}
            taken.add(best)
            self.note(f"→ {best} ({round(options[best] * 100)}% unsearched)", pid)

    def note(self, text: str, pid: str | None = None) -> None:
        self.log.append({"t": now_ms(), "text": text, "phoneId": pid})

    def reset(self) -> None:
        self.assignments.clear()
        self.skipped.clear()
        self.log.clear()

    def snapshot(self) -> dict:
        return {
            "enabled": self.enabled, "mode": "greedy", "sectorSize": SECTOR,
            "cols": self.cols, "rows": self.rows,
            "assignments": {pid: {"sector": a["sector"], "onTarget": a["onTarget"]}
                            for pid, a in self.assignments.items()},
            "log": list(self.log),
        }
