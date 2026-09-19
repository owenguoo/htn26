"""Real network boundaries, with an optional independently running pretrained worker."""
import asyncio
from contextlib import AsyncExitStack, asynccontextmanager, suppress
import io
import json
import os
from pathlib import Path
import socket
import time

import httpx
from fastapi import FastAPI, Request, Response, HTTPException
from PIL import Image
import pytest
import uvicorn
from websockets.asyncio.client import connect

from swarm import hub as module
from swarm.control import Auth, Settings, install_routes
from swarm.inference import Bridge
from swarm.protocol import now_ms, pack, unpack


def jpeg(color='white'):
    output = io.BytesIO()
    Image.new('RGB', (100, 100), color).save(output, 'JPEG')
    return output.getvalue()


@asynccontextmanager
async def server(app, port=0):
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('127.0.0.1', port))
    port = sock.getsockname()[1]
    instance = uvicorn.Server(uvicorn.Config(app, log_level='error', lifespan='off', ws='websockets-sansio'))
    task = asyncio.create_task(instance.serve(sockets=[sock]))
    try:
        async with asyncio.timeout(5):
            while not instance.started:
                if task.done():
                    await task
                await asyncio.sleep(.01)
        yield f'http://127.0.0.1:{port}'
    finally:
        instance.should_exit = True
        await asyncio.wait_for(task, 5)
        sock.close()


class FakeWorker:
    def __init__(self, delay=0):
        self.delay = delay
        self.version = None
        self.key = 'test-model-key'
        self.inflight = 0
        self.maximum = 0
        self.calls = []
        self.app = FastAPI()
        self.app.add_api_route('/v1/targets/active', self.target, methods=['GET', 'PUT', 'DELETE'])
        self.app.add_api_route('/v1/match', self.match, methods=['POST'])

    async def target(self, request: Request):
        if request.headers.get('authorization') != f'Bearer {self.key}':
            raise HTTPException(401)
        if request.method == 'PUT':
            self.version = str(time.monotonic_ns())
        if request.method == 'DELETE':
            self.version = None
            return Response(status_code=204)
        if self.version is None:
            raise HTTPException(404)
        return {'target_id': 'active', 'target_version': self.version}

    async def match(self, request: Request):
        params = request.query_params
        image = Image.open(io.BytesIO(await request.body()))
        present = image.getpixel((0, 0))[0] > 128
        self.inflight += 1
        self.maximum = max(self.maximum, self.inflight)
        self.calls.append((params['phone_id'], int(params['frame_id'])))
        try:
            await asyncio.sleep(self.delay)
            return dict(target_id='active', target_version=self.version, phone_id=params['phone_id'],
                frame_id=params['frame_id'], captured_at=float(params['captured_at']),
                width=image.width, height=image.height, candidates=[dict(box=[10, 10, 80, 90],
                detection_score=.9, similarity=.95)] if present else [],
                queue_ms=0., inference_ms=self.delay * 1000, matching_ms=0.)
        finally:
            self.inflight -= 1


@asynccontextmanager
async def system(monkeypatch, worker_url, key='test-model-key'):
    hub = module.Hub()
    settings = Settings(inference_url=worker_url, inference_key=key, bridge_key='test-bridge-key', operator_code='test-code')
    auth = Auth(settings)
    monkeypatch.setattr(module, 'hub', hub)
    monkeypatch.setattr(module, 'auth', auth)
    app = FastAPI()
    install_routes(app, hub, auth)
    app.add_api_websocket_route('/ws/phone', module.ws_phone)
    app.add_api_websocket_route('/ws/frames', module.ws_frames)
    app.add_api_websocket_route('/ws/dashboard', module.ws_dashboard)
    app.add_api_route('/api/detections', module.post_detections, methods=['POST'])
    async with server(app) as url, httpx.AsyncClient(base_url=url, timeout=5) as client:
        await client.post('/api/session', json={'code': 'test-code'})
        bridge = Bridge(Settings(inference_url=worker_url, inference_key=key,
            hub_url=url, bridge_key='test-bridge-key'), client)
        task = asyncio.create_task(bridge.run())
        try:
            yield hub, bridge, client, task, url.replace('http:', 'ws:')
        finally:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
            await client.delete('/api/search/reference')


async def receive_json(ws, predicate, timeout=5):
    async with asyncio.timeout(timeout):
        async for raw in ws:
            if isinstance(raw, str):
                message = json.loads(raw)
                if predicate(message):
                    return message


