"""The commander's problem: what the central intelligence is trained on.

swarm/simulator.py answers "how fast can a team sweep this floor". With one still casualty and
perfect information that is route planning, and a coverage planner is already very good at it.
This module wraps the same building, movement and sight model in the decisions a real incident
commander has to make, where a report doesn't always mean what it says:

  * "Room clear" may be a physical search, or a crew calling in from the doorway. A casualty who
    can't answer is missed by the second, and crews sometimes take that shortcut unasked.
  * A witness says where they last saw the person. Often right, sometimes the room next door,
    sometimes nowhere near.
  * A doorway may be blocked. Nobody knows until a crew gets there.
  * "On my way" is not "with the casualty". A responder can be stopped by a blocked door after
    acknowledging, and the rescue only counts crews who have physically arrived.

The commander sees reports and gives room-level orders; it never sees the hidden incident.
`CommandSim` is a Gym-style environment (reset / step, JSON observations) for training against.
`compare` runs the same building and the same hidden incident under two policies, with matched
walking speeds, observation rules and dice, for the referee's side-by-side.

    uv run python -m swarm.command_sim compare --env eng-floor --seed 3
    uv run python -m swarm.command_sim evaluate --env eng-floor --episodes 50
"""
from __future__ import annotations

import argparse
import json
import math
import random
import statistics
from dataclasses import dataclass, field

import numpy as np

from .planner import DWELL_S, HEADINGS, TURN_DEG_PER_S, UPDATES_PER_S
from .simulator import (ARRIVE_M, DOOR, WALK_M_PER_S, Environment, load_environment, move_along,
                        turn_between, turn_toward)

CALL_S = 6.0               # calling into a room from its doorway and listening for an answer
P_RESPONSIVE = 0.5         # the casualty can answer a call
P_ANSWER_HEARD = 0.9       # ...and if they can, the crew at the door hears it
P_SHORTCUT = 0.25          # a crew told to search a room calls in from the door instead
P_DOOR_BLOCKED = 0.2       # each ordinary doorway, independently (at most MAX_BLOCKED)
MAX_BLOCKED = 2
BLOCKABLE_WIDTH_M = 1.6    # wider openings than this don't get blocked by a fallen cabinet
P_WITNESS = (0.55, 0.30)   # right room; else a neighboring room; else anywhere
SWEEP_DONE = 0.1           # a physical search ends when this little of the room is left unseen
MIN_ROOM_M2 = 1.0
DECIDE_EVERY_S = 5.0       # the commander is consulted at least this often, and on every report

REWARD_PER_S = -0.1
REWARD_FOUND = 20.0
REWARD_RESCUED = 100.0
REWARD_UNNECESSARY_TRIP = -5.0


# ---------------------------------------------------------------- rooms and doorways
@dataclass
class Layout:
    room_of: np.ndarray          # cell → room id, -1 for doorways, furniture, walls
    rooms: list[dict]
    doors: list[dict]


