"""One batched transition implementation for training, evaluation and replay.

Spatial routes and distances come from the existing Environment engine. Teams
are two-person units. Actions are noninterruptible travel + service jobs; a new
dispatch occurs when a team is free. This is a synthetic scheduling layer, not
an extension of the phone's capabilities.
"""

from functools import lru_cache
from itertools import combinations
from pathlib import Path
import json
import numpy as np
from swarm.simulator import Environment

ROOMS = 8
PREP, WAIT = 8, 9
ACTIONS = 10
STAGES = ["Retrieve equipment", "Isolate hazard", "Clear passage"]
TARGET_COUNT = 3
COMBOS = np.zeros((56, 8), np.float32)
for i, c in enumerate(combinations(range(8), 3)):
    COMBOS[i, list(c)] = 1


@lru_cache(None)
def geometry():
    spec = json.loads(
        (
            Path(__file__).resolve().parents[2] / "web/sim/envs/eng-floor.json"
        ).read_text()
    )
    spec["id"] = "eng-floor"
    env = Environment(spec)
    names = [
        "Robotics lab",
        "Machine shop",
        "Electronics lab",
        "Design studio",
        "E5-101",
        "E5-102",
        "E5-104",
        "E5-105",
    ]
    locations = [next(r for r in spec["rooms"] if r["name"] == name) for name in names]
    locations += [
        dict(name="Equipment", x=23, y=22),
        dict(name="Power isolation", x=25, y=19),
        dict(name="Passage", x=24, y=12),
        dict(name="Entry", x=24, y=24),
    ]
    cells = [env.nearest_walkable(r["x"], r["y"]) for r in locations]
    distances = np.array(
        [[float(env.field(b)[a]) for b in cells] for a in cells], np.float32
    )
    paths = [[env.path(a, b) for b in cells] for a in cells]
    assert np.isfinite(distances).all()
    return spec, locations, cells, distances, paths


def scenarios(seeds):
    out = []
    for seed in seeds:
        rng = np.random.default_rng(int(seed))
        # Half the incidents favor early preparation; the rest favor open rooms.
        wing_hot = bool(rng.integers(2))
        ratio = float(rng.choice([3, 5, 8]))
        weights = np.ones(8, np.float32)
        weights[4:] = ratio if wing_hot else 1 / ratio
        weights *= rng.uniform(0.8, 1.2, 8)
        logw = COMBOS @ np.log(weights)
        posterior = np.exp(logw - logw.max())
        posterior /= posterior.sum()
        truth = COMBOS[int(rng.choice(56, p=posterior))].copy()
        out.append(
            dict(
                seed=int(seed),
                posterior=posterior,
                truth=truth,
                deadline=float(rng.choice([80, 110, 140])),
                service=rng.choice([12, 18, 24], 8).astype(np.float32),
                prep_service=np.array([6, 8, 12], np.float32)
                * rng.choice([0.75, 1, 1.25]),
                speed=float(rng.choice([1.2, 1.5, 1.8])),
                wing_hot=wing_hot,
            )
        )
    return out


