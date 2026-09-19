import asyncio
import io

from fastapi.testclient import TestClient
from PIL import Image

from swarm import hub as module
from swarm.protocol import pack, unpack


def jpeg(width=48, height=64, orientation=None):
    buf = io.BytesIO()
    image = Image.new('RGB', (width, height))
    exif = image.getexif()
    if orientation:
        exif[274] = orientation
    image.save(buf, format='JPEG', exif=exif)
    return buf.getvalue()


class Socket:
    async def close(self):
        pass


def test_reconnect_resets_identity_and_frame():
    hub = module.Hub()
    old, new = Socket(), Socket()
    phone = asyncio.run(hub.register({'phoneId': 'phone'}, old))
    stream = phone.stream_id
    hub.on_frame(phone, pack({'seq': 0}, jpeg()))
    phone.clock_offset = 100
    asyncio.run(hub.register({'phoneId': 'phone'}, new))
    assert phone.stream_id != stream
    assert phone.frame is None and phone.frame_seq == -1
    assert phone.clock_offset is None
    hub.disconnect(phone, old)
    assert phone.connected
    hub.on_frame(phone, pack({'seq': 0}, jpeg()))
    assert phone.frame_seq == 0


def test_frame_pose_dimensions_and_malformed_frame():
    hub = module.Hub()
    phone = asyncio.run(hub.register({'phoneId': 'phone'}, Socket()))
    phone.external_pose = dict(x=2, y=3, heading=180, confidence=.8, source='external', t=module.now_ms())
    hub.on_frame(phone, pack({'seq': 0, 'heading': 90, 'width': 48, 'height': 64}, jpeg()))
    assert phone.frame_pose['heading'] == 90
    assert phone.frame_pose['x'] == 2
    phone.external_pose['x'] = 9
    phone.heading = 120
    assert phone.frame_pose['x'] == 2
    assert (phone.frame_width, phone.frame_height) == (48, 64)
    for header in ({'seq': 1, 'width': 100, 'height': 64}, {'seq': 'invalid'}, {'seq': 1, 'heading': float('nan')}):
        hub.on_frame(phone, pack(header, jpeg()))
        assert phone.frame_seq == 0
    hub.on_frame(phone, pack({'seq': 1}, jpeg(48, 64, 6)))
    assert (phone.frame_width, phone.frame_height) == (64, 48)


def test_websocket_welcome_and_subscriber_contract(monkeypatch):
    hub = module.Hub()
    monkeypatch.setattr(module, 'hub', hub)
    with TestClient(module.app) as client:
        with client.websocket_connect('/ws/phone') as phone:
            phone.send_json({'phoneId': 'phone'})
            welcome = phone.receive_json()
            assert welcome['streamId']
            phone.send_bytes(pack({'seq': 0, 'width': 48, 'height': 64}, jpeg()))
            with client.websocket_connect('/ws/frames') as frames:
                header, data = unpack(frames.receive_bytes())
                assert header['streamId'] == welcome['streamId']
                assert header['searchRevision'] == hub.search.revision
                assert header['phoneId'] == 'phone' and header['seq'] == 0
                assert header['width'] == 48 and header['height'] == 64
                assert 'pose' in header and 't' in header
                assert data == jpeg()


def test_subscriber_keeps_header_and_jpeg_atomic_while_waiting_for_lock(monkeypatch):
    hub = module.Hub()
    monkeypatch.setattr(module, 'hub', hub)
    phone = asyncio.run(hub.register({'phoneId': 'phone'}, Socket()))
    first = jpeg(48, 64)
    hub.on_frame(phone, pack({'seq': 0}, first))
    sent = []

    class Output:
        async def send_bytes(self, data):
            sent.append(unpack(data))
            raise asyncio.CancelledError

    class BusyLock:
        async def __aenter__(self):
            hub.on_frame(phone, pack({'seq': 1}, jpeg(24, 32)))

        async def __aexit__(self, *args):
            pass

    async def run():
        subscriber = module.FrameSubscriber(Output(), 5, False)
        subscriber.lock = BusyLock()
        try:
            await subscriber.run()
        except asyncio.CancelledError:
            pass

    asyncio.run(run())
    header, data = sent[0]
    assert header['seq'] == 0
    assert data == first
