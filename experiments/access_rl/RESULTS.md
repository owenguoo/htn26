# Confirmed results — 2026-09-20

**The learned policy completed 47.6% more target rescues than Bayesian greedy on 1,024 fresh paired incidents.** All three targets were completed in 404 incidents versus 182 for greedy.

| Policy | Targets completed / 3,072 | All three completed | Median decision time |
|---|---:|---:|---:|
| Bayesian greedy (initial actor) | 1,533 | 182 | 0.120 ms |
| Always prepare first | 2,102 | 332 | 0.120 ms |
| 4-decision lookahead | 2,182 | 395 | 2.121 ms |
| 10-decision lookahead | 2,198 | 398 | 3.105 ms |
| PPO, development-selected seed 29 | **2,263** | **404** | **0.136 ms** |

Relative rescue gains: **47.6%** versus greedy, **7.7%** versus preparation-first, **3.7%** versus four-decision lookahead, **3.0%** versus ten-decision lookahead. The large headline gain does **not** hold against the stronger planning controls. Against the ten-decision planner, the learned policy had approximately 23× lower median compute time; both already have millisecond-scale decisions in this small environment.

Against greedy, paired additional rescues per incident were **0.713**, 95% bootstrap interval **[0.650, 0.776]**: 473 wins, 32 losses, 519 ties. Against ten-decision lookahead, the interval was **[0.022, 0.106]** additional rescues per incident. These are same-layout, synthetic-incident intervals, not real-world or cross-building confidence guarantees.

Independent training seed 28 completed **2,264** targets on the same fresh incidents, corroborating the result. Seed 29 was chosen by development performance, not the one-target difference on test. Each training run saw 102,400 incidents; wall time was 42.4 seconds (seed 28) and 37.4 seconds (seed 29), including periodic development evaluation, on Runpod A100. No Baseten training is claimed for these runs.

The earlier 512-incident pilot for seed 28 produced 1,099 rescues versus greedy's 711 (+54.6%); the larger fresh confirmation supersedes that headline. No simulator or reward changes were made between pilot and confirmation. The previous `crew_rl` experiment, which failed to establish an advantage, remains intact.

Interpretation: retrieve equipment, isolate a hazard, and clear passage can be worthwhile despite no immediate reward. A reactive probability/cost rule misses that future value. PPO learns it, while a longer planning horizon can also recover it. This is evidence for a compact learned coordination policy, not evidence of an exclusive RL capability or validated search-and-rescue autonomy.
