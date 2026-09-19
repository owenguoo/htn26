import asyncio

import pytest

from fastapi import FastAPI
from fastapi.testclient import TestClient

from swarm.control import Auth, Settings, install_routes
from swarm.detection import FrameSnapshot
from swarm.hub import Hub
from swarm.protocol import now_ms


def sighting(hub):
    hub.search.set_reference('v')
    hub.search.connect('p', 's')
    t = now_ms()
    hub.search.record_frame(FrameSnapshot('p', 's', 1, t, 10, 10, {'x': 4, 'y': 5}))
    body = dict(phoneId='p', streamId='s', seq=1, searchRevision=hub.search.revision)
    assert hub.search.accept_result(body | dict(t=t, targetVersion='v', width=10, height=10,
        boxes=[dict(x=.1, y=.1, w=.5, h=.5, detectionScore=.8, similarity=.99)],
        queueMs=0., inferenceMs=1., matchingMs=1.), now_ms=t)
    return body


def test_real_similarity_cannot_create_mock_find_or_dispatch():
    hub = Hub()
    hub.target.place(0, 0)
    sighting(hub)
    viewers = {'p': (0, 0, 0, None), 'other': (1, 1, 0, None)}
    hub.target.tick(viewers, 1000)
    commands = hub.target.tick(viewers, 2000)
    assert hub.target.pos is None
    assert hub.target.found_by is None
    assert not hub.target.responders
    assert not commands
    assert hub.phase == 'search'
    assert hub.state()['target'] is None


def test_confirmation_auth_exact_identity_unknown_position_and_phase():
    hub = Hub()
    app = FastAPI()
    install_routes(app, hub, Auth(Settings(operator_code='test')))
    with TestClient(app) as client:
        body = sighting(hub)
        assert client.post('/api/search/confirm', json=body).status_code == 401
        client.post('/api/session', json={'code': 'test'})
        assert client.post('/api/search/confirm', json=body | {'seq': 2}).status_code == 409
        response = client.post('/api/search/confirm', json=body)
        assert response.status_code == 200
        confirmed = response.json()['confirmation']
        assert confirmed['status'] == 'operator_confirmed_visual'
        assert confirmed['targetPosition'] is None
        assert confirmed['locationStatus'] == 'unknown'
        assert confirmed['observerPose'] == {'x': 4, 'y': 5}
        assert confirmed['searchRevision'] == body['searchRevision']
        assert hub.phase == 'found'
        assert hub.search.revision != body['searchRevision']
        assert not hub.search.latest
        assert hub.target.pos is None and not hub.target.responders
        assert not hub.mission_complete
        assert client.post('/api/search/confirm', json=body).status_code == 409
        asyncio.run(hub.set_phase('search'))
        assert hub.search.confirmation is None


def test_stale_reconnect_reset_and_threshold_invalidate_confirmation():
    for change in ('expire', 'reconnect', 'reset', 'threshold', 'clear'):
        hub = Hub()
        body = sighting(hub)
        if change == 'expire':
            hub.search.expire(now_ms() + 2000)
        elif change == 'reconnect':
            hub.search.connect('p', 'new')
        elif change == 'reset':
            hub.search.reset()
        elif change == 'threshold':
            hub.search.set_threshold(.9)
        else:
            hub.search.set_reference(None)
        assert not hub.search.confirm(body['phoneId'], body['streamId'], body['seq'], body['searchRevision'])


def test_real_mode_stays_after_clear_and_explicit_rehearsal_restores_mock():
    hub = Hub()
    app = FastAPI()
    install_routes(app, hub, Auth(Settings(operator_code='test')))
    with TestClient(app) as client:
        sighting(hub)
        client.post('/api/session', json={'code': 'test'})
        assert client.delete('/api/search/reference').status_code == 200
        hub.target.place(0, 0)
        assert hub.target.pos is None
        assert hub.search.mode == 'real'
        assert client.post('/api/search/rehearsal').status_code == 200
        hub.target.place(0, 0)
        viewers = {'p': (0, 0, 0, None)}
        hub.target.tick(viewers, 1000)
        hub.target.tick(viewers, 2000)
        assert hub.target.found_by == 'p'


def test_enter_real_clears_active_mock_guidance_and_mission_context(monkeypatch):
    from swarm.mission import MissionControl
    from swarm.hub import ROOM
    monkeypatch.delenv('OPENAI_API_KEY', raising=False)
    hub = Hub()
    sent = []

    class Phone:
        async def send(self, command):
            sent.append(command)

    hub.target.place(0, 0)
    hub.target.on_found('p', {'p': (0, 0, 0, None)}, 1000)
    hub.phones['p'] = Phone()
    hub.mission_complete = True
    asyncio.run(hub.enter_real_search())
    assert sent == [{'type': 'command', 'cmd': 'guide', 'clear': True}]
    assert hub.target.pos is None and not hub.target.responders
    assert not hub.mission_complete
    hub.phones.clear()
    sighting(hub)
    mission = MissionControl(hub, ROOM)
    snapshot = mission.snapshot()
    assert '"targetPosition": null' in snapshot
    assert '"observerPose": {"x": 4, "y": 5}' in snapshot
    for name in ('place_candidate', 'remove_candidate', 'set_responders'):
        with pytest.raises(ValueError, match='rehearsal'):
            asyncio.run(mission.execute(name, {'x': 0, 'y': 0, 'count': 1}))


def test_confirmed_audit_invalidated_by_reference_threshold_reset_and_reconnect():
    for change in ('replace', 'clear', 'threshold', 'reset', 'reconnect', 'disconnect'):
        hub = Hub()
        body = sighting(hub)
        assert hub.search.confirm('p', 's', 1, body['searchRevision'])
        if change == 'replace':
            hub.search.set_reference('v2')
        elif change == 'clear':
            hub.search.set_reference(None)
        elif change == 'threshold':
            hub.search.set_threshold(.8)
        elif change == 'reset':
            hub.search.reset()
        elif change == 'reconnect':
            hub.search.connect('p', 'new')
        else:
            hub.search.disconnect('p', 's')
        assert hub.search.confirmation is None


def test_confirmation_rejects_nonmatch_and_superseded_result():
    hub = Hub()
    body = sighting(hub)
    old = hub.search.latest['p'].result.model_dump()
    hub.search.record_frame(FrameSnapshot('p', 's', 2, old['t'], 10, 10, None))
    assert hub.search.accept_result(old | {'seq': 2, 'boxes': []}, now_ms=now_ms())
    assert not hub.search.confirm('p', 's', 1, body['searchRevision'])
    assert not hub.search.confirm('p', 's', 2, body['searchRevision'])


def test_real_mode_preserves_planner_scanning_and_coverage(monkeypatch):
    from swarm.hub import Phone
    hub = Hub()
    sighting(hub)
    phone = Phone('p', 1)
    phone.connected = True
    phone.frame = b'frame'
    phone.frame_at = now_ms()
    phone.external_pose = {'x': 0, 'y': 10, 'heading': 0, 't': now_ms(), 'confidence': 1, 'source': 'test'}
    hub.phones['p'] = phone
    hub.planner.enabled = True

    async def stop(_seconds):
        raise asyncio.CancelledError

    monkeypatch.setattr(asyncio, 'sleep', stop)
    with pytest.raises(asyncio.CancelledError):
        asyncio.run(hub.coverage_loop())
    assert hub.coverage.snapshot()['searched'] > 0
    assert hub.planner.enabled
    assert hub.planner.assignments
    assert not hub.target.responders
    assert not hub.mission_complete