def layout(env: Environment) -> Layout:
    """Doorway cells ('d') divide the floor into rooms. A plan with none is one big room."""
    hit = env.__dict__.get("_layout")
    if hit:
        return hit
    n = env.rows * env.cols
    is_door = (env.grid == DOOR).ravel()
    room_of = np.full(n, -1, np.int32)
    door_of = np.full(n, -1, np.int32)

    def flood(start: int, member, mark: np.ndarray, value: int) -> list[int]:
        mark[start] = value
        stack, cells = [start], []
        while stack:
            i = stack.pop()
            cells.append(i)
            for j, _ in env._neighbors[i]:
                if mark[j] == -1 and member(j):
                    mark[j] = value
                    stack.append(j)
        return cells

    rooms, doors = [], []
    labels = {}   # a label names the room whose floor is nearest it (labels often sit on a table)
    for r in env.spec.get("rooms") or []:
        labels[env.nearest_walkable(float(r["x"]), float(r["y"]), among=env.floor_idx[~is_door[env.floor_idx]])] = r["name"]
    for c in env.floor_idx:
        c = int(c)
        if is_door[c] or room_of[c] != -1:
            continue
        cells = flood(c, lambda j: env.floor[j] and not is_door[j], room_of, len(rooms))
        if len(cells) * env.cell ** 2 < MIN_ROOM_M2:
            room_of[cells] = -2  # a sliver: not a room anyone would name
            continue
        arr = np.array(cells)
        r, col = np.divmod(arr, env.cols)
        center = int(arr[int(np.argmin((r - r.mean()) ** 2 + (col - col.mean()) ** 2))])
        name = next((labels[k] for k in cells if k in labels), None)
        x, y = env.xy(center)
        rooms.append({"id": len(rooms), "name": name or f"Area {len(rooms) + 1}", "cells": arr, "center": center,
                      "areaM2": round(len(cells) * env.cell ** 2, 1), "x": x, "y": y,
                      "anchors": [a for a in env.anchors if a in set(cells)] or [center]})
    room_of[room_of == -2] = -1
    for c in np.flatnonzero(is_door & env.floor):
        c = int(c)
        if door_of[c] != -1:
            continue
        cells = flood(c, lambda j: is_door[j] and env.floor[j], door_of, len(doors))
        beside = sorted({int(room_of[j]) for i in cells for j, _ in env._neighbors[i] if room_of[j] >= 0})
        xs, ys = zip(*(env.xy(i) for i in cells))
        width = max(max(xs) - min(xs), max(ys) - min(ys)) + env.cell
        doors.append({"id": len(doors), "cells": cells, "rooms": beside, "x": sum(xs) / len(xs), "y": sum(ys) / len(ys),
                      "widthM": round(width, 2), "blockable": len(beside) == 2 and width <= BLOCKABLE_WIDTH_M})
    for room in rooms:
        room["doors"] = [d["id"] for d in doors if room["id"] in d["rooms"]]
    out = Layout(room_of, rooms, doors)
    env.__dict__["_layout"] = out
    return out


def with_blocked(base: Environment, door_ids: frozenset[int]) -> Environment:
    """The same building with these doorways impassable (and you can't see through them)."""
    if not door_ids:
        return base
    cache = base.__dict__.setdefault("_variants", {})
    if door_ids not in cache:
        if len(cache) > 48:
            cache.clear()
        lay = layout(base)
        grid = [list(row) for row in base.spec["grid"]]
        for d in door_ids:
            for c in lay.doors[d]["cells"]:
                r, col = divmod(c, base.cols)
                grid[r][col] = "#"
        cache[door_ids] = Environment({**base.spec, "grid": ["".join(row) for row in grid]})
    return cache[door_ids]


# ---------------------------------------------------------------- the hidden incident
@dataclass
class Incident:
    seed: int
    casualty: int                 # cell
    room: int
    responsive: bool
    blocked: frozenset[int]
    witness_room: int
    witness_kind: str             # "right" | "neighbor" | "wrong": for the referee only


def make_incident(env: Environment, seed: int, casualty_xy: tuple[float, float] | None = None) -> Incident:
    lay, rng = layout(env), random.Random(f"incident:{seed}")
    in_rooms = env.floor_idx[lay.room_of[env.floor_idx] >= 0]
    if casualty_xy:
        casualty = env.nearest_walkable(*casualty_xy, among=in_rooms)
    else:
        casualty = int(in_rooms[rng.randrange(len(in_rooms))])
    room = int(lay.room_of[casualty])
    blocked = [d["id"] for d in lay.doors if d["blockable"] and rng.random() < P_DOOR_BLOCKED]
    rng.shuffle(blocked)
    blocked = blocked[:MAX_BLOCKED]
    while blocked and not with_blocked(env, frozenset(blocked)).floor[casualty]:
        blocked.pop()  # the casualty can always be reached, if not by the obvious way
    responsive = rng.random() < P_RESPONSIVE
    u = rng.random()
    neighbors = sorted({r for d in lay.doors if room in d["rooms"] for r in d["rooms"]} - {room})
    if u < P_WITNESS[0] or len(lay.rooms) == 1:
        witness, kind = room, "right"
    elif u < P_WITNESS[0] + P_WITNESS[1] and neighbors:
        witness, kind = rng.choice(neighbors), "neighbor"
    else:
        witness, kind = rng.choice([r["id"] for r in lay.rooms if r["id"] != room]), "wrong"
    return Incident(seed, casualty, room, responsive, frozenset(blocked), witness, kind)


