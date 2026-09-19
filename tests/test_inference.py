import asyncio

import httpx
from fastapi.testclient import TestClient

from swarm import hub as module
from swarm.protocol import pack


def test_public_mutations_require_auth():
    with TestClient(module.app) as client:
        assert client.post('/api/detections', json={}).status_code == 401
        assert client.post('/api/pose', json={}).status_code == 401
        assert client.delete('/api/search/reference').status_code == 401
        with client.websocket_connect('/ws/dashboard?role=console') as ws:
            ws.receive_json()
            ws.send_json({'type': 'phase', 'phase': 'end'})
            while True:
                message = ws.receive_json()
                if message.get('type') != 'state':
                    break
            assert message.get('error') == 'operator authentication required'
        assert module.hub.phase == 'search'


def test_latest_pending_fairness_and_bound():
    from swarm.inference import Bridge
    from swarm.control import Settings
    async def run():
        async with httpx.AsyncClient() as client:
            bridge = Bridge(Settings(max_phones=2), client)
            bridge.state = {'active': True, 'searchRevision': 'r', 'targetVersion': 'v'}
            def frame(phone, seq):
                return pack({'phoneId': phone, 'seq': seq, 'searchRevision': 'r'}, b'jpg')
            bridge.offer(frame('a', 1))
            bridge.offer(frame('b', 1))
            bridge.offer(frame('a', 2))
            bridge.offer(frame('c', 1))
            assert len(bridge.pending) == 2
            assert bridge.take()[0]['seq'] == 2
            assert bridge.take()[0]['phoneId'] == 'b'
    asyncio.run(run())


def test_operator_session_origin_and_all_subscriber_routes(monkeypatch):
    from swarm.control import Auth, Settings, install_routes
    from fastapi import FastAPI
    hub = module.Hub()
    settings = Settings(operator_code='test', bridge_key='bridge')
    auth = Auth(settings)
    app = FastAPI()
    install_routes(app, hub, auth)
    with TestClient(app) as client:
        assert not client.get('/api/session').json()['authenticated']
        assert client.post('/api/session', json={'code': 'test'}, headers={'Origin': 'https://evil.test'}).status_code == 403
        assert client.post('/api/session', json={'code': 'test'}).status_code == 200
        assert client.get('/api/search').status_code == 200
        assert client.put('/api/search/threshold', json={'threshold': .8}, headers={'Origin': 'https://evil.test'}).status_code == 403
        assert client.put('/api/search/threshold', json={'threshold': .8}).status_code == 200
        assert hub.search.threshold == .8
    monkeypatch.setattr(module, 'auth', auth)
    with TestClient(module.app) as client:
        with client.websocket_connect('/ws/frames', headers={'Authorization': 'Bearer bridge'}) as ws:
            ws.send_json({'type': 'phase', 'phase': 'end'})
            assert ws.receive_json()['error'] == 'operator authentication required'
        assert module.hub.phase == 'search'


def test_slow_inference_keeps_latest_and_discards_transition():
    from swarm.inference import Bridge
    from swarm.control import Settings
    from swarm.protocol import now_ms
    async def run():
        started, release = asyncio.Event(), asyncio.Event()
        callbacks = []
        async def boundary(request):
            if request.url.path == '/v1/match':
                started.set()
                await release.wait()
                return httpx.Response(200, json=dict(target_id='active', target_version='v', phone_id='stream', frame_id='1',
                    captured_at=timestamp / 1000, width=100, height=100, candidates=[], queue_ms=1., inference_ms=1., matching_ms=1.))
            callbacks.append(request.url.path)
            return httpx.Response(200, json={'ok': True})
        async with httpx.AsyncClient(transport=httpx.MockTransport(boundary)) as client:
            bridge = Bridge(Settings(inference_url='http://127.0.0.1:8001', inference_key='key', bridge_key='bridge'), client)
            bridge.state = dict(active=True, searchRevision='r', targetVersion='v', threshold=.7)
            timestamp = now_ms()
            def packet(seq):
                return pack(dict(phoneId='phone', streamId='stream', seq=seq, t=timestamp,
                    width=100, height=100, searchRevision='r', pose={'x': 1}), b'jpeg')
            bridge.offer(packet(1))
            item = bridge.take()
            task = asyncio.create_task(bridge.process(*item))
            await started.wait()
            for seq in range(2, 100):
                bridge.offer(packet(seq))
            assert len(bridge.pending) == 1
            assert not bridge.ready
            assert bridge.pending['phone'][0]['seq'] == 99
            bridge.state = dict(active=False, searchRevision='new')
            release.set()
            await task
            assert callbacks == []
    asyncio.run(run())


