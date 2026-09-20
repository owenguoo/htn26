import asyncio
import json

import httpx

from swarm.detection import FrameSnapshot, SearchState
from swarm.hazards import ObjectDetection, HazardResult, Hazards, floor_position
from swarm.hub import ROOM
from swarm.inference import Bridge
from swarm.control import Settings
from swarm.protocol import now_ms, pack


def chair(box=(200., 200., 400., 600.)):
    return ObjectDetection(label='chair', score=.9, box=box)


def pose():
    return dict(x=0., y=8., heading=0., pitch=0., calibrated=True, source='slam')


def test_floor_projection_and_unplaceable_views():
    assert floor_position(ObjectDetection(label='person', score=.9, box=(200., 200., 400., 600.)),
                          pose(), 600, 800, ROOM) is not None
    point = floor_position(chair(), pose(), 600, 800, ROOM)
    assert point and abs(point[0]) < .001 and 3 < point[1] < 5
    assert floor_position(chair(), pose() | {'heading': 90.}, 600, 800, ROOM)[0] > 0
    for p in [None, pose() | {'calibrated': False}, pose() | {'pitch': 70.}]:
        assert floor_position(chair(), p, 600, 800, ROOM) is None
    assert floor_position(chair((200., 200., 400., 800.)), pose(), 600, 800, ROOM) is None
    assert floor_position(chair((200., 200., 400., 410.)), pose(), 600, 800, ROOM) is None


def test_confirmation_freshness_identity_and_revision():
    search = SearchState()
    search.connect('phone', 'stream')
    hazards = Hazards()
    def result(seq, t):
        search.record_frame(FrameSnapshot('phone', 'stream', seq, t, 600, 800, pose()))
        return HazardResult(phoneId='phone', streamId='stream', seq=seq, t=t, width=600, height=800,
                            searchRevision=search.revision, detections=[chair()])
    first = result(1, 1000.)
    assert hazards.accept(first, search, ROOM, 1100.)
    assert not hazards.snapshot(1100., search.revision)
    assert not hazards.accept(first, search, ROOM, 1100.)
    second = result(2, 2000.)
    assert not hazards.accept(second.model_copy(update={'streamId': 'old'}), search, ROOM, 2100.)
    assert hazards.accept(second, search, ROOM, 2100.)
    assert len(hazards.snapshot(2100., search.revision)) == 1
    assert not hazards.accept(result(3, 3000.), search, ROOM, 5000.)
    assert len(hazards.snapshot(18001., search.revision)) == 1
    assert hazards.accept(result(4, 19000.), search, ROOM, 19100.)
    assert hazards.accept(result(5, 20000.), search, ROOM, 20100.)
    search.reset()
    assert len(hazards.snapshot(20200., search.revision)) == 1
    hazards.reset()
    assert not hazards.snapshot(20200., search.revision)


def test_chairs_run_without_reference_and_keep_worker_identity():
    async def run():
        timestamp = now_ms()
        calls = []
        async def boundary(request):
            calls.append(request.url.path)
            if request.url.path == '/v1/detect':
                assert request.url.params.get_list('labels') == ['chair', 'person']
                return httpx.Response(200, json=dict(phone_id='stream', frame_id='1', captured_at=timestamp / 1000,
                    width=600, height=800, detections=[chair().model_dump(), ObjectDetection(label='person', score=.8, box=(10., 20., 100., 200.)).model_dump()]))
            body = json.loads(request.content)
            assert body['streamId'] == 'stream'
            assert [d['label'] for d in body['detections']] == ['chair', 'person']
            return httpx.Response(200, json={'ok': True})
        async with httpx.AsyncClient(transport=httpx.MockTransport(boundary)) as client:
            bridge = Bridge(Settings(inference_url='https://worker.test', hub_url='https://hub.test'), client)
            bridge.state = dict(active=False, hazardsActive=True, searchRevision='r')
            header = dict(phoneId='phone', streamId='stream', seq=1, t=timestamp, width=600, height=800, searchRevision='r')
            bridge.offer(pack(header, b'jpeg'))
            assert bridge.take() is not None
            await bridge.process(header, b'jpeg')
            assert calls == ['/v1/detect', '/api/hazards']
    asyncio.run(run())