# ---------------------------------------------------------------- the environment
@dataclass
class Crew:
    id: int
    x: float
    y: float
    heading: float
    cell: int
    path: list = field(default_factory=list)
    walked: float = 0.0
    status: str = "idle"          # idle | enroute | searching | calling | responding | with_casualty
    order: dict | None = None
    method: str | None = None     # how this crew is really checking the room: "physical" | "voice"
    dest: int | None = None
    timer: float = 0.0
    look: dict | None = None
    unseen: np.ndarray | None = None


class CommandSim:
    """reset() → observation; step(orders) → (observation, reward, done, info).

    An order is {"crew": id, "do": "search" | "call" | "respond" | "hold", "room": id}.
    Observations are plain JSON (see observe()); nothing in them comes from the hidden incident
    except through what crews have reported."""

    def __init__(self, env: Environment | str, seed: int = 0, rescuers: int = 3, responders: int = 2,
                 max_time: float = 900.0, walk_speed: float = WALK_M_PER_S, dt: float = 0.25,
                 casualty: tuple[float, float] | None = None, record: bool = False) -> None:
        self.base = load_environment(env) if isinstance(env, str) else env
        self.lay = layout(self.base)
        self.seed, self.n, self.needed = seed, max(1, rescuers), max(1, min(responders, rescuers))
        self.max_time, self.speed, self.dt, self.recording = max_time, walk_speed, dt, record
        self.casualty_xy = casualty
        self.reset()

    # ---- dice that fall the same way for every policy facing this incident
    def roll(self, *key) -> float:
        return random.Random(f"{self.seed}|{'|'.join(map(str, key))}").random()

    def reset(self) -> dict:
        self.incident = make_incident(self.base, self.seed, self.casualty_xy)
        self.truth = with_blocked(self.base, self.incident.blocked)
        self.known_blocked: set[int] = set()
        self.known = self.base
        self.t, self.tick, self.done = 0.0, 0, False
        self.rooms = [{"status": "unknown", "checkedBy": None, "checkedAt": None, "visits": 0} for _ in self.lay.rooms]
        self.reports: list[dict] = []
        self._unread = 0
        self.found_at = self.found_by = self.rescued_at = None
        self.contacts: list[int] = []
        self.unnecessary = self.physical = self.voice = self.false_clears = 0
        self.total_reward = 0.0
        self._last_decision = -math.inf
        self.frames: list[list] = []
        self.timeline: list[dict] = []
        entry = self.base.entries[0]["cell"]
        near = np.argsort(self.base.field(entry)[self.base.floor_idx], kind="stable")
        self.crews = []
        for i in range(self.n):
            cell = int(self.base.floor_idx[near[min(i, len(near) - 1)]])
            x, y = self.base.xy(cell)
            heading = math.degrees(math.atan2(self.base.width / 2 - x, -(self.base.depth / 2 - y))) % 360
            self.crews.append(Crew(i, x, y, heading, cell))
        w = self.lay.rooms[self.incident.witness_room]
        self.report("witness", None, f"Witness at the entrance: “I last saw them in {w['name']}.”", room=w["id"])
        if self.recording:
            self.snap()
        return self.observe()

    def report(self, kind: str, crew: int | None, text: str, **extra) -> None:
        self.reports.append({"t": round(self.t, 1), "kind": kind, "crew": crew, "text": text, **extra})

    # ---- what the commander is told
    def observe(self) -> dict:
        new, self._unread = self.reports[self._unread:], len(self.reports)
        crews = []
        for c in self.crews:
            room = int(self.lay.room_of[c.cell])
            eta = {}
            for r in self.lay.rooms:
                d = float(self.known.field(r["center"])[c.cell])
                eta[r["id"]] = round(d / self.speed, 1) if math.isfinite(d) else None
            to_casualty = None
            if self.found_at is not None:
                d = float(self.known.field(self.incident.casualty)[c.cell])
                to_casualty = round(d / self.speed, 1) if math.isfinite(d) else None
            crews.append({"id": c.id, "status": c.status, "room": room if room >= 0 else None,
                          "x": round(c.x, 2), "y": round(c.y, 2), "order": c.order,
                          "etaS": eta, "etaCasualtyS": to_casualty})
        rooms = [{"id": r["id"], "name": r["name"], "areaM2": r["areaM2"], "doors": r["doors"], **self.rooms[r["id"]]}
                 for r in self.lay.rooms]
        doors = [{"id": d["id"], "rooms": d["rooms"], "blocked": True if d["id"] in self.known_blocked else None}
                 for d in self.lay.doors]
        found = self.found_at is not None
        return {"t": round(self.t, 1), "done": self.done, "crews": crews, "rooms": rooms, "doors": doors,
                "casualty": {"found": found, "room": self.incident.room if found else None,
                             "contacts": len(self.contacts), "needed": self.needed},
                "newReports": new, "reports": self.reports}

    # ---- orders
    def apply(self, order: dict) -> None:
        try:
            crew, do = self.crews[int(order["crew"])], order["do"]
        except (KeyError, IndexError, TypeError, ValueError):
            return
        if crew.status == "with_casualty" or do not in ("search", "call", "respond", "hold"):
            return
        crew.path, crew.look, crew.unseen, crew.method, crew.dest = [], None, None, None, None
        if do == "hold":
            crew.status, crew.order = "idle", None
            return
        if do == "respond":
            if self.found_at is None:
                return
            if sum(c.status in ("responding", "with_casualty") for c in self.crews) >= self.needed:
                self.wasted_trip()
            crew.order, crew.dest = {"do": "respond"}, self.incident.casualty
            if self.route(crew, "the casualty"):
                crew.status = "responding"
                self.report("ack", crew.id, "On my way to the casualty.")
            return
        try:
            room = self.lay.rooms[int(order["room"])]
        except (KeyError, IndexError, TypeError, ValueError):
            return
        state = self.rooms[room["id"]]
        repeat_call = do == "call" and state["status"] == "voice_clear"   # nobody answered the first time either
        if state["status"] == "searched_clear" or repeat_call or self.found_at is not None:
            self.wasted_trip()
        state["visits"] += 1
        crew.order = {"do": do, "room": room["id"]}
        crew.method = "voice" if do == "call" or self.roll("shortcut", crew.id, room["id"], state["visits"]) < P_SHORTCUT else "physical"
        if crew.method == "voice" and room["doors"]:
            field_ = self.known.field(crew.cell)
            crew.dest = min((c for d in room["doors"] for c in self.lay.doors[d]["cells"]), key=lambda c: float(field_[c]))
        else:
            crew.dest = room["center"]
        if self.route(crew, room["name"]):
            crew.status = "enroute"
            self.report("ack", crew.id, f"On my way to {room['name']}.", room=room["id"])
        elif state["status"] == "unknown":
            state["status"] = "unreachable"

    def wasted_trip(self) -> None:
        self.unnecessary += 1
        self.total_reward += REWARD_UNNECESSARY_TRIP

    def route(self, crew: Crew, where: str) -> bool:
        path = self.known.path(crew.cell, crew.dest) if self.known.walkable[crew.cell] else []
        if not path:
            self.report("no_route", crew.id, f"No way through to {where} that we know of.")
            crew.status, crew.order, crew.dest = "idle", None, None
            return False
        crew.path = path[1:]
        return True

    # ---- the world moving
    def step(self, orders: list[dict] | None = None) -> tuple[dict, float, bool, dict]:
        before = self.total_reward
        for order in orders or []:
            self.apply(order)
        self._last_decision = self.t
        seen = len(self.reports)
        while not self.done:
            self.advance()
            idle = any(c.status == "idle" for c in self.crews)
            if len(self.reports) > seen or self.t - self._last_decision >= (2.0 if idle else DECIDE_EVERY_S):
                break
        return self.observe(), self.total_reward - before, self.done, self.metrics()

    def advance(self) -> None:
        dt = self.dt
        for crew in self.crews:
            self.move(crew, dt)
        if self.found_at is None:
            for crew in self.crews:
                cells, pd = self.truth.look(crew.cell, crew.heading, dt * UPDATES_PER_S)
                if crew.unseen is not None:
                    crew.unseen[cells] *= 1 - pd
                at = np.flatnonzero(cells == self.incident.casualty)
                if len(at) and self.roll("see", crew.id, self.tick) < pd[at[0]]:
                    self.find(crew, "Casualty in sight")
                    break
        self.t += dt
        self.tick += 1
        self.total_reward += REWARD_PER_S * dt
        if self.recording and self.tick % max(1, round(0.5 / dt)) == 0:
            self.snap()
        if len(self.contacts) >= self.needed:
            self.rescued_at, self.done = self.t, True
            self.total_reward += REWARD_RESCUED
            self.report("rescued", None, f"{self.needed} crew{'s' if self.needed != 1 else ''} with the casualty.")
        elif self.t >= self.max_time:
            self.done = True
            self.report("timeout", None, "Time is up.")
        if self.done and self.recording:
            self.snap()

    def move(self, crew: Crew, dt: float) -> None:
        if crew.path:
            was = (crew.x, crew.y, crew.cell)
            move_along(self.known, crew, dt, self.speed)
            if not self.truth.walkable[crew.cell]:     # walked into a doorway that turns out to be blocked
                blocked_cell = crew.cell
                crew.x, crew.y, crew.cell = was
                self.discover(crew, blocked_cell)
            return
        if crew.status == "enroute":
            self.arrive(crew)
        elif crew.status == "calling":
            room = self.lay.rooms[crew.order["room"]]
            if not turn_toward(crew, self.bearing(crew, room["x"], room["y"]), dt):
                return
            crew.timer -= dt
            if crew.timer <= 0:
                inside = self.incident.room == room["id"] and self.found_at is None
                if inside and self.incident.responsive and self.roll("answer", crew.id, room["id"]) < P_ANSWER_HEARD:
                    self.find(crew, "Someone answered from inside")
                else:
                    self.clear(crew, room, "voice")
        elif crew.status == "searching":
            self.sweep(crew, dt)
        elif crew.status == "responding":
            crew.status = "with_casualty"
            self.contacts.append(crew.id)
            self.report("arrived", crew.id, "With the casualty.")

    def bearing(self, crew: Crew, x: float, y: float) -> float:
        return math.degrees(math.atan2(x - crew.x, -(y - crew.y))) % 360

    def arrive(self, crew: Crew) -> None:
        room = self.lay.rooms[crew.order["room"]]
        if crew.method == "voice":
            crew.status, crew.timer = "calling", CALL_S
            return
        crew.status = "searching"
        crew.unseen = np.zeros(self.base.rows * self.base.cols)
        crew.unseen[room["cells"]] = 1 / len(room["cells"])
        self.report("entered", crew.id, f"Entering {room['name']} to search.", room=room["id"])

    def sweep(self, crew: Crew, dt: float) -> None:
        """A physical search: look from wherever shows the most of the room not yet seen, until
        almost none of it is left (the same look model as the hub's coverage map)."""
        room = self.lay.rooms[crew.order["room"]]
        if crew.look:
            if turn_toward(crew, crew.look["heading"], dt):
                crew.look["dwell"] -= dt
                if crew.look["dwell"] <= 0:
                    crew.look = None
            return
        if crew.unseen.sum() < SWEEP_DONE:
            self.clear(crew, room, "physical")
            return
        best = None
        for origin in {crew.cell, *room["anchors"]}:
            d = float(self.known.field(origin)[crew.cell])
            if not math.isfinite(d):
                continue
            idx, pd = self.truth.looks(origin)
            values = pd @ crew.unseen[idx]
            turn = np.abs(turn_between(crew.heading, np.arange(HEADINGS) * 360 / HEADINGS)) if origin == crew.cell else 0
            rates = values / (d / self.speed + turn / TURN_DEG_PER_S + DWELL_S)
            h = int(np.argmax(rates))
            if values[h] > 1e-4 and (best is None or rates[h] > best[0]):
                best = (float(rates[h]), origin, h * 360 / HEADINGS)
        if best is None:    # what's left is tucked behind something: go and stand on it
            spot = int(np.argmax(crew.unseen))
            best = (0.0, spot, crew.heading)
            if spot == crew.cell:
                crew.unseen[spot] = 0
                return
        crew.look = {"heading": best[2], "dwell": DWELL_S}
        if best[1] != crew.cell:
            crew.path = self.known.path(crew.cell, best[1])[1:]

    def clear(self, crew: Crew, room: dict, method: str) -> None:
        state = self.rooms[room["id"]]
        if method == "physical":
            self.physical += 1
            state.update(status="searched_clear", checkedBy=crew.id, checkedAt=round(self.t, 1))
            text = f"{room['name']} clear. Searched it."
        else:
            self.voice += 1
            if state["status"] != "searched_clear":
                state.update(status="voice_clear", checkedBy=crew.id, checkedAt=round(self.t, 1))
            text = f"{room['name']} clear. Called in from the door, no answer."
        if self.incident.room == room["id"]:
            self.false_clears += 1
        self.timeline.append({"t": round(self.t, 1), "room": room["id"], "status": state["status"]})
        self.report("clear", crew.id, text, room=room["id"], method=method)
        crew.status, crew.order, crew.unseen, crew.look = "idle", None, None, None

    def find(self, crew: Crew, how: str) -> None:
        room = self.lay.rooms[self.incident.room]
        self.found_at, self.found_by = self.t, crew.id
        self.total_reward += REWARD_FOUND
        self.rooms[room["id"]].update(status="found", checkedBy=crew.id, checkedAt=round(self.t, 1))
        self.timeline.append({"t": round(self.t, 1), "room": room["id"], "status": "found"})
        self.report("found", crew.id, f"{how}: {room['name']}.", room=room["id"])
        for c in self.crews:   # the search is over; everyone waits for the commander
            c.path, c.look, c.unseen, c.order, c.status = [], None, None, None, "idle"

    def discover(self, crew: Crew, cell: int) -> None:
        door = next(d for d in self.lay.doors if cell in d["cells"])
        self.known_blocked.add(door["id"])
        self.known = with_blocked(self.base, frozenset(self.known_blocked))
        names = " and ".join(self.lay.rooms[r]["name"] for r in door["rooms"])
        self.timeline.append({"t": round(self.t, 1), "door": door["id"]})
        self.report("blocked", crew.id, f"Doorway between {names} is blocked. Can't get through.", door=door["id"])
        crew.path, crew.status, crew.order, crew.look, crew.unseen = [], "idle", None, None, None
        for room, state in zip(self.lay.rooms, self.rooms):   # rooms with no other way in are written off
            if state["status"] in ("unknown", "voice_clear") and not self.known.floor[room["center"]]:
                state["status"] = "unreachable"
                self.timeline.append({"t": round(self.t, 1), "room": room["id"], "status": "unreachable"})
        for other in self.crews:   # everyone hears it: anyone routed through that door re-plans
            if other is not crew and other.path and other.dest is not None:
                target = "the casualty" if other.status == "responding" else self.lay.rooms[other.order["room"]]["name"]
                self.route(other, target)

    # ---- the record
    def snap(self) -> None:
        self.frames.append([round(self.t, 2), [
            [round(c.x, 2), round(c.y, 2), round(c.heading), c.status,
             *(self.base.xy(c.dest) if c.path and c.dest is not None else ())] for c in self.crews]])

    def metrics(self) -> dict:
        outcome = "rescued" if self.rescued_at is not None else "found" if self.found_at is not None else "timeout"
        return {"outcome": outcome, "elapsed": round(self.t, 1),
                "foundAt": None if self.found_at is None else round(self.found_at, 1),
                "areasChecked": self.physical + self.voice, "physicalSearches": self.physical, "voiceChecks": self.voice,
                "unnecessaryTrips": self.unnecessary, "physicalContacts": len(self.contacts),
                "falseClears": self.false_clears, "blockedFound": len(self.known_blocked),
                "walkedM": round(sum(c.walked for c in self.crews), 1), "reward": round(self.total_reward, 1)}

    def referee(self) -> dict:
        """The hidden incident, for the judge's view. Never part of an observation."""
        x, y = self.base.xy(self.incident.casualty)
        inc = self.incident
        return {"casualty": {"x": x, "y": y, "room": inc.room, "responsive": inc.responsive},
                "blockedDoors": sorted(inc.blocked),
                "witness": {"room": inc.witness_room, "was": inc.witness_kind}}


