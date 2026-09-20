import asyncio

import pytest

from fastapi import FastAPI
from fastapi.testclient import TestClient

from swarm.control import Auth, Settings, install_routes
from swarm.detection import FrameSnapshot
from swarm.hub import Hub
from swarm.protocol import now_ms


def sighting(hub):
    # A hub starts in "calibrate"; a sighting only exists once the operator has started the search.
    hub.phase = 'search'
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
    install_routes(app, hub, Auth(Settings()))
    with TestClient(app) as client:
        body = sighting(hub)
        assert client.post('/api/search/confirm', json=body, headers={'Origin': 'https://evil.test'}).status_code == 403
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
    install_routes(app, hub, Auth(Settings()))
    with TestClient(app) as client:
        sighting(hub)
        assert client.delete('/api/search/reference').status_code == 200
        hub.target.place(0, 0)
        assert hub.target.pos is None
        assert hub.search.mode == 'real'
        assert client.post('/api/search/rehearsal').status_code == 200
        hub.target.place(0, 0)
        viewers = {'p': (0, 0, 0, None)}
        from swarm.hub import Phone
        phone = Phone('p', 1, seat={'x': 0, 'y': 2}, heading=0)
        hub.phones['p'] = phone
        boxes = hub.mock_detector._box(2, 0, .95)
        asyncio.run(hub.ingest_detections(phone, [boxes]))
        assert hub.sightings.best() is not None
        assert len(set(hub.coverage.prob)) > 1
        assert hub.check_sightings(viewers, now_ms())
        assert hub.target.found_by == 'p'
        assert hub.target.fix == pytest.approx((0, 0), abs=.02)


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
    hub.target.confirm('p', 0, 0, .95, {'p': (0, 0, 0, None)}, 1000)
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


@pytest.mark.parametrize('newer', ['search', 'rehearsal', 'threshold', 'reference'])
def test_invalidated_confirmation_keeps_authoritative_phase_without_success(monkeypatch, newer):
    import httpx
    from swarm.hub import Phone

    async def run():
        hub = Hub()
        body = sighting(hub)
        phone = Phone('p', 1)
        phases = []
        notes = []

        class Socket:
            async def send_json(self, message):
                if message['type'] == 'phase':
                    phases.append(message['phase'])

        phone.ws = Socket()
        hub.phones['p'] = phone
        paused, resume = asyncio.Event(), asyncio.Event()
        calls = 0

        async def clear():
            nonlocal calls
            calls += 1
            if calls == 1:
                paused.set()
                await resume.wait()

        monkeypatch.setattr(hub, 'clear_detection_overlays', clear)
        monkeypatch.setattr(hub.planner, 'note', lambda text, *args: notes.append(text))
        app = FastAPI()
        auth = Auth(Settings())
        install_routes(app, hub, auth)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            confirmation = asyncio.create_task(client.post('/api/search/confirm', json=body))
            await paused.wait()
            if newer == 'search':
                await hub.set_phase('search')
            elif newer == 'rehearsal':
                assert (await client.post('/api/search/rehearsal')).status_code == 200
            elif newer == 'reference':
                assert (await client.delete('/api/search/reference')).status_code == 200
            else:
                assert (await client.put('/api/search/threshold', json={'threshold': .8})).status_code == 200
            resume.set()
            response = await confirmation
        assert phases == [hub.phase]
        assert hub.phase == ('search' if newer in ('search', 'rehearsal') else 'found')
        assert response.status_code == 409
        assert hub.search.confirmation is None
        assert not any('Operator confirmed' in note for note in notes)

    asyncio.run(run())


