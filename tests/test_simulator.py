import json
import math
import time

import numpy as np
import pytest
from fastapi.testclient import TestClient

from swarm import coverage, simulator
from swarm.simulator import Environment, Params, simulate

# Two rooms joined by one door at the top; the wall between them runs most of the way down.
TWO_ROOMS = {
    "id": "two-rooms", "name": "Two rooms", "cell": 0.5,
    "entries": [{"name": "Door", "x": 0.75, "y": 4.25}],
    "grid": [
        "###########",
        "#....#....#",
        "#.........#",
        "#....#....#",
        "#....#....#",
        "#....#....#",
        "#....#....#",
        "#....#....#",
        "#....#..oo#",
        "###########",
    ],
}


@pytest.fixture
def env():
    return Environment(json.loads(json.dumps(TWO_ROOMS)))


def test_look_quality_matches_the_live_hub():
    d, off = np.array([0.5, 2.0, 4.9, 3.0]), np.array([0.0, 10.0, 27.5, 40.0])
    ours = simulator.look_quality(d, off, 27.5)
    theirs = [coverage.look_quality(float(a), float(b), 27.5) for a, b in zip(d, off)]
    assert np.allclose(ours, theirs)


def test_walls_block_sight_and_furniture_does_not(env):
    left = env.cell_at(1.25, 3.25)
    seen = set(env.visible(left)[0].tolist())
    assert env.cell_at(2.25, 3.25) in seen            # same room
    assert env.cell_at(3.75, 3.25) not in seen        # straight through the wall
    level_with_door = set(env.visible(env.cell_at(1.25, 1.25))[0].tolist())
    assert env.cell_at(3.75, 1.25) in level_with_door  # through the doorway
    right = env.cell_at(3.25, 3.75)
    assert env.cell_at(4.75, 3.75) in set(env.visible(right)[0].tolist())  # past the furniture


def test_walking_goes_round_the_wall(env):
    a, b = env.cell_at(1.25, 3.75), env.cell_at(3.75, 3.75)
    assert math.dist(env.xy(a), env.xy(b)) == pytest.approx(2.5)
    assert float(env.field(b)[a]) > 5.5               # up to the door and back down
    path = env.path(a, b)
    assert path[0] == env.xy(a) and path[-1] == env.xy(b)
    assert all(env.line_walkable(p, q) for p, q in zip(path, path[1:]))
    assert not np.isfinite(env.field(b)[env.cell_at(4.25, 4.25)])  # nobody stands on furniture


def test_floor_is_what_an_entry_can_reach():
    spec = json.loads(json.dumps(TWO_ROOMS))
    spec["grid"][2] = "#....#....#"                  # brick up the doorway
    sealed = Environment(spec)
    assert not sealed.floor[sealed.cell_at(3.75, 3.25)]
    assert sealed.floor[sealed.cell_at(1.25, 3.25)]


def test_bad_floor_plans_are_refused():
    for change in ({"grid": ["#.#", "#."]}, {"grid": ["#x#"]}, {"entries": []}, {"cell": 5}):
        with pytest.raises(ValueError):
            Environment({**json.loads(json.dumps(TWO_ROOMS)), **change})


def test_a_run_is_repeatable_and_finds_the_casualty(env):
    params = Params.from_dict({"rescuers": 2, "seed": 7})
    first, second = simulate(env, params), simulate(env, params)
    assert first["summary"] == second["summary"]
    s = first["summary"]
    assert s["outcome"] == "rescued" and s["foundAt"] <= s["rescuedAt"]
    assert first["trace"]["frames"] and first["trace"]["heat"]
    assert len(first["trace"]["heat"][0]["heat"]) == int(env.floor.sum())
    # nobody walks through a wall
    for _, team in first["trace"]["frames"]:
        for x, y, *_ in team:
            assert env.walkable[env.cell_at(x, y)]


def test_the_casualty_can_be_placed(env):
    out = simulate(env, Params.from_dict({"rescuers": 1, "victim": {"x": 4.4, "y": 1.3}}))
    assert out["summary"]["victim"] == {"x": 4.25, "y": 1.25}


def test_more_rescuers_find_people_sooner():
    env = simulator.load_environment("apartment")
    def mean_find(n):
        runs = [simulate(env, Params.from_dict({"rescuers": n, "seed": k, "record": False, "dt": 0.5}))["summary"]
                for k in range(12)]
        return sum(r["foundAt"] if r["foundAt"] is not None else 600 for r in runs) / len(runs)
    assert mean_find(4) < mean_find(1)