# ---------------------------------------------------------------- policies
class CoveragePolicy:
    """The conventional planner: send each free crew to the nearest room nobody has cleared, and take
    every report at its word. "Clear" is clear, "on my way" is as good as there."""
    name = "Coverage planner"

    def __init__(self) -> None:
        self.dispatched_at: float | None = None
        self.cleared: set[int] = set()   # rooms reported clear in the current pass over the building
        self.read = 0

    def act(self, obs: dict) -> list[dict]:
        idle = [c for c in obs["crews"] if c["status"] == "idle"]
        if obs["casualty"]["found"]:
            return self.respond(obs, idle)
        for rep in obs["reports"][self.read:]:
            if rep["kind"] == "clear":
                self.cleared.add(rep["room"])
        self.read = len(obs["reports"])
        reachable = [r for r in obs["rooms"] if r["status"] != "unreachable"]
        if all(r["id"] in self.cleared for r in reachable):
            self.cleared.clear()   # everything reported clear and still nobody: go round again
        open_rooms = [r for r in reachable if r["id"] not in self.cleared]
        taken = {c["order"]["room"] for c in obs["crews"] if c["order"] and "room" in c["order"]}
        orders = []
        for crew in idle:
            options = [r for r in open_rooms if r["id"] not in taken and _eta(crew, r["id"]) is not None]
            if not options:
                continue
            room = min(options, key=lambda r: _eta(crew, r["id"]))
            taken.add(room["id"])
            orders.append({"crew": crew["id"], "do": "search", "room": room["id"]})
        return orders

    def respond(self, obs: dict, idle: list[dict]) -> list[dict]:
        # sends the nearest crews once; only a long silence makes it send anyone else
        if self.dispatched_at is not None and obs["t"] - self.dispatched_at < 90:
            return []
        self.dispatched_at = obs["t"]
        going = sum(c["status"] in ("responding", "with_casualty") for c in obs["crews"])
        nearest = sorted((c for c in idle if c["etaCasualtyS"] is not None), key=lambda c: c["etaCasualtyS"])
        return [{"crew": c["id"], "do": "respond"} for c in nearest[:max(0, obs["casualty"]["needed"] - going)]]


