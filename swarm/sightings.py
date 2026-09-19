"""Detections → sightings in the room, plus a mock detector for rehearsals.

The detection model reports boxes with a confidence score for a phone's frame. Each box is placed
in the room from the phone's position and heading (which way the box is) and the box's size (how
far away it is). Detections within CLUSTER_M of each other are one sighting. A sighting's
confidence combines the best score from each phone: independent looks agreeing make it surer.

- score >= WEAK_MIN: nudges the probability heatmap toward where it points
- sighting confidence >= POSSIBLE_CONF: a possible sighting, worth a second look
- sighting confidence >= FOUND_CONF: found
"""
from __future__ import annotations

import itertools
import math
import random

from .coverage import look_quality

WEAK_MIN = 0.1
POSSIBLE_CONF = 0.4
FOUND_CONF = 0.8
CLUSTER_M = 1.5
FORGET_S = 90          # sightings nobody has reinforced for this long are dropped
TARGET_HEIGHT_M = 1.0  # rough size of the target (a seated person / an object on a table), for distance
FRAME_ASPECT = 4 / 3   # frame height / width (phones stream portrait)


def fovs(room: dict) -> tuple[float, float]:
    """Horizontal and vertical field of view (radians) of a streamed frame."""
    hf = math.radians(room["cameraFovDeg"])
    return hf, 2 * math.atan(math.tan(hf / 2) * FRAME_ASPECT)


class Sightings:
    def __init__(self, room: dict) -> None:
        self.room = room
        self.hfov, self.vfov = fovs(room)
        self.items: list[dict] = []  # {id, x, y, phones: {pid: best score}, t, announced}
        self.ids = itertools.count(1)

    def reset(self) -> None:
        self.items.clear()

    def locate(self, pose: dict, box: dict) -> tuple[float, float] | None:
        """Where in the room a box is: direction from its horizontal position, distance from its height."""
        if pose.get("heading") is None or box.get("h", 0) <= 0:
            return None
        cx = box["x"] + box["w"] / 2
        off = math.degrees(math.atan((cx - 0.5) * 2 * math.tan(self.hfov / 2)))
        d = TARGET_HEIGHT_M / (2 * box["h"] * math.tan(self.vfov / 2))
        d = max(0.5, min(d, self.room["coneLength"] + 2))
        b = math.radians(pose["heading"] + off)
        return pose["x"] + d * math.sin(b), pose["y"] - d * math.cos(b)

    def ingest(self, pid: str, pose: dict, boxes: list[dict], now_s: float) -> list[tuple[float, float, float]]:
        """Record one phone's detections. Returns (x, y, score) for each placed box (for the heatmap)."""
        placed = []
        for box in boxes:
            score = float(box.get("score") or 0)
            if score < WEAK_MIN:
                continue
            spot = self.locate(pose, box)
            if not spot:
                continue
            placed.append((*spot, score))
            if score < POSSIBLE_CONF:
                continue  # faint hint: heatmap only
            near = min(self.items, key=lambda s: math.dist((s["x"], s["y"]), spot), default=None)
            if near and math.dist((near["x"], near["y"]), spot) <= CLUSTER_M:
                w = score / (score + sum(near["phones"].values()))
                near["x"] += w * (spot[0] - near["x"])
                near["y"] += w * (spot[1] - near["y"])
                near["phones"][pid] = max(score, near["phones"].get(pid, 0))
                near["t"] = now_s
            else:
                self.items.append({"id": next(self.ids), "x": spot[0], "y": spot[1],
                                   "phones": {pid: score}, "t": now_s, "announced": False})
        self.items = [s for s in self.items if now_s - s["t"] < FORGET_S]
        return placed

    @staticmethod
    def confidence(s: dict) -> float:
        miss = 1.0
        for score in s["phones"].values():
            miss *= 1 - score
        return 1 - miss

    def best(self) -> dict | None:
        return max(self.items, key=self.confidence, default=None)

    def snapshot(self) -> list[dict]:
        return [{"id": s["id"], "x": round(s["x"], 2), "y": round(s["y"], 2),
                 "confidence": round(self.confidence(s), 3), "phones": list(s["phones"])} for s in self.items]


class MockDetector:
    """Stands in for the real model during rehearsals: when the operator's hidden candidate is in a
    phone's view, now and then report it with a score that's higher up close and dead-center, lower
    far away, plus noise. Occasionally reports a faint false positive. Boxes use the same format as
    POST /api/detections, so the real model drops in without other changes."""

    def __init__(self, room: dict) -> None:
        self.room = room
        self.hfov, self.vfov = fovs(room)
        self.half = room["cameraFovDeg"] / 2

    def detect(self, x: float, y: float, heading: float, pitch: float | None,
               target: tuple[float, float]) -> list[dict]:
        boxes = []
        tx, ty = target
        d = math.hypot(tx - x, ty - y)
        off = (math.degrees(math.atan2(tx - x, -(ty - y))) - heading + 540) % 360 - 180
        tilted = pitch is not None and abs(pitch) > 65
        if 0.3 < d <= self.room["coneLength"] and abs(off) <= self.half and not tilted:
            q = look_quality(d, off, self.half)
            if random.random() < 0.25 + 0.5 * q:  # the model doesn't fire on every frame
                score = max(0.05, min(0.99, 0.35 + 0.75 * q + random.gauss(0, 0.07)))
                boxes.append(self._box(d, off, score))
        if random.random() < 0.01:  # rare faint false positive somewhere in view
            boxes.append(self._box(random.uniform(1, 5), random.uniform(-self.half, self.half),
                                   random.uniform(0.1, 0.3)))
        return boxes

    def _box(self, d: float, off: float, score: float) -> dict:
        h = min(0.95, TARGET_HEIGHT_M / (2 * d * math.tan(self.vfov / 2)))
        w = h * 0.6
        cx = 0.5 + math.tan(math.radians(off)) / (2 * math.tan(self.hfov / 2))
        return {"x": round(cx - w / 2, 3), "y": round(0.55 - h / 2, 3), "w": round(w, 3), "h": round(h, 3),
                "label": "person", "score": round(score, 2)}
