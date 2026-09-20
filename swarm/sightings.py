"""Detections → sightings in the room, plus a mock detector for rehearsals.

The detection model reports boxes with a confidence score for a phone's frame. Each box is placed
in the room from the phone's position and heading (which way the box is) and the box's size (how
far away it is). Detections within CLUSTER_M of each other are one sighting. A sighting's
confidence combines what each phone last saw, faded by how long ago it saw it: independent looks
agreeing make it surer, and evidence nobody has refreshed gets weaker until the sighting is
forgotten at FORGET_S. Both halves matter. Keeping each phone's *best ever* score instead of its
latest made confidence a high-water mark that could only climb — one lucky frame pinned a phone
at 0.9 for a minute and a half — and with several phones stacking their stale peaks under a
noisy-OR, a sighting drifted to near-certainty and tripped FOUND_CONF on evidence nobody still
had in view.

Several sightings can be confident at once — a room can hold more than one person to find — so
nothing here picks a winner. The hub turns every confident sighting into a find (see target.py)
and hands back the people it already has, whose detections are dropped: they have responders with
them, and the swarm's attention belongs on whoever is still missing.

- score >= WEAK_MIN: nudges the probability heatmap toward where it points
- sighting confidence >= POSSIBLE_CONF: a possible sighting, worth a second look
- sighting confidence >= FOUND_CONF: found
"""
from __future__ import annotations

import itertools
import math
import random
import time

from collections.abc import Sequence

from .coverage import look_quality
from .target import SAME_PERSON_M

WEAK_MIN = 0.1
POSSIBLE_CONF = 0.4
FOUND_CONF = 0.8
CLUSTER_M = 1.5
FORGET_S = 90          # sightings nobody has reinforced for this long are dropped
TARGET_HEIGHT_M = 1.0  # rough size of the target (a seated person / an object on a table), for distance
PERSON_HEIGHT_M = 1.7  # a detected person's box, for distance (real inference boxes whole people)
FRAME_ASPECT = 4 / 3   # frame height / width (phones stream portrait)


def fovs(room: dict) -> tuple[float, float]:
    """Horizontal and vertical field of view (radians) of a streamed frame."""
    hf = math.radians(room["cameraFovDeg"])
    return hf, 2 * math.atan(math.tan(hf / 2) * FRAME_ASPECT)


class Sightings:
    def __init__(self, room: dict) -> None:
        self.room = room
        self.hfov, self.vfov = fovs(room)
        self.items: list[dict] = []  # {id, x, y, phones: {pid: {score, similarity, t}}, persons, t, announced}
        self.ids = itertools.count(1)

    def reset(self) -> None:
        self.items.clear()

    def locate(self, pose: dict, box: dict) -> tuple[float, float] | None:
        """Where in the room a box is: direction from its horizontal position, distance from its height."""
        if pose.get("heading") is None or box.get("h", 0) <= 0:
            return None
        cx = box["x"] + box["w"] / 2
        off = math.degrees(math.atan((cx - 0.5) * 2 * math.tan(self.hfov / 2)))
        d = box.get("heightM", TARGET_HEIGHT_M) / (2 * box["h"] * math.tan(self.vfov / 2))
        d = max(0.5, min(d, self.room["coneLength"] + 2))
        b = math.radians(pose["heading"] + off)
        return pose["x"] + d * math.sin(b), pose["y"] - d * math.cos(b)

    def ingest(self, pid: str, pose: dict, boxes: list[dict], now_s: float,
               found: Sequence[tuple[float, float]] = ()) -> list[tuple[float, float, float]]:
        """Record one phone's detections. Returns (x, y, score) for each placed box (for the
        heatmap). Boxes that land on somebody in `found` are dropped: we have them already."""
        placed = []
        for box in boxes:
            score = float(box.get("score") or 0)
            if score < WEAK_MIN:
                continue
            spot = self.locate(pose, box)
            if not spot:
                continue
            if any(math.dist(spot, seen) <= SAME_PERSON_M for seen in found):
                continue
            placed.append((*spot, score))
            if score < POSSIBLE_CONF:
                continue  # faint hint: heatmap only
            who = box.get("person")  # which reference person this matched, when there are several
            # The model's own number, carried through untouched. `score` is derived from it and is
            # the thing the thresholds run on; `similarity` is what the model actually said, and it
            # is what an operator (or anything reading this later) should be shown.
            evidence = {"score": score, "similarity": box.get("similarity"), "t": now_s}
            near = min(self.items, key=lambda s: math.dist((s["x"], s["y"]), spot), default=None)
            if near and math.dist((near["x"], near["y"]), spot) <= CLUSTER_M:
                w = score / (score + sum(self.weights(near, now_s).values()))
                near["x"] += w * (spot[0] - near["x"])
                near["y"] += w * (spot[1] - near["y"])
                near["phones"][pid] = evidence
                near["t"] = now_s
                if who:
                    near["persons"].add(who)
            else:
                self.items.append({"id": next(self.ids), "x": spot[0], "y": spot[1],
                                   "phones": {pid: evidence},
                                   "persons": {who} if who else set(),
                                   "t": now_s, "announced": False})
        self.items = [s for s in self.items if now_s - s["t"] < FORGET_S]
        return placed

    @staticmethod
    def who(s: dict) -> str | None:
        """The reference person this sighting matched, when exactly one of them fits."""
        people = s.get("persons") or set()
        return next(iter(people)) if len(people) == 1 else None

    @staticmethod
    def weights(s: dict, now_s: float | None = None) -> dict[str, float]:
        """Phone id → the score it is still voting with, faded toward zero as its look ages out."""
        now_s = time.time() if now_s is None else now_s
        out = {}
        for pid, e in s["phones"].items():
            fade = max(0.0, 1 - (now_s - e["t"]) / FORGET_S)
            if fade > 0:
                out[pid] = e["score"] * fade
        return out

    @classmethod
    def confidence(cls, s: dict, now_s: float | None = None) -> float:
        miss = 1.0
        for score in cls.weights(s, now_s).values():
            miss *= 1 - score
        return 1 - miss

    @classmethod
    def looking(cls, s: dict, now_s: float | None = None) -> str | None:
        """The phone with the strongest standing evidence for this sighting."""
        live = cls.weights(s, now_s)
        return max(live, key=live.get) if live else None

    def best(self) -> dict | None:
        return max(self.items, key=self.confidence, default=None)

    def confident(self, minimum: float) -> list[dict]:
        """Every sighting at least this confident, surest first — each one is somebody to find."""
        return sorted((s for s in self.items if self.confidence(s) >= minimum),
                      key=self.confidence, reverse=True)

    def snapshot(self) -> list[dict]:
        """`confidence` is a combination and can only be read next to what it was combined from,
        so the raw evidence ships with it: how many phones are looking at this right now, the best
        single score among them, and — in a real search — the model's own similarity behind that
        score, unrescaled. `similarity` is None in a rehearsal, where the mock detector emits a
        score directly and there is no embedding to compare."""
        now_s = time.time()
        out = []
        for s in self.items:
            live = self.weights(s, now_s)
            strongest = max(s["phones"].values(), key=lambda e: e["score"], default=None)
            sim = strongest.get("similarity") if strongest else None
            out.append({"id": s["id"], "x": round(s["x"], 2), "y": round(s["y"], 2),
                        "confidence": round(self.confidence(s, now_s), 3),
                        "agree": len(live),
                        "bestScore": round(strongest["score"], 3) if strongest else 0.0,
                        "similarity": round(sim, 3) if sim is not None else None,
                        "ageMs": round((now_s - s["t"]) * 1000),
                        "phones": list(live), "persons": sorted(s["persons"])})
        return out