class CommanderPolicy:
    """A hand-written commander that reads reports for what they establish: the stand-in for the
    trained policy, and the bar it has to beat. It weighs the witness without trusting them, keeps
    "called in" apart from "searched", calls into unlikely rooms and searches likely ones, and only
    counts a responder once they say they're with the casualty."""
    name = "Commander"

    def act(self, obs: dict) -> list[dict]:
        idle = [c for c in obs["crews"] if c["status"] == "idle"]
        if obs["casualty"]["found"]:
            committed = sum(c["status"] in ("responding", "with_casualty") for c in obs["crews"])
            nearest = sorted((c for c in idle if c["etaCasualtyS"] is not None), key=lambda c: c["etaCasualtyS"])
            return [{"crew": c["id"], "do": "respond"} for c in nearest[:max(0, obs["casualty"]["needed"] - committed)]]
        belief = self.belief(obs)
        taken = {c["order"]["room"] for c in obs["crews"] if c["order"] and "room" in c["order"]}
        orders = []
        for crew in sorted(idle, key=lambda c: c["id"]):
            best = None
            for room in obs["rooms"]:
                eta = _eta(crew, room["id"])
                if room["id"] in taken or eta is None or belief[room["id"]] <= 0:
                    continue
                search_s = 8 + room["areaM2"] * 0.9
                called = room["status"] in ("voice_clear", "searched_clear")
                # someone who didn't answer the first call almost certainly won't answer a second
                p_voice = 0.0 if called else P_RESPONSIVE * P_ANSWER_HEARD
                for do, p_catch, seconds in (("search", 0.95 * (1 - P_SHORTCUT) + p_voice * P_SHORTCUT, search_s),
                                             ("call", p_voice, CALL_S)):
                    if p_catch <= 0:
                        continue
                    rate = belief[room["id"]] * p_catch / (eta + seconds)
                    if best is None or rate > best[0]:
                        best = (rate, room["id"], do)
            if best:
                taken.add(best[1])
                orders.append({"crew": crew["id"], "do": best[2], "room": best[1]})
        return orders

    @staticmethod
    def belief(obs: dict) -> dict[int, float]:
        rooms = {r["id"]: r for r in obs["rooms"]}
        p = {i: r["areaM2"] for i, r in rooms.items() if r["status"] != "unreachable"}
        total = sum(p.values()) or 1.0
        p = {i: v / total for i, v in p.items()}
        called: set[int] = set()
        for rep in obs["reports"]:
            if rep["kind"] == "witness":      # right about half the time, next door a third of the time
                near = {r for d in obs["doors"] if rep["room"] in d["rooms"] for r in d["rooms"]} - {rep["room"]}
                for i in p:
                    like = P_WITNESS[0] if i == rep["room"] else P_WITNESS[1] / max(1, len(near)) if i in near \
                        else (1 - sum(P_WITNESS)) / max(1, len(p) - 1 - len(near))
                    p[i] *= like
            elif rep["kind"] == "clear" and rep["room"] in p:
                # what a "clear" rules out depends on how the room was checked, and a second call into
                # a room that was silent the first time rules out nothing more
                if rep.get("method") == "physical":
                    p[rep["room"]] *= 0.05
                elif rep["room"] not in called:
                    called.add(rep["room"])
                    p[rep["room"]] *= 1 - P_RESPONSIVE * P_ANSWER_HEARD
        total = sum(p.values()) or 1.0
        return {i: v / total for i, v in p.items()}


