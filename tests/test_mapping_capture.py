import tempfile
import unittest
from pathlib import Path

from swarm.hub import Hub, Phone, ROOM
from swarm.mapper import Mapper
from swarm.protocol import now_ms, pack


class MappingCaptureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.hub = Hub()
        self.mapper = self.hub.mapper = Mapper(self.hub, ROOM, Path(self.tmp.name))
        self.mapper.enabled = True
        self.phone = Phone(id='test', index=0)
        self.phone.connected = True
        self.phone.seat = {'x': 1, 'y': 2}
        self.phone.heading = 20
        self.hub.phones['test'] = self.phone

    def test_preview_does_not_replace_scan_capture_pose(self):
        self.hub.on_frame(self.phone, pack({'type': 'frame', 'scanKeyframe': True, 'heading': 20}, b'sharp'))
        self.phone.seat = {'x': 4, 'y': 5}
        self.hub.on_frame(self.phone, pack({'type': 'frame', 'heading': 80}, b'preview'))
        self.mapper.sample()
        frame = self.mapper.keyframes[0]
        self.assertEqual(frame['jpeg'], b'sharp')
        self.assertEqual((frame['x'], frame['y'], frame['heading']), (1, 2, 20))

    def test_stale_scan_capture_is_not_reused(self):
        self.hub.on_frame(self.phone, pack({'type': 'frame', 'scanKeyframe': True, 'heading': 20}, b'sharp'))
        self.phone.scan_frame['at'] = now_ms() - 2000
        self.mapper.sample()
        self.assertEqual(self.mapper.keyframes, [])

    def test_legacy_phone_still_supplies_frames(self):
        self.hub.on_frame(self.phone, pack({'type': 'frame', 'heading': 20}, b'legacy'))
        self.mapper.sample()
        self.assertEqual(self.mapper.keyframes[0]['jpeg'], b'legacy')

    def test_redundancy_eviction_preserves_reference_view(self):
        self.mapper.keyframes = [dict(id=f'k{i}', x=i*.01, y=0, heading=0, t=i) for i in range(33)]
        self.mapper._drop_most_redundant()
        self.assertEqual(self.mapper.keyframes[0]['id'], 'k0')
        self.assertEqual(len(self.mapper.keyframes), 32)


if __name__ == '__main__':
    unittest.main()
