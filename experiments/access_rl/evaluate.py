"""Paired, fresh-incident evaluation including non-learning preparation controls."""

import argparse
import json
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np
from .env import Batch, scenarios
from .policy import choose, plan


def episode(args):
    seed, label, weights = args
    b = Batch(scenarios([seed]))
    times = []
    actions = []
    dispatches = []
    events = []
    while not b.done.all():
        start = time.perf_counter()
        if label.startswith("lookahead"):
            a = plan(b.state(), depth=int(label.split("-")[1]), width=32)
        else:
            a = int(choose(b, weights, preparation=label == "prepare-first")[0])
        times.append((time.perf_counter() - start) * 1000)
        actions.append(
            dict(
                t=float(b.t[0]),
                action=a,
                phase=int(b.phase[0]),
                belief=b.public()[0].tolist(),
            )
        )
        _, ds, es = b.step([a])
        dispatches += ds
        events += es
    return dict(
        seed=seed,
        policy=label,
        rescued=int(b.reward[0]),
        wingHot=b.configs[0]["wing_hot"],
        deadline=float(b.deadline[0]),
        decisionMs=times,
        actions=actions,
        dispatches=dispatches,
        events=events,
        truth=b._truth[0].tolist(),
    )


def report(rows):
    groups = {
        p: [r for r in rows if r["policy"] == p]
        for p in sorted({r["policy"] for r in rows})
    }
    result = {}
    for p, rs in groups.items():
        times = [t for r in rs for t in r["decisionMs"]]
        result[p] = dict(
            incidents=len(rs),
            rescued=sum(r["rescued"] for r in rs),
            targets=3 * len(rs),
            meanRescues=float(np.mean([r["rescued"] for r in rs])),
            allFound=sum(r["rescued"] == 3 for r in rs),
            decisionMedianMs=float(np.median(times)),
            decisionP95Ms=float(np.percentile(times, 95)),
            wingHotMean=float(np.mean([r["rescued"] for r in rs if r["wingHot"]])),
            openHotMean=float(np.mean([r["rescued"] for r in rs if not r["wingHot"]])),
        )
    paired = {}
    trained = {r["seed"]: r["rescued"] for r in groups["trained"]}
    for p, rs in groups.items():
        if p == "trained":
            continue
        diff = np.array([trained[r["seed"]] - r["rescued"] for r in rs])
        boots = np.random.default_rng(28).choice(diff, (4000, len(diff))).mean(1)
        base = result[p]["meanRescues"]
        paired[p] = dict(
            additionalPerIncident=float(diff.mean()),
            relativePercent=float(100 * diff.mean() / base) if base else None,
            bootstrap95=np.quantile(boots, [0.025, 0.975]).tolist(),
            wins=int((diff > 0).sum()),
            losses=int((diff < 0).sum()),
            ties=int((diff == 0).sum()),
        )
    return dict(policies=result, paired=paired)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--weights", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--count", type=int, default=512)
    p.add_argument("--start", type=int, default=9000000)
    p.add_argument("--workers", type=int, default=6)
    p.add_argument(
        "--policies", default="greedy,prepare-first,lookahead-4,lookahead-10,trained"
    )
    a = p.parse_args()
    w = dict(np.load(a.weights, allow_pickle=False))
    a.output.mkdir(parents=True, exist_ok=False)
    tasks = [
        (seed, label, w if label == "trained" else None)
        for label in a.policies.split(",")
        for seed in range(a.start, a.start + a.count)
    ]
    with ProcessPoolExecutor(a.workers) as pool:
        rows = list(pool.map(episode, tasks, chunksize=8))
    (a.output / "episodes.json").write_text(json.dumps(rows))
    result = report(rows)
    (a.output / "report.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
