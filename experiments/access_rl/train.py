"""Batched PPO. Checkpoint selection uses development seeds only."""

import argparse
import json
import time
from pathlib import Path
import numpy as np
from .env import Batch, scenarios, N_FEATURES
from .policy import choose


def save(p, obj):
    p.write_text(json.dumps(obj, indent=2) + "\n")


def evaluate(weights, seeds):
    b = Batch(scenarios(seeds))
    while not b.done.all():
        b.step(choose(b, weights))
    return b.reward


def main():
    import torch
    from torch import nn

    p = argparse.ArgumentParser()
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--updates", type=int, default=200)
    p.add_argument("--batch", type=int, default=512)
    p.add_argument("--seed", type=int, default=28)
    p.add_argument("--lr", type=float, default=0.0007)
    a = p.parse_args()
    out = a.output
    out.mkdir(parents=True, exist_ok=False)
    torch.set_num_threads(1)
    torch.manual_seed(a.seed)
    np.random.seed(a.seed)
    device = "cuda" if torch.cuda.is_available() else "cpu"

    class Model(nn.Module):
        def __init__(self):
            super().__init__()
            self.h1 = nn.Linear(N_FEATURES, 128)
            self.h2 = nn.Linear(128, 128)
            self.actor = nn.Linear(128, 10)
            self.value = nn.Linear(128, 1)
            nn.init.zeros_(self.actor.weight)
            nn.init.zeros_(self.actor.bias)

        def forward(self, x, mask, prior):
            h = torch.tanh(self.h2(torch.tanh(self.h1(x))))
            return (self.actor(h) + prior).masked_fill(~mask, -1e9), self.value(
                h
            ).squeeze(-1)

        def weights(self):
            result = {}
            for layer, w, b in [
                (self.h1, "w1", "b1"),
                (self.h2, "w2", "b2"),
                (self.actor, "wa", "ba"),
            ]:
                result[w] = layer.weight.detach().cpu().numpy().T.copy()
                result[b] = layer.bias.detach().cpu().numpy().copy()
            return result

    model = Model().to(device)
    opt = torch.optim.Adam(model.parameters(), lr=a.lr)

    def tensor(x):
        return torch.as_tensor(x, device=device)

    np.savez(out / "initial.npz", **model.weights())
    save(
        out / "protocol.json",
        dict(
            algorithm="PPO",
            reward="One per target completed; zero for preparation",
            updates=a.updates,
            batch=a.batch,
            seed=a.seed,
            lr=a.lr,
            device=device,
            trainSeedStart=1000000 + a.seed * 1000000,
            devSeedStart=8000000,
            devCount=1024,
            hiddenTruthExcluded=True,
            features=N_FEATURES,
        ),
    )
    start = time.monotonic()
    curve = []
    best = -1
    for update in range(1, a.updates + 1):
        base = 1000000 + a.seed * 1000000 + (update - 1) * a.batch
        env = Batch(scenarios(range(base, base + a.batch)))
        steps = []
        while not env.done.all():
            x, mask, prior = env.observe()
            active = ~env.done.copy()
            with torch.no_grad():
                logits, v = model(tensor(x), tensor(mask), tensor(prior))
                dist = torch.distributions.Categorical(logits=logits)
                act = dist.sample()
                logp = dist.log_prob(act)
            reward, _, _ = env.step(act.cpu().numpy())
            steps.append(
                [
                    x,
                    mask,
                    prior,
                    act.cpu().numpy(),
                    logp.cpu().numpy(),
                    v.cpu().numpy(),
                    reward,
                    active,
                ]
            )
        returns = np.zeros(a.batch, np.float32)
        samples = []
        for x, m, p, act, lp, v, r, active in reversed(steps):
            returns = r + returns
            samples.append(
                (
                    x[active],
                    m[active],
                    p[active],
                    act[active],
                    lp[active],
                    returns[active].copy(),
                    (returns - v)[active],
                )
            )
        arrays = [np.concatenate([s[i] for s in samples]) for i in range(7)]
        arrays[-1] = (arrays[-1] - arrays[-1].mean()) / (arrays[-1].std() + 1e-6)
        xx, mm, pp, aa, ll, rr, adv = [tensor(z) for z in arrays]
        for epoch in range(4):
            order = torch.randperm(len(xx), device=device)
            for ids in order.split(1024):
                logits, val = model(xx[ids], mm[ids], pp[ids])
                dist = torch.distributions.Categorical(logits=logits)
                ratio = (dist.log_prob(aa[ids]) - ll[ids]).exp()
                actor = -torch.minimum(
                    ratio * adv[ids], ratio.clamp(0.8, 1.2) * adv[ids]
                ).mean()
                loss = (
                    actor
                    + 0.5 * ((val - rr[ids]) ** 2).mean()
                    - 0.02 * dist.entropy().mean()
                )
                opt.zero_grad()
                loss.backward()
                nn.utils.clip_grad_norm_(model.parameters(), 0.5)
                opt.step()
        if update == 1 or update % 10 == 0:
            weights = model.weights()
            dev = evaluate(weights, range(8000000, 8001024))
            row = dict(
                update=update,
                trainMean=float(env.reward.mean()),
                devMean=float(dev.mean()),
                seconds=time.monotonic() - start,
            )
            curve.append(row)
            save(out / "curve.json", curve)
            print(json.dumps(row), flush=True)
            if dev.mean() > best:
                best = float(dev.mean())
                np.savez(out / "selected.npz", **weights)
                save(out / "selection.json", row)
            np.savez(out / "latest.npz", **weights)
            torch.save(
                dict(
                    model=model.state_dict(), optimizer=opt.state_dict(), update=update
                ),
                out / "resume.pt",
            )
    save(
        out / "complete.json",
        dict(
            seconds=time.monotonic() - start, episodes=a.updates * a.batch, bestDev=best
        ),
    )


if __name__ == "__main__":
    main()
