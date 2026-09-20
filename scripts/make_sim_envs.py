"""Draw the simulator's built-in floor plans into web/sim/envs/.

These are stand-ins drawn by hand until the real walkthrough scans exist: a scan imported in the
simulator (New environment → From a 3D scan) replaces them with the building as it actually is.

Run:  uv run python scripts/make_sim_envs.py
"""
from __future__ import annotations

import json
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "web" / "sim" / "envs"


class Plan:
    """A grid you draw on in meters. Walls are one cell thick."""

    def __init__(self, width: float, depth: float, cell: float) -> None:
        self.cell = cell
        self.cols, self.rows = round(width / cell), round(depth / cell)
        self.g = [["."] * self.cols for _ in range(self.rows)]
        self.rooms: list[dict] = []
        self.entries: list[dict] = []

    def _c(self, m: float, limit: int) -> int:
        return max(0, min(limit - 1, round(m / self.cell)))

    def fill(self, x1: float, y1: float, x2: float, y2: float, ch: str) -> None:
        """Cells from (x1, y1) up to but not including (x2, y2), in meters."""
        for r in range(self._c(y1, self.rows + 1), max(self._c(y1, self.rows + 1) + 1, round(y2 / self.cell))):
            for c in range(self._c(x1, self.cols + 1), max(self._c(x1, self.cols + 1) + 1, round(x2 / self.cell))):
                if r < self.rows and c < self.cols:
                    self.g[r][c] = ch

    def hwall(self, y: float, x1: float, x2: float) -> None:
        r = self._c(y, self.rows)
        for c in range(self._c(x1, self.cols), self._c(x2, self.cols) + 1):
            self.g[r][c] = "#"

    def vwall(self, x: float, y1: float, y2: float) -> None:
        c = self._c(x, self.cols)
        for r in range(self._c(y1, self.rows), self._c(y2, self.rows) + 1):
            self.g[r][c] = "#"

    def border(self) -> None:
        w, d = self.cols * self.cell, self.rows * self.cell
        self.hwall(0, 0, w); self.hwall(d, 0, w); self.vwall(0, 0, d); self.vwall(w, 0, d)

    def hdoor(self, y: float, x: float, width: float = 1.0) -> None:
        """A doorway in a horizontal wall at height y, starting at x."""
        r = self._c(y, self.rows)
        for c in range(self._c(x, self.cols), self._c(x, self.cols) + max(1, round(width / self.cell))):
            self.g[r][c] = "d"

    def vdoor(self, x: float, y: float, width: float = 1.0) -> None:
        c = self._c(x, self.cols)
        for r in range(self._c(y, self.rows), self._c(y, self.rows) + max(1, round(width / self.cell))):
            self.g[r][c] = "d"

    def furniture(self, x: float, y: float, w: float, h: float) -> None:
        self.fill(x, y, x + w, y + h, "o")

    def room(self, name: str, x: float, y: float) -> None:
        self.rooms.append({"name": name, "x": x, "y": y})

    def entry(self, name: str, x: float, y: float) -> None:
        self.entries.append({"name": name, "x": x, "y": y})

    def save(self, env_id: str, name: str, description: str) -> None:
        OUT.mkdir(parents=True, exist_ok=True)
        spec = {"name": name, "description": description, "source": "layout", "cell": self.cell,
                "wallHeightM": 2.6, "entries": self.entries, "rooms": self.rooms,
                "grid": ["".join(row) for row in self.g]}
        (OUT / f"{env_id}.json").write_text(json.dumps(spec, indent=1) + "\n")
        print(f"{env_id}: {self.cols}×{self.rows} cells at {self.cell} m")


