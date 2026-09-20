"""Everyone the swarm has found, the teams sent to them, and guiding those teams in.

A search usually turns up more than one person, so this holds a list. Finding is driven by
detections (see sightings.py): once a sighting is confident enough the hub calls confirm(). A
sighting on top of somebody we already have reinforces them; anyone new becomes another Victim
with their own fix, their own find team and their own guidance.

The finder counts as the first responder (they're already there) and the nearest free phones fill
out the team. A phone belongs to one team at a time. When somebody new is found and nobody is
free, a spare responder is pulled off a team that has already gathered — nobody is left standing
alone next to a person they just found. Finding one person never ends the search: see complete().

For rehearsals the operator can hide several mock candidates. The mock detector reports whichever
ones a camera can see. Real visual searches use operator-confirmed evidence with unknown position.
"""
from __future__ import annotations

import itertools
import math
import random
from collections.abc import Callable

from .protocol import now_ms

ARRIVE_M = 1.5       # responders closer than this have arrived
GUIDE_EVERY_MS = 200
SAME_PERSON_M = 2.0  # a find this close to somebody already found is that same person
# `drawFoundPerson` in web/console.js, so the colour a searcher's whole screen
# turns is the colour the operator's map already marks that person with.
FOUND_COLOR = "#b72f36"


class Victim:
    """One found person: where they are, how sure we are, and who is with them."""

    def __init__(self, vid: int, x: float, y: float, confidence: float, finder: str,
                 now: float, wanted: int, label: str | None = None) -> None:
        self.id = vid
        self.label = label or f"Person {vid}"  # the reference photo's name, when there is one
        self.fix = (x, y)
        self.confidence = confidence
        self.found_by = finder
        self.found_at = now
        self.wanted = wanted
        self.responders: dict[str, dict] = {finder: {"arrived": True}}

    @property
    def attended(self) -> bool:
        """The whole team is with this person."""
        return bool(self.responders) and all(r["arrived"] for r in self.responders.values())

    def short(self) -> int:
        """How many more responders this person still needs."""
        return max(0, self.wanted - len(self.responders))

    def spare(self) -> str | None:
        """A responder this team can give up: one who has arrived and isn't the finder."""
        extra = [pid for pid, r in self.responders.items() if pid != self.found_by and r["arrived"]]
        return extra[-1] if len(self.responders) > 1 and extra else None

    def reinforce(self, x: float, y: float, confidence: float) -> None:
        """Another confident look at the same person: nudge the fix, keep the better confidence."""
        total = confidence + self.confidence
        w = confidence / total if total else 0.5
        self.fix = (self.fix[0] + w * (x - self.fix[0]), self.fix[1] + w * (y - self.fix[1]))
        self.confidence = max(self.confidence, confidence)

    def takeover(self, kind: str, ttl_ms: int) -> dict:
        """A full-screen card on a searcher's phone, named rather than worded.

        The phone owns the wording and the layout (`HUDMirror.takeover`); all the
        hub says is which card and who it is about, so the two cannot drift and
        the phone can show the person's name rather than "them"."""
        return {"cmd": "flash", "color": FOUND_COLOR, "takeover": kind,
                "name": self.label, "ttlMs": ttl_ms}

    def snapshot(self, now: float) -> dict:
        return {"id": self.id, "label": self.label,
                "x": round(self.fix[0], 2), "y": round(self.fix[1], 2),
                "foundBy": self.found_by, "confidence": round(self.confidence, 3),
                "foundMs": round(now - self.found_at), "attended": self.attended,
                "respondersWanted": self.wanted,
                "responders": {pid: r["arrived"] for pid, r in self.responders.items()}}


def scatter(room: dict, count: int, rng: random.Random, taken: list[tuple[float, float]] | None = None,
            margin: float = .6, spacing: float = 2.0) -> list[tuple[float, float]]:
    """`count` spots on the floor, none of them on top of each other or of `taken`.

    Used to lay out a drill: the people to find and the chairs in the way. Rejection
    sampling with a bail-out, because a small room and a large count can make the
    spacing impossible and a rehearsal that hangs is worse than one that crowds.
    """
    placed = list(taken or [])
    out: list[tuple[float, float]] = []
    x0, x1 = -room['width'] / 2 + margin, room['width'] / 2 - margin
    y0, y1 = margin, room['depth'] - margin
    for _ in range(max(0, count)):
        for attempt in range(60):
            spot = (round(rng.uniform(x0, x1), 2), round(rng.uniform(y0, y1), 2))
            if attempt == 59 or all(math.dist(spot, other) >= spacing for other in placed):
                placed.append(spot)
                out.append(spot)
                break
    return out