def _eta(crew: dict, room_id: int):
    eta = crew["etaS"]
    return eta.get(room_id, eta.get(str(room_id)))


POLICIES = {"coverage": CoveragePolicy, "commander": CommanderPolicy}


def run_policy(sim: CommandSim, policy) -> dict:
    obs = sim.reset()
    while not sim.done:
        obs, _, _, _ = sim.step(policy.act(obs))
    return {"policy": getattr(policy, "name", type(policy).__name__), "metrics": sim.metrics(),
            "reports": sim.reports, "frames": sim.frames, "timeline": sim.timeline}


def compare(env_id: str, seed: int, policies=("coverage", "commander"), **kwargs) -> dict:
    """The same building and the same hidden incident, once per policy."""
    runs, referee = [], None
    for key in policies:
        sim = CommandSim(env_id, seed=seed, record=True, **kwargs)
        runs.append({"key": key, **run_policy(sim, POLICIES[key]())})
        referee = sim.referee()
    return {"env": env_id, "seed": seed, "referee": referee, "runs": runs}


def evaluate(env_id: str, episodes: int, seed: int = 0, policies=("coverage", "commander"), **kwargs) -> dict:
    out = {}
    for key in policies:
        rows = [run_policy(CommandSim(env_id, seed=seed + k, **kwargs), POLICIES[key]())["metrics"] for k in range(episodes)]
        out[key] = {"episodes": episodes, "rescued": round(sum(r["outcome"] == "rescued" for r in rows) / episodes, 3),
                    **{m: round(statistics.fmean(r[m] for r in rows), 1)
                       for m in ("elapsed", "areasChecked", "unnecessaryTrips", "falseClears", "reward")}}
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Beacon commander environment")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("compare", "evaluate"):
        sp = sub.add_parser(name)
        sp.add_argument("--env", required=True)
        sp.add_argument("--seed", type=int, default=0)
        sp.add_argument("--rescuers", type=int, default=3)
        sp.add_argument("--responders", type=int, default=2)
    sub.choices["evaluate"].add_argument("--episodes", type=int, default=30)
    args = ap.parse_args()
    kwargs = {"rescuers": args.rescuers, "responders": args.responders}
    if args.cmd == "evaluate":
        print(json.dumps(evaluate(args.env, args.episodes, args.seed, **kwargs), indent=2))
        return
    out = compare(args.env, args.seed, **kwargs)
    print(json.dumps({"referee": out["referee"], **{r["key"]: r["metrics"] for r in out["runs"]}}, indent=2))


if __name__ == "__main__":
    main()
