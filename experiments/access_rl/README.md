# Access preparation RL experiment

A real PPO policy learns when to spend time preparing access to a restricted wing, while the other crew searches accessible rooms. The default demo compares the untrained policy (exactly the Bayesian greedy prior) with its learned residual. All baselines remain selectable and visible in the aggregate table.

This is a **synthetic scheduling extension** using the existing `swarm.simulator.Environment` floor plan, pathfinder, and travel distances. It does not add equipment or hazard controls to the phone app. The older, unsuccessful `crew_rl` experiment is preserved separately.

## Run

Use Python 3.11 and NumPy 1.26.4 for reproducibility. Torch is needed only for training; serving uses the exported NumPy weights.

```sh
OPENBLAS_NUM_THREADS=1 python -m experiments.access_rl.demo \
  --artifacts experiments/access_rl/artifacts/demo --port 8024

# GPU training; use a fresh output directory
OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 python -m experiments.access_rl.train \
  --output /tmp/access-run28 --seed 28 --updates 200 --batch 512

OPENBLAS_NUM_THREADS=1 python -m experiments.access_rl.evaluate \
  --weights /tmp/access-run28/selected.npz --output /tmp/access-test28 \
  --count 1024 --start 10000000 --workers 8

python -m pytest -q experiments/access_rl/test_env.py
```

Local isolated interpreter: `.runtime/crew-rl/venv/bin/python`.

## Task and information boundary

- Four people organized into two identical two-person crews.
- Eight searchable rooms, three hidden requested targets, at most one per room.
- Target count is known. Exact Bayesian posterior over the 56 possible target subsets is public to every policy.
- Half the scenario distribution favors the restricted rooms; half favors the open rooms. This label and sampled target positions never enter the policy observations.
- Room costs, crew speed, preparation costs and the 80/110/140 second deadline vary.
- Retrieve equipment → isolate hazard → clear passage. All three must finish before restricted-room searches are legal.
- Each action occupies a crew for travel plus fixed service time. Jobs cannot be interrupted. The next decision occurs when a crew is free.
- A target counts only after its room's travel and combined search/assistance service finish. Empty rooms consume the same fixed room service budget; this is an abstraction, not a visual-detection or medical model.
- Reward is exactly one per completed target. Preparation earns zero. No auxiliary shaping, privileged teacher, hidden-target features, speech, or external API participates in the policy.
- Geometry is fixed to the engineering floor. Test cases vary incidents on this layout, not unseen buildings.

The neural network has 96 public inputs, two 128-unit tanh hidden layers, a 10-action actor and a value head. PPO uses complete-episode undiscounted returns, four clipped optimization epochs, entropy regularization, and a fixed Bayesian-greedy logit prior. Its initially zero actor residual reproduces greedy action selection exactly. The final actor is exported for CPU inference.

## Controls

1. **Bayesian greedy / before RL:** choose the legal room with highest probability divided by a travel/service cost. Preparation has no immediate reward; when no room is attractive/available it can prepare. This is an intentionally reactive baseline, not a general Bayesian planning algorithm.
2. **Always prepare first:** do the next preparation job whenever legal; otherwise choose greedy search. It prevents mistaking a fixed preparation recipe for learned adaptation.
3. **4-decision lookahead:** receding-horizon expected-reward beam search, width 32. Pending searches count at leaf states. Diverse preparation branches are retained so pruning does not exclude them by construction.
4. **10-decision lookahead:** same planner with a longer horizon. These are certainty-equivalent approximations: hypothetical searches use the current posterior marginals; actual observations trigger exact Bayesian updates. They do not branch over all possible future observations and are not optimal POMDP solvers.

All have identical observations, action masks, scheduling rules and geometry. Both initial actor and trained actor retain the same probability/cost prior. The policy cannot issue a faster route or see hidden targets.

## Reproducibility and selection

Two independent training seeds, 28 and 29, each ran 200 × 512 = 102,400 training incidents on the existing Runpod A100. Development seeds 8,000,000–8,001,023 select checkpoints. Seed 29 won on development performance (update 160), so it is the demo model. Fresh confirmation seeds 10,000,000–10,001,023 evaluate both training seeds. Training seeds start at 1,000,000 + model_seed × 1,000,000 and do not overlap development or test seeds.

Artifacts include both model/optimizer checkpoints, initial and selected NumPy actors, complete development curves, all confirmation episode records, the initial pilot, protocol files, source snapshot and a SHA-256 manifest. Reports use paired bootstrap intervals over incidents (4,000 resamples), not over individual targets. Timing includes policy observation preparation and CPU inference/search, excludes transition execution, and comes from multiprocessing evaluation on the same machine; it is not mobile or end-to-end network latency.

The default replay intentionally selects the first test incident with at least two additional rescues versus greedy. It is explicitly labeled illustrative. “New incident” uses fresh seeds and can produce losses or ties. The aggregate includes every test incident. Replay executes policies anew, rather than playing a hardcoded outcome.

## Limits of the claim

The large advantage is against a reactive planner on a scenario deliberately designed for delayed preparation decisions. The strongest tested planner is close in rescue count. This demonstrates learned scheduling and amortized planning; it does not establish that Bayesian methods cannot represent these tasks or that RL is necessary for this small map. It does not validate real rescue operations, changing hazards, camera perception, identity matching, human compliance, unknown target counts, or unseen-map generalization.