class Batch:
    def __init__(self, configs):
        self.n = len(configs)
        self.configs = configs
        self.t = np.zeros(self.n, np.float32)
        self.deadline = np.array([c["deadline"] for c in configs], np.float32)
        self.posterior = np.stack([c["posterior"] for c in configs])
        self._truth = np.stack([c["truth"] for c in configs])
        self.service = np.stack([c["service"] for c in configs])
        self.prep_service = np.stack([c["prep_service"] for c in configs])
        self.speed = np.array([c["speed"] for c in configs], np.float32)
        self.phase = np.zeros(self.n, np.int64)
        self.used = np.zeros((self.n, 8), bool)
        self.checked = np.zeros((self.n, 8), bool)
        self.found = np.zeros((self.n, 8), bool)
        self.pos = np.full((self.n, 2), 11, np.int64)
        self.jobs = np.full((self.n, 2), -1, np.int64)
        self.ends = np.zeros((self.n, 2), np.float32)
        self.reward = np.zeros(self.n, np.float32)
        self.done = np.zeros(self.n, bool)
        self.i = np.arange(self.n)
        self.decisions = 0

    def active_team(self):
        return np.argmin(self.jobs >= 0, axis=1)

    def public(self):
        return self.posterior @ COMBOS

    def duration(self):
        team = self.active_team()
        pos = self.pos[self.i, team]
        dist = geometry()[3]
        room = dist[pos, :8] / self.speed[:, None] + self.service
        stage = np.minimum(self.phase, 2)
        prep = dist[pos, 8 + stage] / self.speed + self.prep_service[self.i, stage]
        return room, prep

    def masks(self):
        room, prep = self.duration()
        left = self.deadline - self.t
        mask = np.ones((self.n, 10), bool)
        mask[:, :8] = ~self.used & (room <= left[:, None] + 1e-5)
        mask[:, 4:8] &= (self.phase == 3)[:, None]
        mask[:, 8] = (self.phase < 3) & ~(self.jobs == 8).any(1) & (prep <= left + 1e-5)
        mask[self.done, :] = False
        mask[:, 9] = True
        return mask

    def observe(self):
        belief = self.public()
        room, prep = self.duration()
        busy = self.jobs >= 0
        # This builder deliberately never reads _truth or scenario labels.
        x = np.concatenate(
            [
                belief,
                self.used.astype(np.float32),
                self.checked.astype(np.float32),
                self.found.astype(np.float32),
                room / 100,
                np.eye(4, dtype=np.float32)[self.phase],
                (self.deadline - self.t)[:, None] / 160,
                self.deadline[:, None] / 160,
                np.maximum(0, self.ends - self.t[:, None]) / 100,
                np.eye(12, dtype=np.float32)[self.pos].reshape(self.n, -1),
                np.eye(10, dtype=np.float32)[np.where(busy, self.jobs, 9)].reshape(
                    self.n, -1
                ),
                self.prep_service / 30,
                prep[:, None] / 60,
            ],
            axis=1,
        ).astype(np.float32)
        mask = self.masks()
        prior = np.zeros((self.n, 10), np.float32)
        prior[:, :8] = 4 * belief / (0.5 + room / 30)
        prior[:, 9] = -1
        return x, mask, prior

    def step(self, actions):
        actions = np.asarray(actions, np.int64)
        mask = self.masks()
        if not mask[self.i, actions].all():
            raise ValueError("Illegal action")
        if self.decisions > 40:
            raise RuntimeError("Nonterminating episode")
        self.decisions += 1
        room, prep = self.duration()
        team = self.active_team()
        active = ~self.done
        dispatched = []
        for a in range(9):
            ids = np.flatnonzero(active & (actions == a))
            if not len(ids):
                continue
            ts = team[ids]
            self.jobs[ids, ts] = a
            self.ends[ids, ts] = self.t[ids] + (room[ids, a] if a < 8 else prep[ids])
            if a < 8:
                self.used[ids, a] = True
            dispatched.extend(
                (
                    int(i),
                    int(t),
                    int(a),
                    float(self.t[i]),
                    float(self.ends[i, t]),
                    int(self.pos[i, t]),
                )
                for i, t in zip(ids, ts)
            )
        # If another team is free, dispatch it before advancing simulated time.
        advance = active & (((self.jobs >= 0).all(1)) | (actions == WAIT))
        next_t = np.minimum(
            self.deadline, np.where(self.jobs >= 0, self.ends, np.inf).min(1)
        )
        self.t = np.where(advance, next_t, self.t)
        reward = np.zeros(self.n, np.float32)
        events = []
        for team_idx in range(2):
            complete = (
                advance
                & (self.jobs[:, team_idx] >= 0)
                & (self.ends[:, team_idx] <= self.t + 1e-5)
            )
            for a in range(9):
                ids = np.flatnonzero(complete & (self.jobs[:, team_idx] == a))
                if not len(ids):
                    continue
                if a < 8:
                    found = self._truth[ids, a]
                    reward[ids] += found
                    self.checked[ids, a] = True
                    self.found[ids, a] = found.astype(bool)
                    compatible = COMBOS[:, a][None, :] == found[:, None]
                    self.posterior[ids] *= compatible
                    self.posterior[ids] /= self.posterior[ids].sum(1)[:, None]
                    self.pos[ids, team_idx] = a
                    for i, f in zip(ids, found):
                        events.append(
                            (
                                int(i),
                                int(team_idx),
                                "rescued" if f else "clear",
                                a,
                                float(self.t[i]),
                            )
                        )
                else:
                    self.pos[ids, team_idx] = 8 + self.phase[ids]
                    self.phase[ids] += 1
                    for i in ids:
                        events.append(
                            (
                                int(i),
                                int(team_idx),
                                "prepared",
                                int(self.phase[i]),
                                float(self.t[i]),
                            )
                        )
                self.jobs[ids, team_idx] = -1
        self.reward += reward
        self.done |= (self.t >= self.deadline - 1e-5) | (self.reward >= TARGET_COUNT)
        return reward, dispatched, events

    def state(self, i=0):
        return dict(
            t=float(self.t[i]),
            deadline=float(self.deadline[i]),
            phase=int(self.phase[i]),
            used=self.used[i].tolist(),
            checked=self.checked[i].tolist(),
            found=self.found[i].tolist(),
            belief=self.public()[i].tolist(),
            pos=self.pos[i].tolist(),
            jobs=self.jobs[i].tolist(),
            ends=self.ends[i].tolist(),
            service=self.service[i].tolist(),
            prep_service=self.prep_service[i].tolist(),
            speed=float(self.speed[i]),
            rescued=float(self.reward[i]),
        )


N_FEATURES = 96