def apartment() -> None:
    p = Plan(12, 9, 0.25)
    p.border()
    # bedrooms and the bathroom along the top, a hallway under them, kitchen and living room below
    p.hwall(3.75, 0, 12)
    p.vwall(4.5, 0, 3.75)
    p.vwall(6.75, 0, 3.75)
    p.hwall(5.0, 0, 4.5)
    p.vwall(4.5, 5.0, 9)
    p.hdoor(3.75, 3.0, 0.9); p.room("Bedroom 1", 2.25, 1.9)
    p.hdoor(3.75, 5.2, 0.8); p.room("Bathroom", 5.6, 1.9)
    p.hdoor(3.75, 7.5, 0.9); p.room("Bedroom 2", 9.4, 1.9)
    p.hdoor(5.0, 2.5, 1.0); p.room("Kitchen", 2.25, 7.0)
    p.vdoor(4.5, 6.5, 1.5); p.room("Living room", 8.25, 7.0)
    p.room("Hall", 8.0, 4.4)
    # a walk-in closet off bedroom 1: the kind of place a sweep forgets
    p.hwall(1.5, 0, 1.75); p.vwall(1.75, 0, 1.5); p.vdoor(1.75, 0.5, 0.75); p.room("Closet", 0.9, 0.8)
    # the hall runs straight into the living room
    p.hwall(5.0, 4.5, 12); p.hdoor(5.0, 6.0, 3.0)
    p.hdoor(9.0, 10.0, 1.0); p.entry("Front door", 10.5, 8.6)
    # furniture blocks the way but not the view
    p.furniture(2.4, 0.4, 1.8, 2.0)     # bed 1
    p.furniture(9.6, 0.4, 2.0, 1.6)     # bed 2
    p.furniture(7.1, 2.4, 1.4, 0.6)     # desk
    p.furniture(5.9, 0.4, 0.7, 1.6)     # bath
    p.furniture(0.4, 5.4, 0.6, 3.2)     # kitchen counter
    p.furniture(1.9, 6.6, 1.4, 0.9)     # kitchen island
    p.furniture(5.2, 7.9, 2.4, 0.8)     # sofa
    p.furniture(5.8, 6.4, 1.2, 0.7)     # coffee table
    p.furniture(9.4, 5.6, 1.6, 1.0)     # dining table
    p.save("apartment", "Two-bedroom apartment",
           "Stand-in layout, 12 × 9 m: two bedrooms, a bathroom and a walk-in closet off a hall, "
           "kitchen and living room. One way in.")


def eng_floor() -> None:
    p = Plan(48, 25, 0.5)
    p.border()
    # one long corridor, classrooms to the north, labs and the lobby to the south
    p.hwall(10, 0, 48); p.hwall(13, 0, 48)
    for i in range(1, 6):
        p.vwall(i * 8, 0, 10)
    for i in range(6):
        x = i * 8
        p.hdoor(10, x + 1.5, 1.0)
        if i % 2 == 0:
            p.hdoor(10, x + 5.5, 1.0)   # the bigger rooms have a second door
        p.room(f"E5-{101 + i}", x + 4, 5)
        for row in range(3):            # rows of benches
            p.furniture(x + 1.5, 2 + row * 2.5, 5, 1)
    for x in (12, 20, 28, 36):
        p.vwall(x, 13, 25)
    labs = [(0, 12, "Robotics lab"), (12, 20, "Machine shop"), (28, 36, "Electronics lab"), (36, 48, "Design studio")]
    for x1, x2, name in labs:
        p.hdoor(13, x1 + 2, 1.0)
        p.room(name, (x1 + x2) / 2, 19)
        p.furniture(x1 + 2, 16, x2 - x1 - 4, 1.5)
        if name != "Machine shop":
            p.furniture(x1 + 2, 20.5, x2 - x1 - 4, 1.5)
    # the machine shop has a storeroom at the back you only reach through the shop
    p.hwall(21, 12, 20); p.hdoor(21, 17, 1.0); p.room("Stores", 16, 23)
    # lobby: open to the corridor, main doors on the south wall
    p.hdoor(13, 21, 6.0); p.room("Lobby", 24, 19); p.room("Corridor", 30, 11.75)
    p.hdoor(25, 23, 2.0); p.entry("Main entrance", 24, 24)
    p.vdoor(0, 11, 1.5); p.entry("West stairs", 0.75, 11.75)
    p.vdoor(48, 11, 1.5); p.entry("East stairs", 47.25, 11.75)
    p.save("eng-floor", "Engineering building, one floor",
           "Stand-in layout, 48 × 25 m: six classrooms and four labs off one long corridor, a lobby, "
           "and a storeroom you can only reach through the machine shop. Three ways in.")


if __name__ == "__main__":
    apartment()
    eng_floor()
