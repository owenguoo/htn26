"""Coverage and probability over the floor plan.

- looked: which cells any camera has looked at (drives "area searched" and the planner).
- prob: where the candidate probably is (a Bayesian search map). It starts even. Every look
  lowers the cells it covered by how good the look was (close and centered counts more), and
  detections raise the cells around where they point. It's renormalized every update, so
  probability flows toward places nobody has checked properly.
"""
from __future__ import annotations

import math

MAX_PITCH = 65        # ignore cameras pointed at the floor or ceiling
POD_MAX = 0.2         # chance per update (5/s) of spotting the target dead-center, right in front
POD_FALLOFF_M = 4.0   # looks get less reliable with distance
BOOST_SIGMA_M = 0.8   # how far a detection's evidence spreads around where it points
BOOST_GAIN = 6.0      # how strongly a detection raises probability (scaled by its score)
HEAT_LEVELS = "0123456789abcdefghijklmnopqrstuvwxyz"


def look_quality(d: float, off_deg: float, half_fov: float) -> float:
    """0..1: how well a camera sees something d meters away, off_deg from the center of its view."""
    edge = min(1.0, abs(off_deg) / half_fov)
    return math.exp(-d / POD_FALLOFF_M) * (0.3 + 0.7 * math.cos(edge * math.pi / 2))


class Coverage:
    def __init__(self, room: dict, cell: float = 0.5) -> None:
        self.cell = cell
        self.x0 = -room["width"] / 2
        self.cols = round(room["width"] / cell)
        self.rows = round(room["depth"] / cell)
        self.fov = room["cameraFovDeg"]
        self.range = room["coneLength"]
        n = self.cols * self.rows
        self.looked = [False] * n
        self.prob = [1 / n] * n

    def reset(self) -> None:
        n = len(self.looked)
        self.looked = [False] * n
        self.prob = [1 / n] * n

    def cone(self, x: float, y: float, heading: float) -> list[tuple[int, float, float]]:
        """Cells inside a camera's view: (cell index, distance m, degrees off the view's center)."""
        h = math.radians(heading)
        hx, hy = math.sin(h), -math.cos(h)  # heading 0 = toward the stage (-y)
        half = self.fov / 2
        cos_half = math.cos(math.radians(half))
        r, cell = self.range, self.cell
        c0 = max(0, math.floor((x - r - self.x0) / cell))
        c1 = min(self.cols - 1, math.floor((x + r - self.x0) / cell))
        r0 = max(0, math.floor((y - r) / cell))
        r1 = min(self.rows - 1, math.floor((y + r) / cell))
        out = []
        for row in range(r0, r1 + 1):
            dy = (row + 0.5) * cell - y
            for col in range(c0, c1 + 1):
                dx = self.x0 + (col + 0.5) * cell - x
                d = math.hypot(dx, dy)
                if d > r or d < cell:  # skip the cell the phone is standing in
                    continue
                c = (dx * hx + dy * hy) / d
                if c >= cos_half:
                    out.append((row * self.cols + col, d, math.degrees(math.acos(min(1.0, c)))))
        return out

    def cells_in_cone(self, x: float, y: float, heading: float) -> list[int]:
        return [i for i, _, _ in self.cone(x, y, heading)]

    def update(self, viewers: dict[str, tuple[float, float, float, float | None]]) -> dict[str, int]:
        """viewers: phone id → (x, y, heading, pitch) for every phone with a live camera.
        Marks looked cells, lowers probability where cameras looked, and returns how many cells
        each phone looked at for the first time."""
        fresh: dict[str, int] = {}
        half = self.fov / 2
        for pid, (x, y, heading, pitch) in viewers.items():
            if pitch is not None and abs(pitch) > MAX_PITCH:
                continue
            for c, d, off in self.cone(x, y, heading):
                if not self.looked[c]:
                    self.looked[c] = True
                    fresh[pid] = fresh.get(pid, 0) + 1
                # "if it were here, this look would have caught it with chance POD": it wasn't caught
                self.prob[c] *= 1 - POD_MAX * look_quality(d, off, half)
        self._normalize()
        return fresh

    def boost(self, x: float, y: float, score: float) -> None:
        """A detection at (x, y) with this confidence: raise probability around it."""
        reach = 3 * BOOST_SIGMA_M
        c0 = max(0, math.floor((x - reach - self.x0) / self.cell))
        c1 = min(self.cols - 1, math.floor((x + reach - self.x0) / self.cell))
        r0 = max(0, math.floor((y - reach) / self.cell))
        r1 = min(self.rows - 1, math.floor((y + reach) / self.cell))
        for row in range(r0, r1 + 1):
            for col in range(c0, c1 + 1):
                dx = self.x0 + (col + 0.5) * self.cell - x
                dy = (row + 0.5) * self.cell - y
                g = math.exp(-(dx * dx + dy * dy) / (2 * BOOST_SIGMA_M ** 2))
                self.prob[row * self.cols + col] *= 1 + BOOST_GAIN * score * g
        self._normalize()

    def _normalize(self) -> None:
        total = sum(self.prob)
        if total > 0:
            self.prob = [p / total for p in self.prob]

    def snapshot(self) -> dict:
        top = max(self.prob) or 1
        last = len(HEAT_LEVELS) - 1
        return {
            "cols": self.cols, "rows": self.rows, "cell": self.cell, "x0": self.x0,
            "cells": "".join("1" if seen else "0" for seen in self.looked),
            "heat": "".join(HEAT_LEVELS[round(last * p / top)] for p in self.prob),  # relative to the hottest cell
            "searched": sum(self.looked) / len(self.looked),
        }
