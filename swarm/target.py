"""Mock candidate for rehearsing the find → respond flow.

The operator places and drags a candidate on the dashboard. When a phone's camera cone
covers it for DWELL_MS, it's found: the finder is told, and the RESPONDERS nearest other
phones get live directions to it until they're within ARRIVE_M.
"""
from __future__ import annotations

import math

from .protocol import now_ms

DWELL_MS = 500     # candidate must stay in view this long to count as found
ARRIVE_M = 1.5     # responders closer than this have arrived
GUIDE_EVERY_MS = 200
MAX_PITCH = 65


class Target:
    def __init__(self, room: dict, note) -> None:
        self.range = room["coneLength"]
        self.half_fov = room["cameraFovDeg"] / 2
        self.note = note  # log callback: note(text, phone_id)
        self.pos: tuple[float, float] | None = None
        self.responders_wanted = 3
        self.pending_clear: list[str] = []  # ex-responders whose guidance must be cleared
        self.reset_search()

    def reset_search(self) -> None:
        self.found_by: str | None = None
        self.found_at: float | None = None
        self.search_started = now_ms()
        self.in_view_since: dict[str, float] = {}
        self.responders: dict[str, dict] = {}  # phone id → {"arrived": bool}
        self.last_guide = 0.0

    def place(self, x: float, y: float) -> None:
        fresh = self.pos is None or self.found_by is not None
        self.pos = (x, y)
        if fresh:  # a new candidate, or moving a found one, starts a new search
            self.pending_clear += list(self.responders)
            self.reset_search()

    def remove(self) -> None:
        self.pending_clear += list(self.responders)
        self.pos = None
        self.reset_search()

    def busy(self) -> set[str]:
        """Phones currently responding (the planner leaves them alone)."""
        return {pid for pid, r in self.responders.items() if not r["arrived"]}

    def sees(self, x: float, y: float, heading: float, pitch: float | None) -> bool:
        tx, ty = self.pos
        d = math.hypot(tx - x, ty - y)
        if d > self.range or (pitch is not None and abs(pitch) > MAX_PITCH):
            return False
        if d < 0.3:
            return True
        bearing = math.degrees(math.atan2(tx - x, -(ty - y)))
        return abs((bearing - heading + 540) % 360 - 180) <= self.half_fov

    def tick(self, viewers: dict[str, tuple[float, float, float, float | None]], now: float) -> list[tuple[str, dict]]:
        out: list[tuple[str, dict]] = [(pid, {"cmd": "guide", "clear": True}) for pid in self.pending_clear]
        self.pending_clear = []
        if self.pos is None:
            return out
        tx, ty = self.pos

        if self.found_by is None:
            for pid, (x, y, heading, pitch) in viewers.items():
                if not self.sees(x, y, heading, pitch):
                    self.in_view_since.pop(pid, None)
                    continue
                since = self.in_view_since.setdefault(pid, now)
                if now - since >= DWELL_MS:
                    out += self.on_found(pid, viewers, now)
                    break
            return out

        # guide responders in
        if now - self.last_guide < GUIDE_EVERY_MS:
            return out
        self.last_guide = now
        for pid, r in self.responders.items():
            if r["arrived"] or pid not in viewers:
                continue
            x, y, heading, _ = viewers[pid]
            d = math.hypot(tx - x, ty - y)
            if d <= ARRIVE_M:
                r["arrived"] = True
                self.note("arrived at the candidate", pid)
                out.append((pid, {"cmd": "guide", "clear": True}))
                out.append((pid, {"cmd": "flash", "color": "#7ae582", "text": "You're there ✓", "ttlMs": 1500}))
                continue
            bearing = math.degrees(math.atan2(tx - x, -(ty - y))) % 360
            delta = (bearing - heading + 540) % 360 - 180
            out.append((pid, {"cmd": "guide", "kind": "respond", "sector": "CANDIDATE",
                              "delta": round(delta, 1), "distance": round(d, 1)}))
        return out

    def on_found(self, finder: str, viewers: dict, now: float) -> list[tuple[str, dict]]:
        self.found_by, self.found_at = finder, now
        secs = (now - self.search_started) / 1000
        self.note(f"FOUND the candidate after {secs:.1f}s", finder)
        tx, ty = self.pos
        others = sorted(
            (math.hypot(tx - x, ty - y), pid) for pid, (x, y, _, _) in viewers.items() if pid != finder
        )
        chosen = [pid for _, pid in others[: self.responders_wanted]]
        self.responders = {pid: {"arrived": False} for pid in chosen}
        out = [(finder, {"cmd": "flash", "color": "#ff5d73", "text": "You found them!\nStay on them", "ttlMs": 2500})]
        for d, pid in others[: self.responders_wanted]:
            self.note(f"dispatched ({d:.1f} m away)", pid)
            out.append((pid, {"cmd": "flash", "color": "#ff5d73", "text": "Candidate found!\nFollow the arrow", "ttlMs": 1800}))
        return out

    def snapshot(self, now: float) -> dict | None:
        if self.pos is None:
            return None
        return {
            "x": self.pos[0], "y": self.pos[1], "respondersWanted": self.responders_wanted,
            "foundBy": self.found_by,
            "searchMs": round((self.found_at or now) - self.search_started),
            "responders": {pid: r["arrived"] for pid, r in self.responders.items()},
        }