async def join(ws, phone):
    await ws.send(json.dumps(dict(type='hello', phoneId=phone, name=phone)))
    return await receive_json(ws, lambda m: m.get('type') == 'welcome')


async def wait_active(bridge):
    async with asyncio.timeout(5):
        while not bridge.state.get('active'):
            await asyncio.sleep(.02)


async def replay(monkeypatch, worker_url, reference, present, absent, box, key='test-model-key'):
    async with system(monkeypatch, worker_url, key) as (hub, bridge, client, bridge_task, url):
        registered = await client.put('/api/search/reference', params={'box': box}, content=reference)
        assert registered.status_code == 200, registered.text
        await wait_active(bridge)
        headers = {'Cookie': f'{Auth.cookie}={client.cookies[Auth.cookie]}'}
        async with connect(url + '/ws/phone') as phone, connect(url + '/ws/dashboard?role=console',
                additional_headers=headers, origin=url.replace('ws:', 'http:')) as console:
            welcome = await join(phone, 'replay')
            await console.send(json.dumps(dict(type='hide', phoneId='replay', hidden=True)))
            await receive_json(console, lambda m: m.get('type') == 'state' and
                any(p['id'] == 'replay' and p['hidden'] for p in m.get('phones', [])))
            results = []
            ages = []
            for seq, frame in enumerate((present, absent)):
                await phone.send(pack(dict(type='frame', seq=seq, tCapture=now_ms()), frame))
                result = await receive_json(phone, lambda m: m.get('cmd') == 'detections' and m.get('seq') == seq)
                assert result['phoneId'] == 'replay' and result['streamId'] == welcome['streamId']
                assert result['searchRevision'] == registered.json()['searchRevision']
                age = now_ms() - result['t']
                assert 0 <= age < 1500
                ages.append(round(age, 2))
                results.append(result)
                async with asyncio.timeout(5):
                    async for raw in console:
                        if isinstance(raw, bytes):
                            header, image = unpack(raw)
                            assert header['phoneId'] == 'replay' and header['seq'] == seq
                            assert header['streamId'] == welcome['streamId']
                            assert image == frame
                            break
                    else:
                        pytest.fail('Console closed before receiving the hidden phone frame')
                state = await receive_json(console, lambda m: m.get('type') == 'state' and
                    any(s.get('seq') == seq for s in m.get('search', {}).get('sightings', []))) if result['boxes'] else None
                if result['boxes']:
                    assert state is not None
            assert results[0]['boxes'] and results[0]['boxes'][0]['similarity'] >= .7
            assert not results[1]['boxes'] or max(b['similarity'] for b in results[1]['boxes']) < .7
            # Reconnection changes stream identity even when the sequence starts at zero.
        async with connect(url + '/ws/phone') as phone:
            reconnected = await join(phone, 'replay')
            assert reconnected['streamId'] != welcome['streamId']
            await phone.send(pack(dict(type='frame', seq=0, tCapture=now_ms()), present))
            result = await receive_json(phone, lambda m: m.get('cmd') == 'detections' and m.get('seq') == 0)
            assert result['phoneId'] == 'replay' and result['streamId'] == reconnected['streamId']
            assert result['searchRevision'] == registered.json()['searchRevision']
            assert result['boxes'] and result['boxes'][0]['similarity'] >= .7
            assert 0 <= now_ms() - result['t'] < 1500
        print(dict(acceptedAgeMs=ages, similarities=[[b['similarity'] for b in r['boxes']] for r in results]))


def test_phone_bridge_worker_console_replay(monkeypatch):
    async def run():
        async with server(FakeWorker().app) as url:
            await replay(monkeypatch, url, jpeg(), jpeg(), jpeg('black'), '0,0,100,100')
    asyncio.run(run())