def test_reference_restart_and_backoff():
    from swarm.inference import Bridge
    from swarm.control import Settings
    from swarm.protocol import now_ms
    async def run():
        statuses = []
        code = 429
        async def boundary(request):
            if request.url.path == '/v1/match':
                return httpx.Response(code)
            statuses.append(__import__('json').loads(request.content))
            return httpx.Response(200)
        async with httpx.AsyncClient(transport=httpx.MockTransport(boundary)) as client:
            bridge = Bridge(Settings(inference_url='http://127.0.0.1:8001', inference_key='key', bridge_key='bridge'), client)
            bridge.state = dict(active=True, searchRevision='r', targetVersion='v', threshold=.7)
            header = dict(phoneId='phone', streamId='s', seq=1, t=now_ms(), width=10, height=10, searchRevision='r')
            await bridge.process(header, b'jpg')
            assert 0 < bridge.backoff_until - asyncio.get_running_loop().time() <= 1
            code = 404
            await bridge.process(header, b'jpg')
            assert statuses[-1] == dict(searchRevision='r', status='reference_unavailable')
            assert bridge.state == {}
    asyncio.run(run())


def test_reference_clear_wins_slow_upload(monkeypatch):
    from swarm.control import Auth, Settings, install_routes
    from fastapi import FastAPI
    async def run():
        entered, release = asyncio.Event(), asyncio.Event()
        async def worker(request):
            if request.method == 'PUT':
                entered.set()
                await release.wait()
                return httpx.Response(200, json={'target_version': 'late'})
            return httpx.Response(204)
        real_client = httpx.AsyncClient
        transport = httpx.MockTransport(worker)
        monkeypatch.setattr(httpx, 'AsyncClient', lambda **kwargs: real_client(transport=transport, **kwargs))
        hub = module.Hub()
        auth = Auth(Settings(inference_url='http://127.0.0.1:8001', inference_key='key', bridge_key='bridge', operator_code='code'))
        app = FastAPI()
        install_routes(app, hub, auth)
        async with real_client(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            await client.post('/api/session', json={'code': 'code'})
            registration = asyncio.create_task(client.put('/api/search/reference?box=0,0,10,10', content=b'jpg'))
            await entered.wait()
            clear = asyncio.create_task(client.delete('/api/search/reference'))
            await asyncio.sleep(0)
            release.set()
            assert (await registration).status_code == 409
            assert (await clear).status_code == 200
            assert hub.search.target_version is None
    asyncio.run(run())


def test_frame_receiver_reconnects_with_bounded_buffer():
    from websockets.asyncio.server import serve
    from swarm.inference import Bridge
    from swarm.control import Settings
    async def run():
        connected = asyncio.Event()
        count = 0
        async def server(ws):
            nonlocal count
            count += 1
            if count == 1:
                await ws.close()
                return
            await ws.send(pack({'phoneId': 'p', 'seq': 1, 'searchRevision': 'r'}, b'jpg'))
            connected.set()
            await ws.wait_closed()
        async with serve(server, '127.0.0.1', 0) as server_socket:
            port = server_socket.sockets[0].getsockname()[1]
            async with httpx.AsyncClient() as client:
                bridge = Bridge(Settings(hub_url=f'http://127.0.0.1:{port}'), client)
                bridge.state = dict(active=True, searchRevision='r')
                task = asyncio.create_task(bridge.receive())
                await asyncio.wait_for(connected.wait(), 4)
                for _ in range(100):
                    if bridge.pending:
                        break
                    await asyncio.sleep(.01)
                assert list(bridge.pending) == ['p']
                assert count == 2
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
    asyncio.run(run())


def test_generation_status_cannot_restore_cleared_reference():
    from swarm.control import Auth, Settings, install_routes
    from fastapi import FastAPI
    hub = module.Hub()
    hub.search.set_reference('version')
    revision = hub.search.revision
    app = FastAPI()
    install_routes(app, hub, Auth(Settings(bridge_key='key')))
    with TestClient(app) as client:
        headers = {'Authorization': 'Bearer key'}
        assert client.post('/api/search/status', headers=headers, json={'searchRevision': revision, 'status': 'reference_unavailable'}).status_code == 200
        assert hub.search.target_version is None
        assert client.post('/api/search/status', headers=headers, json={'searchRevision': revision, 'status': 'available'}).status_code == 409


def test_delivery_rechecks_revision_after_phone_lock(monkeypatch):
    from swarm.control import Auth, Settings
    from swarm.detection import FrameSnapshot
    from swarm.protocol import now_ms
    from starlette.requests import Request
    from fastapi import HTTPException
    async def run():
        hub = module.Hub()
        hub.search.set_reference('v')
        hub.search.connect('p', 's')
        timestamp = now_ms()
        hub.search.record_frame(FrameSnapshot('p', 's', 1, timestamp, 10, 10, None))
        phone = module.Phone(id='p', index=1, name='p')
        hub.phones['p'] = phone
        monkeypatch.setattr(module, 'hub', hub)
        monkeypatch.setattr(module, 'auth', Auth(Settings(bridge_key='key')))
        request = Request({'type': 'http', 'headers': [(b'authorization', b'Bearer key')]})
        body = dict(phoneId='p', streamId='s', seq=1, t=timestamp, searchRevision=hub.search.revision,
            targetVersion='v', width=10, height=10, boxes=[], queueMs=0., inferenceMs=1., matchingMs=1.)
        await phone.send_lock.acquire()
        callback = asyncio.create_task(module.post_detections(body, request))
        await asyncio.sleep(0)
        assert 'p' in hub.search.latest
        hub.search.set_reference(None)
        phone.send_lock.release()
        try:
            await callback
        except HTTPException as error:
            assert error.status_code == 409
        else:
            raise AssertionError('stale callback was delivered')
    asyncio.run(run())


def test_bridge_normalizes_valid_response_and_rejects_wrong_identity():
    from swarm.inference import Bridge
    from swarm.control import Settings
    from swarm.protocol import now_ms
    import json
    import pytest
    async def run():
        timestamp = now_ms()
        wrong = False
        posted = []
        async def boundary(request):
            if request.url.path == '/v1/match':
                assert request.url.params['phone_id'] == 's'
                assert request.url.params['frame_id'] == '1'
                return httpx.Response(200, json=dict(target_id='active', target_version='v', phone_id='wrong' if wrong else 's',
                    frame_id='1', captured_at=timestamp / 1000, width=100, height=100,
                    candidates=[dict(box=[10., 20., 50., 80.], detection_score=.9, similarity=.8)],
                    queue_ms=0., inference_ms=5., matching_ms=1.))
            if request.url.path == '/api/detections':
                posted.append(json.loads(request.content))
            return httpx.Response(200, json={})
        async with httpx.AsyncClient(transport=httpx.MockTransport(boundary)) as client:
            bridge = Bridge(Settings(inference_url='http://127.0.0.1:8001', inference_key='key', bridge_key='bridge'), client)
            bridge.state = dict(active=True, searchRevision='r', targetVersion='v', threshold=.7)
            header = dict(phoneId='p', streamId='s', seq=1, t=timestamp, width=100, height=100, searchRevision='r')
            await bridge.process(header, b'jpg')
            assert posted[0]['boxes'][0] == dict(x=.1, y=.2, w=.4, h=.6, label='person', detectionScore=.9, similarity=.8)
            assert posted[0]['t'] == timestamp
            wrong = True
            with pytest.raises(ValueError, match='identity'):
                await bridge.process(header, b'jpg')
            assert len(posted) == 1
    asyncio.run(run())
