"""Look-count coverage grid over the floor plan.

Each cell counts how many separate times a camera has looked at it. A look is counted
when a cell enters a phone's view cone; the same phone only counts it again after the
cell has been out of its view for REARM_MS. Staring doesn't increase the count, and
gyro jitter at the cone's edge doesn't either.
"""
from __future__ import annotations

import math

REARM_MS = 1500
MAX_PITCH = 65  # ignore cameras pointed at the floor or ceiling


class Coverage:
    def __init__(self, room: dict, cell: float = 0.5) -> None:
        self.cell = cell
        self.x0 = -room["width"] / 2
        self.cols = round(room["width"] / cell)
        self.rows = round(room["depth"] / cell)
        self.fov = room["cameraFovDeg"]
        self.range = room["coneLength"]
        self.counts = [0] * (self.cols * self.rows)
        self.last_in_view: dict[str, dict[int, float]] = {}  # phone id → cell → last time in view

    def reset(self) -> None:
        self.counts = [0] * len(self.counts)
        self.last_in_view.clear()

    def cells_in_cone(self, x: float, y: float, heading: float) -> list[int]:
        h = math.radians(heading)
        hx, hy = math.sin(h), -math.cos(h)  # heading 0 = toward the stage (-y)
        cos_half = math.cos(math.radians(self.fov / 2))
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
                if (dx * hx + dy * hy) / d >= cos_half:
                    out.append(row * self.cols + col)
        return out

    def update(self, viewers: dict[str, tuple[float, float, float, float | None]], now: float) -> None:
        """viewers: phone id → (x, y, heading, pitch) for every phone with a live camera."""
        for pid in list(self.last_in_view):
            if pid not in viewers:
                del self.last_in_view[pid]
        for pid, (x, y, heading, pitch) in viewers.items():
            seen = self.last_in_view.setdefault(pid, {})
            if pitch is not None and abs(pitch) > MAX_PITCH:
                continue
            for c in self.cells_in_cone(x, y, heading):
                last = seen.get(c)
                if last is None or now - last > REARM_MS:
                    self.counts[c] += 1
                seen[c] = now

    def snapshot(self) -> dict:
        looked = sum(1 for c in self.counts if c)
        return {
            "cols": self.cols, "rows": self.rows, "cell": self.cell, "x0": self.x0,
            "cells": "".join(str(min(c, 9)) for c in self.counts),
            "searched": looked / len(self.counts),
        }