class MockDetector:
    """Stands in for the real model during rehearsals: when one of the operator's hidden candidates
    is in a phone's view, now and then report it with a score that's higher up close and
    dead-center, lower far away, plus noise. A camera pointed at two of them reports both.
    Occasionally reports a faint false positive. Boxes use the same format as
    POST /api/detections, so the real model drops in without other changes."""

    def __init__(self, room: dict) -> None:
        self.room = room
        self.hfov, self.vfov = fovs(room)
        self.half = room["cameraFovDeg"] / 2

    def detect(self, x: float, y: float, heading: float, pitch: float | None,
               target: tuple[float, float]) -> list[dict]:
        return self.detect_many(x, y, heading, pitch, [target])

    def detect_many(self, x: float, y: float, heading: float, pitch: float | None,
                    targets: Sequence[tuple[float, float]]) -> list[dict]:
        boxes = []
        for target in targets:
            boxes += self._see(x, y, heading, pitch, target)
        if random.random() < 0.01:  # rare faint false positive somewhere in view
            boxes.append(self._box(random.uniform(1, 5), random.uniform(-self.half, self.half),
                                   random.uniform(0.1, 0.3)))
        return boxes

    def _see(self, x: float, y: float, heading: float, pitch: float | None,
             target: tuple[float, float]) -> list[dict]:
        tx, ty = target
        d = math.hypot(tx - x, ty - y)
        off = (math.degrees(math.atan2(tx - x, -(ty - y))) - heading + 540) % 360 - 180
        tilted = pitch is not None and abs(pitch) > 65
        if not (0.3 < d <= self.room["coneLength"] and abs(off) <= self.half and not tilted):
            return []
        q = look_quality(d, off, self.half)
        if random.random() >= 0.25 + 0.5 * q:  # the model doesn't fire on every frame
            return []
        score = max(0.05, min(0.99, 0.35 + 0.75 * q + random.gauss(0, 0.07)))
        return [self._box(d, off, score)]

    def _box(self, d: float, off: float, score: float) -> dict:
        h = min(0.95, TARGET_HEIGHT_M / (2 * d * math.tan(self.vfov / 2)))
        w = h * 0.6
        cx = 0.5 + math.tan(math.radians(off)) / (2 * math.tan(self.hfov / 2))
        return {"x": round(cx - w / 2, 3), "y": round(0.55 - h / 2, 3), "w": round(w, 3), "h": round(h, 3),
                "label": "person", "score": round(score, 2)}
