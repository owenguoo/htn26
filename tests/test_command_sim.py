import json

import pytest
from fastapi.testclient import TestClient

from swarm import command_sim
from swarm.command_sim import CommandSim, CommanderPolicy, CoveragePolicy, compare, layout, run_policy
from swarm.simulator import load_environment


def test_doorways_divide_the_plan_into_named_rooms():
    lay = layout(load_environment("apartment"))
    names = {r["name"] for r in lay.rooms}
    assert {"Bedroom 1", "Bedroom 2", "Bathroom", "Closet", "Kitchen", "Hall", "Living room"} <= names
    closet = next(r for r in lay.rooms if r["name"] == "Closet")
    door = lay.doors[closet["doors"][0]]
    assert door["blockable"] and len(door["rooms"]) == 2
    assert not next(d for d in lay.doors if d["widthM"] >= 3)["blockable"]   # the wide opening into the living room


def test_both_policies_face_the_same_hidden_incident():
    out = compare("apartment", seed=11)
    assert [r["key"] for r in out["runs"]] == ["coverage", "commander"]
    a, b = CommandSim("apartment", seed=11), CommandSim("apartment", seed=11)
    assert a.incident == b.incident and a.reports[0]["text"] == b.reports[0]["text"]
    assert CommandSim("apartment", seed=12).incident != a.incident


def test_observations_never_leak_the_incident():
    sim = CommandSim("eng-floor", seed=4)
    obs = sim.reset()
    hidden = sim.referee()
    text = json.dumps(obs)
    assert obs["casualty"] == {"found": False, "room": None, "contacts": 0, "needed": 2}
    assert all(d["blocked"] is None for d in obs["doors"])
    assert "responsive" not in text and str(hidden["casualty"]["x"]) not in text


def incident_where(env_id, want, tries=200):
    for seed in range(tries):
        sim = CommandSim(env_id, seed=seed)
        if want(sim):
            return sim
    raise AssertionError("no such incident in the first seeds")


def test_calling_from_the_door_misses_someone_who_cannot_answer():
    sim = incident_where("eng-floor", lambda s: not s.incident.responsive and s.lay.rooms[s.incident.room]["areaM2"] > 50
                         and not s.incident.blocked)
    room = sim.incident.room
    obs, done = sim.reset(), False
    obs, *_ = sim.step([{"crew": 0, "do": "call", "room": room}])
    while not any(r["kind"] == "clear" and r["room"] == room for r in obs["reports"]) and not obs["casualty"]["found"]:
        obs, _, done, _ = sim.step([])
        assert not done
    if not obs["casualty"]["found"]:   # (they can still be seen from the doorway: that's a find, not a miss)
        report = next(r for r in obs["reports"] if r["kind"] == "clear")
        assert report["method"] == "voice" and obs["rooms"][room]["status"] == "voice_clear"
        assert sim.metrics()["falseClears"] == 1


def test_a_blocked_doorway_is_only_known_once_a_crew_reaches_it():
    sim = incident_where("eng-floor", lambda s: s.incident.blocked)
    door = sim.lay.doors[sorted(sim.incident.blocked)[0]]
    room = next(r for r in door["rooms"] if len(sim.lay.rooms[r]["doors"]) == 1) if any(
        len(sim.lay.rooms[r]["doors"]) == 1 for r in door["rooms"]) else door["rooms"][0]
    obs = sim.reset()
    obs, *_ = sim.step([{"crew": 0, "do": "search", "room": room}])
    assert any(r["kind"] == "ack" for r in obs["reports"])          # "on my way" came straight back
    for _ in range(400):
        if any(r["kind"] == "blocked" for r in obs["reports"]) or sim.done:
            break
        obs, *_ = sim.step([])
    blocked = [r for r in obs["reports"] if r["kind"] == "blocked"]
    if blocked:                                                       # (another door may have been nearer)
        assert obs["doors"][blocked[0]["door"]]["blocked"] is True
        assert obs["crews"][0]["status"] == "idle"


def test_on_my_way_is_not_arrival():
    sim = CommandSim("apartment", seed=3)
    obs = run_until_found(sim)
    obs, *_ = sim.step([{"crew": c["id"], "do": "respond"} for c in obs["crews"]][:2])
    acks = [r for r in obs["reports"] if r["kind"] == "ack" and "casualty" in r["text"]]
    assert len(acks) == 2 and obs["casualty"]["contacts"] < 2 and not sim.done
    while not sim.done:
        obs, *_ = sim.step([])
    assert obs["casualty"]["contacts"] == 2 and sim.metrics()["outcome"] == "rescued"
    assert sum(r["kind"] == "arrived" for r in obs["reports"]) == 2


def run_until_found(sim):
    policy, obs = CommanderPolicy(), sim.reset()
    while not obs["casualty"]["found"]:
        obs, _, done, _ = sim.step(policy.act(obs))
        assert not done
    return obs


def test_wasted_trips_cost_reward():
    sim = CommandSim("apartment", seed=5)
    run_until_found(sim)
    before = sim.total_reward
    sim.apply({"crew": 0, "do": "search", "room": 0})    # the search is over: nobody needs to go there
    assert sim.metrics()["unnecessaryTrips"] == 1 and sim.total_reward == before + command_sim.REWARD_UNNECESSARY_TRIP


def test_the_commander_beats_the_coverage_planner_on_average():
    def mean_reward(policy):
        return sum(run_policy(CommandSim("apartment", seed=k), policy())["metrics"]["reward"] for k in range(15)) / 15
    assert mean_reward(CommanderPolicy) > mean_reward(CoveragePolicy)


def test_compare_route():
    from swarm.hub import app
    with TestClient(app) as client:
        out = client.post("/api/sim/compare", json={"env": "apartment", "seed": 2, "rescuers": 2}).json()
        assert len(out["runs"]) == 2 and out["referee"]["casualty"]["room"] is not None
        assert {"elapsed", "areasChecked", "unnecessaryTrips", "physicalContacts", "reward"} <= out["runs"][0]["metrics"].keys()
        env = client.get("/api/sim/envs/apartment").json()
        assert len(env["roomOf"]) == len(env["grid"]) * len(env["grid"][0]) and env["doors"]
