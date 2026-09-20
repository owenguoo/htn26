# Rescue simulator

The console's **Simulator** tab (`/simulator`) rehearses a search on a floor plan before anyone walks into the building.
It never touches live hub state, so it is safe to use while phones are connected.

The tab's main run is now the **commander comparison**: see [Commander environment](commander-env.md). This page covers environments, the editor, hazards and the team-size comparison.

## What it does

Pick an environment, set the scenario (rescuers, responders, where the casualty is or "random", time limit), and **Run simulation**.
The team walks in at the environment's first entry and searches with Beacon's planner; every run is a new one.
The hub plays the search out and the page replays it in plan view or 3D: where each rescuer walked and looked, the probability map draining as rooms are cleared, the find, and responders converging.

**Compare team sizes** runs the scenario many times with the casualty somewhere new each time, and every team size faces the same casualties.
It reports the median time to find, the range 8 in 10 runs fell in, the found rate, rescue time, and how far each rescuer walked.
A run that times out counts as the full time limit.
Click a team size to see on the plan where casualties took longest to find.

From a terminal:

```bash
uv run python -m swarm.simulator run --env apartment --rescuers 3 --seed 1
uv run python -m swarm.simulator batch --env eng-floor --rescuers 1,2,4,6 --runs 40
```

## How the search is modelled

`swarm/simulator.py` is the live hub's search model with walls in it.
Detection uses the hub's own constants (`POD_MAX`, `look_quality`, dwell, turn rate, imported from `swarm/coverage.py` and `swarm/planner.py`), so retuning the hub retunes the simulator.
The **Beacon planner** strategy is the same Bayesian search objective as `swarm/planner.py`: each idle rescuer takes the option that buys the most probability of a find per second, assigned greedily with each pick discounting what it covers.
What differs from the live hall: sight lines stop at walls (furniture blocks walking but not sight), walking costs the real path length, and rescuers walk at 1.2 m/s instead of being seated.
A no-planning baseline (`--strategy frontier`: everyone heads for the nearest place nobody has looked), a team already spread through the building (`--start spread`) and repeatable runs (`--seed`) are on the command line, not the page. The engine can also start the team at another entry (`entry` in `Params`).

The live `Planner` and `Coverage` still assume one open room. The simulator does not change them.

## Environments

An environment is a JSON file: a grid of cells (`.` floor, `o` furniture, `#` wall, `d` doorway, space = outside, `f` fire, `s` smoke), a cell size in meters, named entries, room labels, and optionally the 3D scan it was traced from.

- Built-ins live in `web/sim/envs/` and are drawn by `scripts/make_sim_envs.py`. The apartment and engineering-floor plans there are hand-drawn stand-ins until the real walkthrough scans exist.
- Environments made in the console are saved to `web/sim/envs/user/` (not in Git), with their `.glb` beside them.

**New environment → From a 3D scan** takes a `.glb` (meters, Y up: what Polycam, Scaniverse, RoomPlan and the VGGT worker export).
The page traces it in the browser (`web/sim-scan.js`): anything between 0.3 m and head height blocks walking, anything reaching above 1.2 m also blocks sight, and cells with no scanned floor are outside.
Touch up the plan (close gaps in walls, clear doorways that were scanned shut), mark at least one entry, and save.
Scale, Turn and Cell re-trace the scan if it came in at the wrong size or angle. A floor plan is limited to 40,000 cells.
In 3D the scan is shown under the simulation; **Scan** switches back to the traced walls.

## Hazards

The plan editor (New environment → Edit a copy of this floor plan) has **Fire** and **Smoke** brushes. They fill open floor only, so brushing along a wall leaves the wall standing.

- **Fire**: nobody walks through it. Routes go round; rooms whose only way in is burning are cut off and drop out of the search, and the casualty is never placed there.
- **Smoke**: can be crossed at 2.5× the time, so routes avoid it unless the way round is much longer. A look into smoke, or out of it, is 0.3× as likely to spot someone, so smoky rooms stay hot on the map for longer.

Hazards are part of the saved environment and stay put for the whole run. Save one copy per situation ("hall fire", "east wing smoke") and compare them.

## Not built yet

- Hazards that change during a run: fire spreading, smoke filling a corridor, a route collapsing.
- Generating an environment from photos of a building (the disabled option in New environment).
- Rescue planning against the live team: seeding a simulation with the phones actually connected and their positions, and handing the resulting plan to Mission Control.
- Multiple floors, moving casualties, more than one casualty.
