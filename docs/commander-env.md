# Commander environment (for RL)

`swarm/command_sim.py` is what the central intelligence is trained on. It uses the simulator's buildings, movement and sight model (`swarm/simulator.py`), but the policy is a **commander**: it reads reports and gives room-level orders to crews. It never sees the hidden incident.

Sweeping a floor for one still casualty with perfect information is route planning, and a coverage planner is already strong at it. The decisions worth learning come from reports that don't mean what they say.

## Uncertainties in the environment today

| What the commander hears | What may be true |
|---|---|
| "E5-103 clear." | A physical search (misses about 1 in 20), or a call from the doorway, which misses anyone who can't answer (half of casualties). A crew told to search takes the doorway shortcut 25% of the time. The report's `method` says which. |
| "I last saw them in the Robotics lab." | Right 55% of the time, the room next door 30%, anywhere 15%. |
| Nothing, until a crew gets there | Each ordinary doorway is blocked with probability 0.2 (at most two; the casualty stays reachable). A crew that hits one stops and reports it; rooms with no other way in become `unreachable`. |
| "On my way to the casualty." | An acknowledgement. The rescue counts only crews who later report "With the casualty", and a responder can be stopped by a blocked door after acknowledging. |

All probabilities are constants at the top of the module.

## Interface

```python
from swarm.command_sim import CommandSim

sim = CommandSim("eng-floor", seed=7, rescuers=3, responders=2)
obs = sim.reset()
while not sim.done:
    orders = policy(obs)                 # [{"crew": 0, "do": "search", "room": 4}, ...]
    obs, reward, done, info = sim.step(orders)
```

- **Orders:** `{"crew": id, "do": "search" | "call" | "respond" | "hold", "room": id}`. `search` is a physical search, `call` is calling in from the doorway (about 6 s), `respond` sends a crew to the casualty once found. A new order to a busy crew replaces its current one.
- **Decision points:** `step` returns on every new report, at least every 5 s, and every 2 s while a crew is idle.
- **Observation** (plain JSON, so it can be fed to an LLM or flattened to a vector): `t`; `crews` (status, room, position, current order, `etaS` to every room and `etaCasualtyS` on the known map); `rooms` (name, area, doors, status `unknown | voice_clear | searched_clear | found | unreachable`, who checked it and when); `doors` (`blocked` is `true` or `null` = unknown); `casualty` (found, room once found, contacts, needed); `newReports` and the full `reports` log. Each report has `t`, `kind` (`witness, ack, entered, clear, found, blocked, no_route, arrived, rescued, timeout`), `crew`, `text`, and structured fields (`room`, `method`, `door`).
- **Reward:** −0.1 per second, +20 on the find, +100 when the needed crews are physically with the casualty, −5 per unnecessary trip (sending a crew to a room already physically searched, calling again into a room that was already silent, ordering a search after the find, sending more responders than needed).
- **`info`** is the scorecard: outcome, elapsed, found-at, areas checked (physical / voice), unnecessary trips, physical contacts, reward, plus referee-only `falseClears`.
- `sim.referee()` returns the hidden incident for the judge's view. It is never in an observation (there is a test for that).

**Matched comparisons.** An incident is fully determined by `(environment, seed)`: casualty, whether they can answer, blocked doors, the witness. Chance events are keyed dice (`sim.roll`), so the same crew calling into the same room gets the same outcome under every policy. `compare(env, seed)` runs each policy on the same incident; `evaluate(env, episodes)` averages over many.

```bash
uv run python -m swarm.command_sim compare --env eng-floor --seed 3
uv run python -m swarm.command_sim evaluate --env eng-floor --episodes 50
```

## Policies in the repo

- `CoveragePolicy`: the conventional planner. Nearest unchecked room for each free crew, takes every report at its word, sends responders once.
- `CommanderPolicy`: a hand-written commander that weighs the witness, keeps "called in" apart from "searched", calls into unlikely rooms and searches likely ones, and only counts confirmed arrivals. It is the stand-in for the trained policy and the bar it has to beat.

40 incidents, 3 crews (2026-09-20): engineering floor, coverage 95% rescued, 210 s, reward 84; commander 100%, 89 s, reward 110.

To add a policy, give it an `act(obs) -> orders` method and register it in `POLICIES`; the Simulator tab plays whatever `compare` returns.

## In the Simulator tab

**Run simulation** plays one hidden incident under both policies. Switch whose run is on the map, scrub, and read the radio log. Rooms are tinted by what has been *reported* (not checked / called in / searched / no way in). **Referee view** shows the casualty, the doorways nobody has found blocked yet, and whether the witness was right; turn it off to see only what the commander knows. The scorecard shows elapsed time, areas checked, unnecessary trips, physical contacts and reward side by side.

Rooms come from **Door** cells in the floor plan: paint one across every doorway in the editor. A plan with no doors is one big room.

## Next uncertainties (not built)

The report log, provenance fields and keyed dice are set up for these:

1. "I saw them outside": a report that someone left, which may predate them going back in.
2. Several reports that trace back to one witness (hearsay that looks like corroboration).
3. Two people last seen together: finding one is information, not the end.
4. Scope: "checked the machine shop" that never entered its storeroom.
5. Place names: "the workshop", "E5-103" and "opposite the robotics lab" as one room or three.
6. Delayed messages that arrive after the sender has been re-tasked (timestamps are already on every report).
7. Handoffs nobody accepted.
8. A belonging found in a room is not its owner.

Also not built: more than one casualty, hazards changing mid-run, crews whose position reports are wrong, 3D markers for blocked doors.
