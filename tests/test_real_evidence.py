"""Real detections as search evidence: matches raise the probability map and become possible sightings,
near misses only nudge the heatmap, other people change nothing, and nothing ever confirms a find."""
import asyncio

from fastapi.testclient import TestClient

from swarm.control import Auth, Settings
from swarm.detection import FrameSnapshot
from swarm.hub import Hub
from swarm.protocol import now_ms

POSE = {'x': 0.0, 'y': 12.0, 'heading': 0.0}  # facing the stage from the back of the room


def result(hub, similarity, *, h=.5, pose=POSE, seq=1):
    """Register a frame and accept a real result for it; returns the accepted entry."""
    if hub.search.target_version is None:
        asyncio.run(hub.enter_real_search())
        hub.search.set_reference('v')
        hub.search.connect('p', 's')
    t = now_ms()
    hub.search.record_frame(FrameSnapshot('p', 's', seq, t, 480, 640, pose))
    body = dict(phoneId='p', streamId='s', seq=seq, searchRevision=hub.search.revision, t=t, targetVersion='v',
                width=480, height=640, boxes=[dict(x=.4, y=.2, w=.2, h=h, detectionScore=.9, similarity=similarity)],
                queueMs=0., inferenceMs=1., matchingMs=1.)
    assert hub.search.accept_result(body, now_ms=t)
    return hub.search.latest['p'], body


def ahead(hub):
    """Probability share of the cells in front of the phone (toward the stage)."""
    cov = hub.coverage
    return sum(p for i, p in enumerate(cov.prob) if (i // cov.cols) * cov.cell < POSE['y'] - 1)


def test_match_raises_probability_and_makes_a_possible_sighting_but_never_a_find():
    hub = Hub()
    before = ahead(hub)
    entry, _ = result(hub, .92)
    assert hub.real_evidence(entry) == 1
    assert ahead(hub) > before
    s = hub.sightings.best()
    assert s and hub.sightings.confidence(s) >= .4
    assert s['y'] < POSE['y']  # in front of the phone, toward the stage
    assert hub.check_sightings({'p': (0, 12, 0, None)}, now_ms()) == []  # the operator confirms, not the hub
    assert not hub.target.found_by and not hub.target.responders
    assert any('Possible sighting' in line['text'] for line in hub.planner.log)


def test_near_miss_only_nudges_the_heatmap():
    hub = Hub()
    before = ahead(hub)
    entry, _ = result(hub, hub.search.threshold - .05)
    assert hub.real_evidence(entry) == 1
    assert ahead(hub) > before
    assert not hub.sightings.items  # below "possible": heatmap only


def test_someone_else_changes_nothing():
    hub = Hub()
    entry, _ = result(hub, .2)
    prob = hub.coverage.prob.copy()
    assert hub.real_evidence(entry) == 0
    assert hub.coverage.prob == prob and not hub.sightings.items


def test_no_pose_or_not_searching_means_no_evidence():
    hub = Hub()
    entry, _ = result(hub, .95, pose={'x': 1, 'y': 2})  # no heading: can't tell where the box points
    assert hub.real_evidence(entry) == 0
    asyncio.run(hub.set_phase('lobby'))
    entry, _ = result(hub, .95, seq=2)
    assert hub.real_evidence(entry) == 0


def test_posting_a_detection_reports_the_evidence_it_added(monkeypatch):
    from swarm import hub as module
    hub = Hub()
    monkeypatch.setattr(module, 'hub', hub)
    monkeypatch.setattr(module, 'auth', Auth(Settings(bridge_key='bridge')))
    _, body = result(hub, .9)
    hub.search._accepted_seq.pop('p')  # let the endpoint accept this frame's result itself
    hub.search.latest.pop('p')
    with TestClient(module.app) as client:
        response = client.post('/api/detections', json=body, headers={'Authorization': 'Bearer bridge'})
    assert response.status_code == 200, response.text
    assert response.json()['evidence'] == 1
    assert hub.sightings.best()
