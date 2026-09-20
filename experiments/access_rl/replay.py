"""Replays for the simulation page: the same incident under a baseline and the trained policy.

Loaded once from an artifacts directory; `report()` feeds the page's numbers and
`run(seed, baseline)` replays one incident with the real exported weights.
"""

from copy import deepcopy
import gzip
import json
from pathlib import Path

import numpy as np

from .env import geometry, scenarios
from .evaluate import episode

ARTIFACTS = Path(__file__).with_name("artifacts") / "demo"
BASELINES = ("greedy", "prepare-first", "lookahead-4", "lookahead-10")

# Display labels only: preserve room IDs, geometry, actions and trained features.
ROOM_LABELS = {
    "Robotics lab": "Room 1",
    "Machine shop": "Equipment room",
    "Electronics lab": "Room 2",
    "Design studio": "Storage room",
    **{f"E5-{101 + i}": f"Room {3 + i}" for i in range(6)},
    "Stores": "Supply room",
    "Lobby": "Entry hall",
    "Equipment": "Rescue gear station",
    "Power isolation": "Hazard control point",
    "Passage": "Hazard zone entrance",
}
HAZARD_STEPS = ["Collect rescue gear", "Isolate hazard", "Clear access route"]


def display_location(location):
    return {**location, "name": ROOM_LABELS.get(location["name"], location["name"])}


class Replay:
    def __init__(self, artifacts: Path = ARTIFACTS):
        self.weights = dict(np.load(artifacts / "selected.npz"))
        report = json.loads((artifacts / "report.json").read_text())
        report["curve"] = json.loads((artifacts / "curve.json").read_text())
        report["protocol"] = json.loads((artifacts / "protocol.json").read_text())
        rows = json.loads(gzip.decompress((artifacts / "episodes.json.gz").read_bytes()))
        by = {(r["seed"], r["policy"]): r for r in rows}
        examples = [
            r["seed"]
            for r in rows
            if r["policy"] == "trained"
            and r["rescued"] - by[(r["seed"], "greedy")]["rescued"] >= 2
        ]
        report["exampleSeed"] = examples[0] if examples else rows[0]["seed"]
        spec, loc, _, _, _ = geometry()
        report["environment"] = deepcopy(spec)
        report["environment"]["name"] = "Search and rescue training floor"
        report["environment"]["rooms"] = [display_location(r) for r in spec["rooms"]]
        report["locations"] = [display_location(r) for r in loc]
        self.report = report

    def run(self, seed: int, baseline: str = "greedy") -> dict:
        if baseline not in BASELINES:
            raise ValueError("Unknown baseline")
        if not 0 <= seed < 2**31:
            raise ValueError("Invalid seed")
        return dict(
            seed=seed,
            before=self._replay(seed, baseline, None),
            trained=self._replay(seed, "trained", self.weights),
        )

    @staticmethod
    def _replay(seed, label, weights):
        row = episode((seed, label, weights))
        # `truth` stays in the replay so the page can show where the people are.
        # The policy never sees it: the observation builder in env.py excludes it.
        spec, locations, cells, dist, paths = geometry()
        stage = 0
        jobs = []
        for _, team, action, start, end, source in row["dispatches"]:
            dest = action if action < 8 else 8 + stage
            name = (
                display_location(locations[action])["name"]
                if action < 8
                else HAZARD_STEPS[stage]
            )
            if action == 8:
                stage += 1
            jobs.append(
                dict(
                    team=team,
                    action=action,
                    start=start,
                    end=end,
                    path=paths[source][dest],
                    travel=float(dist[source, dest] / scenarios([seed])[0]["speed"]),
                    name=name,
                )
            )
        return dict(**row, jobs=jobs)