def test_thirty_phones_slow_worker_is_bounded_fair_and_responsive(monkeypatch):
    async def run():
        worker = FakeWorker(.35)
        async with server(worker.app) as worker_url, system(monkeypatch, worker_url) as (hub, bridge, client, bridge_task, url):
            assert (await client.put('/api/search/reference?box=0,0,100,100', content=jpeg())).status_code == 200
            await wait_active(bridge)
            sockets = [await connect(url + '/ws/phone', max_queue=None) for _ in range(30)]
            try:
                welcomes = await asyncio.gather(*(join(ws, f'load-{i}') for i, ws in enumerate(sockets)))
                image = jpeg()
                maximum_pending = 0
                latencies = []
                for seq in range(70):
                    packet = pack(dict(type='frame', seq=seq, tCapture=now_ms()), image)
                    await asyncio.gather(*(ws.send(packet) for ws in sockets))
                    start = time.monotonic()
                    assert (await client.get('/api/search')).status_code == 200
                    latencies.append(time.monotonic() - start)
                    maximum_pending = max(maximum_pending, len(bridge.pending))
                    assert len(bridge.pending) <= 30 and len(bridge.busy) <= 4
                    assert len(bridge.ready) == len(set(bridge.ready))
                    await asyncio.sleep(.1)
                counts = [sum(stream == w['streamId'] for stream, _ in worker.calls) for w in welcomes]
                assert min(counts) >= 1
                assert max(counts) - min(counts) <= 2
                assert worker.maximum <= 4
                assert max(latencies) < .5
                assert max(seq for _, seq in worker.calls) > 40
                assert sum(p.frames_total for p in hub.phones.values()) == 2100
                print(dict(phones=30, frames=2100, modelCalls=len(worker.calls), maxPending=maximum_pending,
                    maxInflight=worker.maximum, fairness=[min(counts), max(counts)],
                    maxHubResponseMs=round(max(latencies)*1000, 2)))
            finally:
                await asyncio.gather(*(ws.close() for ws in sockets))
    asyncio.run(run())


@pytest.mark.skipif(not os.getenv('SWARM_REAL_E2E_URL'), reason='opt-in pretrained worker and local images required')
def test_pretrained_phone_replay(monkeypatch):
    asyncio.run(replay(monkeypatch, os.environ['SWARM_REAL_E2E_URL'],
        Path(os.environ['SWARM_REAL_REFERENCE']).read_bytes(),
        Path(os.environ['SWARM_REAL_PRESENT']).read_bytes(),
        Path(os.environ['SWARM_REAL_ABSENT']).read_bytes(), os.environ['SWARM_REAL_BOX'],
        os.environ['SWARM_REAL_KEY']))


def test_sim_replay_loads_real_images_as_jpeg(tmp_path):
    from swarm.sim import load_replay
    path = tmp_path / 'frame.png'
    Image.new('RGBA', (32, 24), (255, 0, 0, 255)).save(path)
    frames = load_replay([path])
    image = Image.open(io.BytesIO(frames[0]))
    assert image.format == 'JPEG' and image.size == (32, 24)
    assert load_replay([]) == []


def test_idle_paused_bridge_failure_and_reference_recovery(monkeypatch):
    async def run():
        worker = FakeWorker()
        async with AsyncExitStack() as listeners:
            worker_url = await listeners.enter_async_context(server(worker.app))
            await recovery(listeners, worker, worker_url)

    async def recovery(listeners, worker, worker_url):
        async with system(monkeypatch, worker_url) as (hub, bridge, client, task, url):
            async def status(value, timeout=5):
                async with asyncio.timeout(timeout):
                    while True:
                        state = (await client.get('/api/search')).json()
                        if state['status'] == value:
                            return state
                        await asyncio.sleep(.05)
            async def register():
                result = await client.put('/api/search/reference?box=0,0,100,100', content=jpeg())
                assert result.status_code == 200
                return result.json()
            initial = await register()
            hub.phase = 'found'
            await asyncio.sleep(11)
            assert (await client.get('/api/search')).json()['status'] == 'available'
            await listeners.aclose()
            with pytest.raises(httpx.ConnectError):
                await client.get(worker_url + '/v1/targets/active')
            await status('unavailable')
            restarted_url = await listeners.enter_async_context(server(worker.app, httpx.URL(worker_url).port))
            assert restarted_url == worker_url
            await status('available')
            worker.key = 'rotated-key'
            await status('unavailable')
            worker.key = 'test-model-key'
            await status('available')
            worker.version = None
            missing = await status('reference_unavailable')
            assert not missing['referenceAvailable'] and not missing['active']
            await asyncio.sleep(1.2)
            assert (await client.get('/api/search')).json()['status'] == 'reference_unavailable'
            rotated = await register()
            assert rotated['searchRevision'] != initial['searchRevision']
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
            await status('unavailable', timeout=12)
            recovered_task = asyncio.create_task(bridge.run())
            try:
                await status('available')
                assert (await client.delete('/api/search/reference')).status_code == 200
                await asyncio.sleep(1.2)
                assert not (await client.get('/api/search')).json()['referenceAvailable']
            finally:
                recovered_task.cancel()
                with suppress(asyncio.CancelledError):
                    await recovered_task
    asyncio.run(run())
