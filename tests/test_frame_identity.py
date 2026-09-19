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


def test_overlapping_registration_keeps_newest_socket_and_stream():
    async def run():
        entered, release = asyncio.Event(), asyncio.Event()

        class HeldClose(Socket):
            async def close(self):
                entered.set()
                await release.wait()

        hub = module.Hub()
        old, middle, newest = HeldClose(), Socket(), Socket()
        phone = await hub.register({'phoneId': 'phone'}, old)
        pending = asyncio.create_task(hub.register({'phoneId': 'phone'}, middle))
        await entered.wait()
        await hub.register({'phoneId': 'phone'}, newest)
        newest_stream = phone.stream_id
        release.set()
        await pending
        assert phone.ws is newest
        assert phone.stream_id == newest_stream
        assert hub.search.streams['phone'] == newest_stream

    asyncio.run(run())


def test_overlapping_welcome_only_reaches_its_own_connection(monkeypatch):
    async def run():
        entered, release = asyncio.Event(), asyncio.Event()

        class HeldClose(Socket):
            async def close(self):
                entered.set()
                await release.wait()

        class EndpointSocket(Socket):
            def __init__(self):
                self.messages = []
                self.welcomed = asyncio.Event()

            async def accept(self):
                pass

            async def receive_json(self):
                return {'phoneId': 'phone'}

            async def send_json(self, message):
                self.messages.append(message)
                if message['type'] == 'welcome':
                    self.welcomed.set()

            async def receive(self):
                await asyncio.Event().wait()

        hub = module.Hub()
        monkeypatch.setattr(module, 'hub', hub)
        await hub.register({'phoneId': 'phone'}, HeldClose())
        middle, newest = EndpointSocket(), EndpointSocket()
        pending = asyncio.create_task(module.ws_phone(middle))
        await entered.wait()
        current = asyncio.create_task(module.ws_phone(newest))
        await newest.welcomed.wait()
        stream = newest.messages[0]['streamId']
        release.set()
        await asyncio.sleep(0)
        try:
            assert hub.phones['phone'].ws is newest
            assert hub.phones['phone'].stream_id == stream
            assert [message for message in newest.messages if message['type'] == 'welcome'] == [newest.messages[0]]
            assert not middle.messages
        finally:
            pending.cancel()
            current.cancel()
            await asyncio.gather(pending, current, return_exceptions=True)

    asyncio.run(run())
