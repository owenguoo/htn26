import numpy as np
from experiments.access_rl.env import Batch, scenarios, COMBOS, N_FEATURES, geometry
from experiments.access_rl.policy import choose, transition, options


def test_no_hidden_truth_in_policy_input():
    c = scenarios([1, 2])
    c[1] = dict(c[0], truth=1 - c[0]["truth"])
    b = Batch(c)
    x, m, p = b.observe()
    assert x.shape == (2, N_FEATURES)
    np.testing.assert_array_equal(x[0], x[1])
    np.testing.assert_array_equal(p[0], p[1])
    np.testing.assert_array_equal(m[0], m[1])


def test_preparation_sequence_and_no_free_reward():
    b = Batch(scenarios([0]))
    b.deadline[:] = 300
    assert not b.masks()[0, 4:8].any()
    for stage in range(3):
        r, _, _ = b.step([8])
        assert not r.any()
        assert not b.masks()[0, 8]
        r, _, _ = b.step([9])
        assert not r.any()
        assert b.phase[0] == stage + 1
    assert b.masks()[0, 4:8].all()
    assert not b.masks()[0, 8]


def test_vector_and_single_replay_agree():
    cases = scenarios(range(32))
    batch = Batch(cases)
    while not batch.done.all():
        batch.step(choose(batch, preparation=True))
    for i, c in enumerate(cases):
        b = Batch([c])
        while not b.done.all():
            b.step(choose(b, preparation=True))
        assert b.reward[0] == batch.reward[i]
        np.testing.assert_allclose(b.posterior[0], batch.posterior[i], atol=1e-6)
    np.testing.assert_allclose(batch.posterior.sum(1), 1, atol=1e-6)
    assert (batch.reward <= 3).all()


def test_planner_scheduling_matches_environment():
    b = Batch(scenarios([3]))
    b.deadline[:] = 300
    for action in [8, 0, 8, 1, 8, 9, 4, 5, 9, 9]:
        if not b.masks()[0, action]:
            continue
        state = b.state()
        _, opts = options(state)
        expected, _ = transition(state, action, dict(opts)[action])
        b.step([action])
        actual = b.state()
        for key in ["phase", "used", "pos", "jobs"]:
            assert actual[key] == expected[key], key
        np.testing.assert_allclose(actual["t"], expected["t"], atol=1e-5)
        np.testing.assert_allclose(actual["ends"], expected["ends"], atol=2e-5)


def test_target_prior_and_paths():
    assert np.all(COMBOS.sum(1) == 3)
    for c in scenarios(range(30)):
        assert c["truth"].sum() == 3
        assert np.isclose(c["posterior"].sum(), 1)
    assert np.isfinite(geometry()[3]).all()