class Target:
    def __init__(self, room: dict, note, enabled: Callable[[], bool] = lambda: True) -> None:
        self.enabled = enabled
        self.note = note  # log callback: note(text, phone_id)
        self.candidates: dict[int, tuple[float, float]] = {}  # hidden mock candidates (rehearsals)
        self.responders_wanted = 3
        self.pending_clear: list[str] = []  # ex-responders whose guidance must be cleared
        self._candidate_ids = itertools.count(1)
        self._victim_ids = itertools.count(1)
        self.reset_search()

    def reset_search(self) -> None:
        self.victims: list[Victim] = []
        self.search_started = now_ms()
        self.last_guide = 0.0

    # ---- the first find and the first hidden candidate ------------------------
    # Single-target callers (and the hub's older state fields) still read these.

    @property
    def pos(self) -> tuple[float, float] | None:
        return next(iter(self.candidates.values()), None)

    @property
    def found_by(self) -> str | None:
        return self.victims[0].found_by if self.victims else None

    @property
    def found_at(self) -> float | None:
        return self.victims[0].found_at if self.victims else None

    @property
    def fix(self) -> tuple[float, float] | None:
        return self.victims[0].fix if self.victims else None

    @property
    def confidence(self) -> float | None:
        return self.victims[0].confidence if self.victims else None

    @property
    def responders(self) -> dict[str, dict]:
        """Every responder on every team."""
        return {pid: r for v in self.victims for pid, r in v.responders.items()}

    # ---- hidden mock candidates (rehearsals) ----------------------------------

    def place(self, x: float, y: float, cid: int | None = None) -> bool:
        """Hide a mock candidate. Without an id this adds another one; with one it moves that one.
        Returns True when this starts a fresh rehearsal (the hub then clears old sightings)."""
        if not self.enabled():
            self.remove()
            return False
        if cid is not None and cid in self.candidates:
            self.candidates[cid] = (x, y)
            return False
        fresh = not self.candidates and not self.victims
        self.candidates[next(self._candidate_ids) if cid is None else cid] = (x, y)
        if fresh:
            self.pending_clear += list(self.responders)
            self.reset_search()
        return fresh

    def remove(self, cid: int | None = None) -> None:
        """Remove one hidden candidate, or with no id clear the lot: candidates and finds alike."""
        if cid is not None:
            self.candidates.pop(cid, None)
            return
        self.pending_clear += list(self.responders)
        self.candidates.clear()
        self.reset_search()

    def unfound(self) -> list[tuple[float, float]]:
        """Hidden candidates nobody has found yet — the only ones the mock detector reports."""
        return [p for p in self.candidates.values() if not self.at(*p)]

    # ---- found people ---------------------------------------------------------

    def at(self, x: float, y: float) -> Victim | None:
        """Whoever we have already found at this spot, if anyone."""
        near = min(self.victims, key=lambda v: math.dist(v.fix, (x, y)), default=None)
        return near if near and math.dist(near.fix, (x, y)) <= SAME_PERSON_M else None

    def found_positions(self) -> list[tuple[float, float]]:
        return [v.fix for v in self.victims]

    def set_responders_wanted(self, n: int) -> None:
        """Team size for the next find, and for teams still being filled."""
        self.responders_wanted = max(0, n)
        for victim in self.victims:
            victim.wanted = self.responders_wanted

    def busy(self) -> set[str]:
        """Everybody on a find team: nothing else may steer them."""
        return set(self.responders) if self.enabled() else set()

    def complete(self) -> bool:
        """Everyone we found has their team with them, and no hidden candidate is still missing."""
        return bool(self.enabled() and self.victims and not self.unfound()
                    and all(v.attended for v in self.victims))

    def confirm(self, finder: str, x: float, y: float, confidence: float,
                viewers: dict, now: float, label: str | None = None) -> list[tuple[str, dict]]:
        """A sighting reached the found threshold: this is somebody we already have, or somebody
        new who needs a find team of their own. `label` names them when the sighting matched one
        particular reference photo."""
        if not self.enabled():
            return []
        known = self.at(x, y)
        if known:
            known.reinforce(x, y, confidence)
            return []
        victim = Victim(next(self._victim_ids), x, y, confidence, finder, now,
                        self.responders_wanted, label)
        self.victims.append(victim)
        secs = (now - self.search_started) / 1000
        who = victim.label if label else ("someone" if len(self.victims) == 1 else f"person {victim.id}")
        self.note(f"FOUND {who} ({round(confidence * 100)}% sure) after {secs:.1f}s", finder)
        return ([(finder, victim.takeover("found_stay", 2500))] + self._staff(victim, viewers))

    def _staff(self, victim: Victim, viewers: dict) -> list[tuple[str, dict]]:
        """Fill a team: free phones first, nearest first, then a spare from a team that has already
        gathered. Called again every guide cycle, so a short team picks up whoever comes free."""
        out: list[tuple[str, dict]] = []
        tx, ty = victim.fix
        while victim.short():
            taken = set(self.responders)
            free = sorted((math.hypot(tx - px, ty - py), pid)
                          for pid, (px, py, _, _) in viewers.items() if pid not in taken)
            if free:
                distance, pid = free[0]
                victim.responders[pid] = {"arrived": False}
                self.note(f"dispatched to {victim.label} ({distance:.1f} m away)", pid)
            else:
                donation = self._donor(victim)
                if not donation:
                    break
                giver, pid = donation
                del giver.responders[pid]
                victim.responders[pid] = {"arrived": False}
                self.note(f"pulled off {giver.label} to reach {victim.label}", pid)
            out.append((pid, victim.takeover("found_go", 1800)))
        return out

    def _donor(self, needy: Victim) -> tuple[Victim, str] | None:
        """The most over-staffed gathered team that can spare somebody. It has to keep more people
        than the team it's giving to, so responders can't ping-pong between two finds."""
        best: tuple[Victim, str] | None = None
        for victim in self.victims:
            if victim is needy or not victim.attended:
                continue
            if len(victim.responders) - 1 <= len(needy.responders):
                continue
            pid = victim.spare()
            if pid and (best is None or len(victim.responders) > len(best[0].responders)):
                best = (victim, pid)
        return best

    def tick(self, viewers: dict[str, tuple[float, float, float, float | None]],
             now: float) -> list[tuple[str, dict]]:
        if not self.enabled():
            self.remove()
        out: list[tuple[str, dict]] = [(pid, {"cmd": "guide", "clear": True}) for pid in self.pending_clear]
        self.pending_clear = []
        if not self.victims or now - self.last_guide < GUIDE_EVERY_MS:
            return out
        self.last_guide = now
        for victim in self.victims:
            out += self._staff(victim, viewers)
        many = len(self.victims) > 1
        for victim in self.victims:
            tx, ty = victim.fix
            for pid, r in victim.responders.items():
                if r["arrived"] or pid not in viewers:
                    continue
                x, y, heading, _ = viewers[pid]
                d = math.hypot(tx - x, ty - y)
                if d <= ARRIVE_M:
                    r["arrived"] = True
                    self.note(f"arrived at {victim.label}" if many else "arrived at the candidate", pid)
                    out.append((pid, {"cmd": "guide", "clear": True}))
                    # Arriving at a person is not a green "task done": it is the
                    # start of staying with them, and the phone says so in the
                    # same red it has been saying since the find.
                    out.append((pid, victim.takeover("found_stay", 1500)))
                    continue
                bearing = math.degrees(math.atan2(tx - x, -(ty - y))) % 360
                delta = (bearing - heading + 540) % 360 - 180
                out.append((pid, {"cmd": "guide", "kind": "respond",
                                  "sector": victim.label.upper()[:16] if many else "CANDIDATE",
                                  "delta": round(delta, 1), "distance": round(d, 1)}))
        return out

    def snapshot(self, now: float) -> dict | None:
        if not self.enabled() or (not self.candidates and not self.victims):
            return None
        first = self.victims[0] if self.victims else None
        return {
            # the first hidden candidate and the first find, the shape the console grew up on
            "x": self.pos[0] if self.pos else None, "y": self.pos[1] if self.pos else None,
            "respondersWanted": self.responders_wanted,
            "foundBy": first.found_by if first else None,
            "fix": list(first.fix) if first else None,
            "confidence": first.confidence if first else None,
            "searchMs": round((first.found_at if first else now) - self.search_started),
            "responders": {pid: r["arrived"] for pid, r in self.responders.items()},
            # everyone, which is what the console actually draws
            "candidates": [{"id": cid, "x": round(x, 2), "y": round(y, 2), "found": self.at(x, y) is not None}
                           for cid, (x, y) in self.candidates.items()],
            "victims": [v.snapshot(now) for v in self.victims],
            "foundCount": len(self.victims),
            "attendedCount": sum(1 for v in self.victims if v.attended),
            "stillMissing": len(self.unfound()),
        }
