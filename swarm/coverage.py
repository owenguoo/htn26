"""Coverage grid over the floor plan: which cells has any camera looked at?"""
from __future__ import annotations

import math

MAX_PITCH = 65  # ignore cameras pointed at the floor or ceiling


class Coverage:
    def __init__(self, room: dict, cell: float = 0.5) -> None:
        self.cell = cell
        self.x0 = -room["width"] / 2
        self.cols = round(room["width"] / cell)
        self.rows = round(room["depth"] / cell)
        self.fov = room["cameraFovDeg"]
        self.range = room["coneLength"]
        self.looked = [False] * (self.cols * self.rows)

    def reset(self) -> None:
        self.looked = [False] * len(self.looked)

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

    def update(self, viewers: dict[str, tuple[float, float, float, float | None]]) -> dict[str, int]:
        """viewers: phone id → (x, y, heading, pitch) for every phone with a live camera.
        Returns how many cells each phone looked at for the first time."""
        fresh: dict[str, int] = {}
        for pid, (x, y, heading, pitch) in viewers.items():
            if pitch is not None and abs(pitch) > MAX_PITCH:
                continue
            for c in self.cells_in_cone(x, y, heading):
                if not self.looked[c]:
                    self.looked[c] = True
                    fresh[pid] = fresh.get(pid, 0) + 1
        return fresh

    def snapshot(self) -> dict:
        return {
            "cols": self.cols, "rows": self.rows, "cell": self.cell, "x0": self.x0,
            "cells": "".join("1" if seen else "0" for seen in self.looked),
            "searched": sum(self.looked) / len(self.looked),
        }