def test_phase_send_rechecks_transition_after_phone_lock(monkeypatch):
    from swarm.hub import Phone

    async def run():
        hub = Hub()
        phone = Phone('p', 1)
        phases = []
        waiting, release, newer_committed = asyncio.Event(), asyncio.Event(), asyncio.Event()

        class Gate:
            async def __aenter__(self):
                waiting.set()
                await release.wait()

            async def __aexit__(self, *_args):
                pass

        class Socket:
            async def send_json(self, message):
                phases.append(message['phase'])

        async def clear():
            if hub.phase == 'search':
                newer_committed.set()

        phone.ws = Socket()
        phone.send_lock = Gate()
        hub.phones['p'] = phone
        monkeypatch.setattr(hub, 'clear_detection_overlays', clear)
        older = asyncio.create_task(hub.set_phase('found'))
        await waiting.wait()
        newer = asyncio.create_task(hub.set_phase('search'))
        await newer_committed.wait()
        release.set()
        await asyncio.gather(older, newer)
        assert hub.phase == 'search'
        assert phases == ['search']
        assert hub.planner.enabled

    asyncio.run(run())


@pytest.mark.parametrize('edit', ['threshold', 'reference'])
def test_ordinary_phase_publication_survives_search_edit(monkeypatch, edit):
    from swarm.hub import Phone

    async def run():
        hub = Hub()
        phone = Phone('p', 1)
        phases = []
        paused, resume = asyncio.Event(), asyncio.Event()

        class Socket:
            async def send_json(self, message):
                phases.append(message['phase'])

        async def clear():
            paused.set()
            await resume.wait()

        phone.ws = Socket()
        hub.phones['p'] = phone
        monkeypatch.setattr(hub, 'clear_detection_overlays', clear)
        transition = asyncio.create_task(hub.set_phase('end'))
        await paused.wait()
        if edit == 'threshold':
            hub.search.set_threshold(.8)
        else:
            hub.search.set_reference('replacement')
        resume.set()
        assert await transition
        assert phases == [hub.phase] == ['end']
        assert not hub.planner.enabled

    asyncio.run(run())


def test_real_mode_rejects_geometric_rehearsal_evidence():
    from swarm.hub import Phone
    hub = Hub()
    hub.phase = 'search'  # detections only land while the search is running
    phone = Phone('p', 1, seat={'x': 0, 'y': 2}, heading=0)
    hub.phones['p'] = phone
    boxes = [hub.mock_detector._box(2, 0, .99)]
    asyncio.run(hub.ingest_detections(phone, boxes))
    assert hub.sightings.best()
    asyncio.run(hub.enter_real_search())
    assert not hub.sightings.items
    assert len(set(hub.coverage.prob)) == 1
    before = hub.coverage.prob.copy()
    asyncio.run(hub.ingest_detections(phone, boxes))
    assert not hub.sightings.items
    assert hub.coverage.prob == before
    assert hub.check_sightings({'p': (0, 2, 0, None)}, now_ms()) == []
    assert hub.target.confirm('p', 0, 0, .99, {'p': (0, 2, 0, None)}, now_ms()) == []
    assert not hub.target.found_by and not hub.target.complete()


def test_waiting_mock_overlay_cannot_cross_into_real_search():
    from swarm.hub import Phone

    async def run():
        hub = Hub()
        phone = Phone('p', 1, seat={'x': 0, 'y': 2}, heading=0)
        sent = []

        class Socket:
            async def send_json(self, message):
                sent.append(message)

        phone.ws = Socket()
        await phone.send_lock.acquire()
        pending = asyncio.create_task(hub.ingest_detections(phone, [hub.mock_detector._box(2, 0, .99)]))
        await asyncio.sleep(0)
        await hub.enter_real_search()
        phone.send_lock.release()
        await pending
        assert not sent
        assert not hub.sightings.items

    asyncio.run(run())


def test_rehearsal_overlay_carries_stream_and_search_identity():
    from swarm.hub import Phone
    hub = Hub()
    sent = []

    class Socket:
        async def send_json(self, message):
            sent.append(message)

    phone = Phone('p', 1, stream_id='stream', frame_seq=7)
    phone.ws = Socket()
    boxes = [hub.mock_detector._box(2, 0, .99)]
    asyncio.run(hub.ingest_detections(phone, boxes))
    assert sent == [{'type': 'command', 'cmd': 'rehearsal_detections', 'boxes': boxes,
                     'streamId': 'stream', 'seq': 7, 'searchRevision': hub.search.revision, 'ttlMs': 1500}]