def test_hazard_api_authentication_and_map_snapshot(monkeypatch):
    from fastapi.testclient import TestClient
    from swarm import hub as module
    from swarm.control import Auth
    hub = module.Hub()
    hub.phase = 'search'
    hub.search.connect('phone', 'stream')
    monkeypatch.setattr(module, 'hub', hub)
    monkeypatch.setattr(module, 'auth', Auth(Settings(bridge_key='test-key')))
    delivered = []
    class Socket:
        async def send_json(self, message):
            delivered.append(message)
    phone = module.Phone('phone', 1)
    phone.ws = Socket()
    hub.phones['phone'] = phone
    client = TestClient(module.app)
    for seq in (1, 2):
        timestamp = now_ms()
        hub.search.record_frame(FrameSnapshot('phone', 'stream', seq, timestamp, 600, 800, pose()))
        payload = dict(phoneId='phone', streamId='stream', seq=seq, t=timestamp, width=600, height=800,
                       searchRevision=hub.search.revision, detections=[chair().model_dump(),
                           ObjectDetection(label='person', score=.9, box=chair().box).model_dump()])
        assert client.post('/api/hazards', json=payload).status_code == 401
        assert client.post('/api/hazards', json=payload,
                           headers={'Authorization': 'Bearer test-key'}).status_code == 200
    hazards = client.get('/api/state').json()['hazards']
    assert len(hazards) == 1 and hazards[0]['label'] == 'chair' and hazards[0]['approximate']

    assert delivered[-1]['cmd'] == 'hazard_detections'
    assert delivered[-1]['boxes'][0]['label'] == 'Hazard'
    assert delivered[-1]['boxes'][0]['x'] == 200 / 600
    assert delivered[-1]['seq'] == 2

    people = client.get('/api/state').json()['detectedPeople']
    assert len(people) == 1 and people[0]['label'] == 'person'
    assert delivered[-1]['boxes'][1]['label'] == 'Person'
    asyncio.run(hub.set_phase('end'))
    assert len(client.get('/api/state').json()['hazards']) == 1
    assert len(client.get('/api/state').json()['detectedPeople']) == 1
    asyncio.run(hub.set_phase('calibrate', restart=True))
    assert not client.get('/api/state').json()['hazards']
    assert not client.get('/api/state').json()['detectedPeople']


def test_phone_world_publishes_persistent_hazards_and_clears_after_reset():
    from contextlib import suppress
    from swarm.hub import Hub, Phone
    async def run():
        hub = Hub()
        messages = asyncio.Queue()
        class Socket:
            async def send_json(self, message):
                await messages.put(message)
        phone = Phone('phone', 1)
        phone.connected = True
        phone.ws = Socket()
        hub.phones[phone.id] = phone
        hub.hazards.observations['h'] = dict(id='h', label='chair', x=1., y=2., hits=2, t=now_ms() - 20000)
        hub.hazards.observations['p'] = dict(id='p', label='person', x=3., y=4., hits=2, t=now_ms())
        hub.search.mode = 'real'
        hub.search.map_sighting = dict(x=2., y=-1., t=now_ms())
        task = asyncio.create_task(hub.world_loop())
        try:
            world = await asyncio.wait_for(messages.get(), 2)
            assert world['hazards'] == [dict(id='h', x=1., y=2., stale=True)]
            assert world['detectedPeople'] == [dict(id='p', x=3., y=4., stale=False)]
            assert world['candidate'] == dict(x=2., y=-1., possible=True)
            hub.hazards.reset()
            world = await asyncio.wait_for(messages.get(), 2)
            assert world['hazards'] == []
        finally:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
    asyncio.run(run())


def test_live_chair_outside_nominal_room_still_has_a_position():
    detection = chair((277.12, 395.51, 554.54, 761.39))
    camera = pose() | dict(x=-2.292, y=1.08, heading=42.61, pitch=-2.834)
    point = floor_position(detection, camera, 720, 960, ROOM)
    assert point is not None
    assert -3 < point[1] < 0
    search = SearchState()
    search.connect('phone', 'stream')
    hazards = Hazards()
    for seq in (1, 2):
        t = seq * 500.
        search.record_frame(FrameSnapshot('phone', 'stream', seq, t, 720, 960, camera))
        result = HazardResult(phoneId='phone', streamId='stream', seq=seq, t=t,
                              width=720, height=960, searchRevision=search.revision, detections=[detection])
        assert hazards.accept(result, search, ROOM, t + 100)
    assert len(hazards.snapshot(1100, search.revision)) == 1