def test_built_in_environments_load():
    ids = {e["id"] for e in simulator.list_environments() if "error" not in e}
    assert {"apartment", "eng-floor"} <= ids


def test_batch_compares_team_sizes_on_the_same_casualties():
    out = simulator.batch("apartment", {"seed": 3}, [1, 3], runs=4, workers=1)
    assert [s["rescuers"] for s in out["sizes"]] == [1, 3]
    ones, threes = out["runs"][:4], out["runs"][4:]
    assert [(r["x"], r["y"]) for r in ones] == [(r["x"], r["y"]) for r in threes]


# ---------------------------------------------------------------- routes
@pytest.fixture
def client(monkeypatch, tmp_path):
    from swarm.hub import app
    monkeypatch.setattr(simulator, "USER_ENVS", tmp_path / "user")
    with TestClient(app) as c:
        yield c


def test_routes_list_describe_and_run(client):
    envs = client.get("/api/sim/envs").json()["environments"]
    assert any(e["id"] == "apartment" and e["builtin"] for e in envs)
    env = client.get("/api/sim/envs/apartment").json()
    assert len(env["grid"]) * env["cell"] == env["depth"] and env["entryPoints"]
    out = client.post("/api/sim/run", json={"env": "apartment", "rescuers": 2, "seed": 1}).json()
    assert out["summary"]["outcome"] == "rescued" and out["trace"]["frames"]
    assert client.get("/api/sim/envs/nope").status_code == 404
    assert client.get("/simulator").status_code == 200


def test_saved_environments_are_checked_and_kept_apart_from_built_ins(client, tmp_path):
    body = {"name": "Apartment", "cell": 0.5, "grid": TWO_ROOMS["grid"], "entries": TWO_ROOMS["entries"]}
    saved = client.post("/api/sim/envs", json=body).json()
    assert saved["id"] == "apartment-2"              # never on top of the built-in
    assert (tmp_path / "user" / "apartment-2.json").is_file()
    assert client.post("/api/sim/envs", json={**body, "entries": []}).status_code == 422
    assert client.put("/api/sim/envs/apartment-2/scan", content=b"not a glb").status_code == 415
    assert client.put("/api/sim/envs/apartment-2/scan", content=b"glTF" + bytes(16)).status_code == 200
    assert client.delete("/api/sim/envs/apartment").status_code == 403
    assert client.delete("/api/sim/envs/apartment-2").status_code == 200
    assert not list((tmp_path / "user").glob("apartment-2.*"))


def test_batch_route_runs_in_its_own_process(client):
    job = client.post("/api/sim/batch", json={"env": "apartment", "teamSizes": [1, 2], "runs": 2}).json()
    for _ in range(100):
        status = client.get(f"/api/sim/batch/{job['job']}").json()
        if status["status"] != "running":
            break
        time.sleep(0.1)
    assert status["status"] == "done", status
    assert [s["rescuers"] for s in status["result"]["sizes"]] == [1, 2]


# ---------------------------------------------------------------- hazards
def hazard_env(row: str) -> Environment:
    """TWO_ROOMS with the doorway row replaced: the only way between the rooms runs along it."""
    spec = json.loads(json.dumps(TWO_ROOMS))
    spec["grid"][2] = row
    return Environment(spec)


def test_fire_cuts_a_route_and_nobody_is_placed_in_it():
    burning = hazard_env("#....f....#")           # the doorway is on fire
    assert not burning.floor[burning.cell_at(3.75, 3.25)]     # the far room can't be reached
    assert not burning.walkable[burning.cell_at(2.75, 1.25)]


def test_smoke_is_slow_to_cross_and_hard_to_see_into(env):
    smoky = hazard_env("#...sss...#")
    a, b = env.cell_at(1.25, 3.75), env.cell_at(3.75, 3.75)
    assert smoky.floor[b]                                       # still reachable
    assert float(smoky.field(b)[a]) > float(env.field(b)[a]) + 1.0
    origin, target = env.cell_at(1.25, 1.25), env.cell_at(2.75, 1.25)
    def chance(e):
        cells, pd = e.look(origin, 90, 1)   # one map update's worth of looking
        return float(pd[cells == target][0])
    assert chance(smoky) < chance(env) * 0.5
    out = simulate(smoky, Params.from_dict({"rescuers": 2, "seed": 5}))
    for _, team in out["trace"]["frames"]:
        for x, y, *_ in team:
            assert smoky.walkable[smoky.cell_at(x, y)]
