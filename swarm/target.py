"""The search target: found state, the find team, and guiding responders in.

Finding is driven by detections (see sightings.py): once a sighting is confident enough, the hub
calls confirm(). The finder counts as the first responder (already there); the nearest other
phones make up the rest of the team and get live directions to the sighting until they're within
ARRIVE_M. The whole team then stays with the candidate: nothing else steers them.

For rehearsals the operator can also place a hidden mock candidate (pos). The mock detector
reports it when cameras see it. Real visual searches use operator-confirmed evidence with unknown position.
"""
from __future__ import annotations

import math
from collections.abc import Callable

from .protocol import now_ms

ARRIVE_M = 1.5     # responders closer than this have arrived
GUIDE_EVERY_MS = 200


class Target:
    def __init__(self, room: dict, note, enabled: Callable[[], bool] = lambda: True) -> None:
        self.enabled = enabled
        self.note = note  # log callback: note(text, phone_id)
        self.pos: tuple[float, float] | None = None  # hidden mock candidate (rehearsals only)
        self.responders_wanted = 3
        self.pending_clear: list[str] = []  # ex-responders whose guidance must be cleared
        self.reset_search()

    def reset_search(self) -> None:
        self.found_by: str | None = None
        self.found_at: float | None = None
        self.fix: tuple[float, float] | None = None  # where the confirmed sighting is
        self.confidence: float | None = None
        self.search_started = now_ms()
        self.responders: dict[str, dict] = {}  # phone id → {"arrived": bool}
        self.last_guide = 0.0

    def place(self, x: float, y: float) -> bool:
        if not self.enabled():
            self.remove()
            return False
        fresh = self.pos is None or self.found_by is not None
        self.pos = (x, y)
        if fresh:
            self.pending_clear += list(self.responders)
            self.reset_search()
        return fresh

    def remove(self) -> None:
        self.pending_clear += list(self.responders)
        self.pos = None
        self.reset_search()

    def busy(self) -> set[str]:
        """The find team (finder + responders, arrived or not): nothing else may steer them."""
        return set(self.responders) if self.enabled() else set()

    def complete(self) -> bool:
        """Found, and the whole find team is with the candidate: the search is over."""
        return bool(self.enabled() and self.found_by and self.responders and all(r["arrived"] for r in self.responders.values()))

    def confirm(self, finder: str, x: float, y: float, confidence: float,
                viewers: dict, now: float) -> list[tuple[str, dict]]:
        """A sighting reached the found threshold: form the find team and start guiding it in."""
        if not self.enabled():
            return []
        self.found_by, self.found_at, self.fix, self.confidence = finder, now, (x, y), confidence
        secs = (now - self.search_started) / 1000
        self.note(f"FOUND the candidate ({round(confidence * 100)}% sure) after {secs:.1f}s", finder)
        others = sorted(
            (math.hypot(x - px, y - py), pid) for pid, (px, py, _, _) in viewers.items() if pid != finder
        )
        # the finder is the first responder; the nearest others fill out the team
        dispatched = others[: max(0, self.responders_wanted - 1)]
        self.responders = {finder: {"arrived": True}} | {pid: {"arrived": False} for _, pid in dispatched}
        out = [(finder, {"cmd": "flash", "color": "#ff5d73", "text": "You found them!\nStay on them", "ttlMs": 2500})]
        for d, pid in dispatched:
            self.note(f"dispatched ({d:.1f} m away)", pid)
            out.append((pid, {"cmd": "flash", "color": "#ff5d73", "text": "Candidate found!\nFollow the arrow", "ttlMs": 1800}))
        return out

    def tick(self, viewers: dict[str, tuple[float, float, float, float | None]], now: float) -> list[tuple[str, dict]]:
        if not self.enabled():
            self.remove()
        out: list[tuple[str, dict]] = [(pid, {"cmd": "guide", "clear": True}) for pid in self.pending_clear]
        self.pending_clear = []
        if not self.found_by or now - self.last_guide < GUIDE_EVERY_MS:
            return out
        self.last_guide = now
        tx, ty = self.fix
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

    def snapshot(self, now: float) -> dict | None:
        if not self.enabled() or (self.pos is None and not self.found_by):
            return None
        return {
            "x": self.pos[0] if self.pos else None, "y": self.pos[1] if self.pos else None,
            "respondersWanted": self.responders_wanted,
            "foundBy": self.found_by,
            "fix": list(self.fix) if self.fix else None,
            "confidence": self.confidence,
            "searchMs": round((self.found_at or now) - self.search_started),
            "responders": {pid: r["arrived"] for pid, r in self.responders.items()},
        }
