"""Coverage and probability over the floor plan.

- looked: which cells any camera has looked at (drives "area searched" and the planner).
- prob: where somebody still missing probably is (a Bayesian search map). It starts even. Every
  look lowers the cells it covered by how good the look was (close and centered counts more), and
  detections raise the cells around where they point. It's renormalized every update, so
  probability flows toward places nobody has checked properly. Finding somebody empties the map
  where they are (clear_around), which is what sends the swarm after the next person instead of
  leaving everybody staring at the one they just found.
"""
from __future__ import annotations

import math

MAX_PITCH = 65        # ignore cameras pointed at the floor or ceiling
LOOK_MIN = 0.25       # a cell only counts as searched once a camera had this good a look at it
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
                q = look_quality(d, off, half)
                # Being inside the cone isn't a search. The far edge of a 5 m cone is a smear the
                # detector can't work with, so only a look good enough to have caught somebody
                # marks the cell — otherwise a single spin "searches" the whole disc around you.
                if q >= LOOK_MIN and not self.looked[c]:
                    self.looked[c] = True
                    fresh[pid] = fresh.get(pid, 0) + 1
                # "if it were here, this look would have caught it with chance POD": it wasn't caught
                self.prob[c] *= 1 - POD_MAX * q
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

    def adjust(self, factor: float, x: float | None = None, y: float | None = None, radius: float = 2.0,
               cells: list[int] | None = None) -> None:
        """Evidence that isn't a camera look, e.g. "last seen near the stage" or "staff already checked the
        back rows": multiply the probability around (x, y) (fading out over about `radius` meters), or of
        the given cells, by `factor` (>1 more likely, <1 less likely), then renormalize."""
        if cells is not None:
            for c in cells:
                self.prob[c] *= factor
        else:
            sigma = max(radius, self.cell) / 2
            for i in range(len(self.prob)):
                row, col = divmod(i, self.cols)
                d2 = (self.x0 + (col + 0.5) * self.cell - x) ** 2 + ((row + 0.5) * self.cell - y) ** 2
                self.prob[i] *= 1 + (factor - 1) * math.exp(-d2 / (2 * sigma * sigma))
        floor = 1e-6 / len(self.prob)  # never exactly zero: "ruled out" can be wrong
        self.prob = [max(p, floor) for p in self.prob]
        self._normalize()

    def clear_around(self, x: float, y: float, radius: float = 2.0) -> None:
        """Somebody has been found here and has responders coming: take the probability out of this
        spot so the rest of the swarm goes looking for whoever else is missing."""
        self.adjust(0.02, x, y, radius=radius)

    def _normalize(self) -> None:
        total = sum(self.prob)
        if total > 0:
            self.prob = [p / total for p in self.prob]

    def heat(self) -> str:
        """The probability field in 36 steps, log-scaled around the uniform prior.

        Two encodings failed before this one. Linear against the hottest cell
        threw the map away the moment a sighting landed: boosts compound until
        one cell holds most of the mass, and `round(35 * p / top)` then put 1188
        of 1200 cells on step 0. Log across the field's own extremes moved the
        problem rather than fixing it — the span from the most-cleared cell to
        the hottest is set by two outliers, so the body of the floor bunched up
        at the bottom and the map went blank again.

        The reference that means something is the uniform prior, 1/cells: the
        value every cell starts at, and the one it keeps while nobody has looked
        there. Step 17 or so is "no information", above it is "more likely than
        average", below it is "somebody has swept this". Each half is log-scaled
        over its own range, so one enormous spike cannot flatten the rest and a
        heavily cleared corner cannot either.

        Consumers read the steps directly (`heatLevels` in `web/room.js` and its
        Swift mirror) — they must not renormalise to the hottest cell, or the
        anchor is lost.
        """
        last = len(HEAT_LEVELS) - 1
        n = len(self.prob)
        if not n:
            return ""
        mid = sorted(self.prob)[n // 2]
        top = max(self.prob)
        floor = min((p for p in self.prob if p > 0), default=0)
        # A half with no real range in it is flat, and must be read as flat: the
        # untouched cells of a room nobody has swept differ from each other only
        # in the last bits of the renormalisation, and dividing by that span
        # turned float noise into a saturated blue sheet over the whole floor.
        # SPREAD is the smallest ratio worth a ramp.
        SPREAD = 1.05
        up = math.log(top / mid) if top > mid * SPREAD and mid > 0 else 0.0
        down = math.log(mid / floor) if floor > 0 and mid > floor * SPREAD else 0.0
        out = []
        for p in self.prob:
            if p >= mid:
                level = 0.5 + (0.5 * math.log(p / mid) / up if up else 0.0)
            elif p > 0:
                level = 0.5 - (0.5 * math.log(mid / p) / down if down else 0.0)
            else:
                level = 0.0
            out.append(HEAT_LEVELS[round(last * min(1.0, max(0.0, level)))])
        return "".join(out)

    def snapshot(self) -> dict:
        return {
            "cols": self.cols, "rows": self.rows, "cell": self.cell, "x0": self.x0,
            "cells": "".join("1" if seen else "0" for seen in self.looked),
            "heat": self.heat(),
            "searched": sum(self.looked) / len(self.looked),
        }
