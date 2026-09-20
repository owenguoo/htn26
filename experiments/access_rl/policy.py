"""Observable-state policies; planners never receive sampled target locations."""

import copy
import numpy as np
from .env import geometry


def forward(x, weights):
    h = np.tanh(x @ weights["w1"] + weights["b1"])
    h = np.tanh(h @ weights["w2"] + weights["b2"])
    return h @ weights["wa"] + weights["ba"]


def choose(batch, weights=None, preparation=False):
    x, mask, prior = batch.observe()
    logits = prior if weights is None else prior + forward(x, weights)
    a = np.where(mask, logits, -1e9).argmax(1)
    if preparation:
        a = np.where(mask[:, 8], 8, a)
    return a


def options(s):
    team = next(i for i, j in enumerate(s["jobs"]) if j < 0)
    distances = geometry()[3][s["pos"][team]] / s["speed"]
    left = s["deadline"] - s["t"]
    options = [
        (i, float(distances[i] + s["service"][i]))
        for i in range(8)
        if not s["used"][i]
        and (i < 4 or s["phase"] == 3)
        and distances[i] + s["service"][i] <= left + 1e-5
    ]
    if s["phase"] < 3 and 8 not in s["jobs"]:
        d = float(distances[8 + s["phase"]] + s["prep_service"][s["phase"]])
        if d <= left + 1e-5:
            options.append((8, d))
    options.append((9, 0))
    return team, options


def transition(s, action, duration):
    s = copy.deepcopy(s)
    reward = 0.0
    team = next(i for i, j in enumerate(s["jobs"]) if j < 0)
    if action < 9:
        s["jobs"][team] = action
        s["ends"][team] = s["t"] + duration
        if action < 8:
            s["used"][action] = True
    if action == 9 or all(j >= 0 for j in s["jobs"]):
        s["t"] = min(
            [s["deadline"]] + [s["ends"][i] for i, j in enumerate(s["jobs"]) if j >= 0]
        )
        for i, j in enumerate(s["jobs"]):
            if j < 0 or s["ends"][i] > s["t"] + 1e-5:
                continue
            if j < 8:
                reward += s["belief"][j]
                s["pos"][i] = j
            else:
                s["pos"][i] = 8 + s["phase"]
                s["phase"] += 1
            s["jobs"][i] = -1
    return s, reward


def plan(s, depth=4, width=24):
    # Certainty-equivalent beam search. Exact Bayesian posterior at every real
    # observation; hypothetical branches use current expected room occupancy.
    beam = [(0.0, s, -1)]
    for _ in range(depth):
        children = []
        for score, state, first in beam:
            if state["t"] >= state["deadline"] - 1e-5:
                children.append((score, state, first))
                continue
            _, actions = options(state)
            for a, d in actions:
                nxt, r = transition(state, a, d)
                children.append((score + r, nxt, a if first < 0 else first))
        # Pending jobs count at leaves only if they can finish by the deadline.
        # Small time tie-break avoids preferring gratuitous waiting.
        children.sort(
            key=lambda row: (
                row[0]
                + sum(
                    row[1]["belief"][j]
                    for i, j in enumerate(row[1]["jobs"])
                    if 0 <= j < 8 and row[1]["ends"][i] <= row[1]["deadline"]
                ),
                -row[1]["t"],
            ),
            reverse=True,
        )
        # Keep some zero-immediate-return preparation branches. Without this,
        # beam pruning would silently preclude the long-horizon strategy.
        diverse = []
        counts = {}
        for child in children:
            group = (child[2], child[1]["phase"])
            if counts.get(group, 0) < max(2, width // 10):
                diverse.append(child)
                counts[group] = counts.get(group, 0) + 1
            if len(diverse) >= width:
                break
        beam = diverse
    return beam[0][2]
