import asyncio
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import cv2
import numpy as np

from swarm.hub import Hub, Phone, ROOM
from swarm.keyframes import VisualSelector, working_batch, graph, reachable, trim_archive
from swarm.mapper import Mapper, align
from swarm.protocol import now_ms, pack


def texture(seed=2):
    rng = np.random.default_rng(seed)
    image = np.full((480, 640, 3), 125, np.uint8)
    for _ in range(600):
        x, y = rng.integers([0, 0], [640, 480])
        cv2.circle(image, (int(x), int(y)), int(rng.integers(2, 12)),
                   tuple(map(int, rng.integers(0, 255, 3))), -1)
    return image


def jpeg(image):
    return cv2.imencode('.jpg', image)[1].tobytes()


def view(image, shift):
    return jpeg(cv2.warpAffine(image, np.float32([[1, 0, shift], [0, 1, 0]]), (640, 480)))


def frame(i, pid='a', links=None):
    return dict(id=f'k{i}', pid=pid, links=links or {}, quality=100, t=i)


class VisualTests(unittest.TestCase):
    def test_quality_overlap_and_duplicates(self):
        selector = VisualSelector()
        a, _ = selector.describe(jpeg(texture()))
        b, _ = selector.describe(view(texture(), 50))
        other, _ = selector.describe(jpeg(texture(10)))
        self.assertTrue(selector.compare(a, a)[1])
        strength, duplicate = selector.compare(a, b)
        self.assertGreater(strength, 0)
        self.assertFalse(duplicate)
        self.assertEqual(selector.compare(a, other)[0], 0)
        self.assertIsNone(selector.describe(b'not a jpeg')[0])
        self.assertIsNone(selector.describe(jpeg(np.zeros((480, 640, 3), np.uint8)))[0])
        self.assertIsNone(selector.describe(jpeg(cv2.GaussianBlur(texture(), (41, 41), 10)))[0])

    def test_sharpest_eligible_view_and_cross_phone_connection(self):
        selector = VisualSelector()
        root = frame(0) | {'jpeg': jpeg(texture())}
        archive, _, _ = selector.choose({'a': [root]}, [], set())
        blurred = frame(1, 'b') | {'jpeg': jpeg(cv2.GaussianBlur(texture(), (41, 41), 10))}
        sharp = frame(2, 'b') | {'jpeg': view(texture(), 45)}
        archive, added, _ = selector.choose({'b': [blurred, sharp]}, archive, set())
        self.assertEqual([k['id'] for k in added], ['k2'])
        self.assertIn('k0', added[0]['links'])
        _, added, hints = selector.choose({'c': [frame(3, 'c') | {'jpeg': jpeg(texture(11))}]}, archive, set())
        self.assertEqual(added, [])
        self.assertIn('mapped area', hints['c'])

    def test_batch_is_connected_bounded_and_balanced(self):
        frames = [frame(0)] + [frame(i, 'a' if i < 40 else 'b', {'k0': .4}) for i in range(1, 60)]
        previous = [f'k{i}' for i in range(16)]
        batch = working_batch(frames, previous, {f'k{i}' for i in range(40, 60)})
        self.assertEqual(len(batch), 32)
        self.assertEqual(batch[0]['id'], 'k0')
        self.assertEqual(len(reachable(graph(batch), 'k0')), 32)
        self.assertGreaterEqual(len(set(previous) & {k['id'] for k in batch}), 6)
        self.assertGreaterEqual(sum(k['pid'] == 'b' for k in batch), 10)
        self.assertTrue(any(k['id'] in {f'k{i}' for i in range(16, 40)} for k in batch))

    def test_bridge_views_survive_selection_and_archive_eviction(self):
        frames = [frame(0), frame(1, links={'k0': .4})]
        frames += [frame(i, 'b', {'k1': .5}) for i in range(2, 110)]
        kept = trim_archive(frames, {'k0', 'k1', 'k109'})
        self.assertEqual(len(kept), 96)
        self.assertEqual(len(reachable(graph(kept), 'k0')), 96)
        batch = working_batch(kept, ['k0', 'k1'], ['k109'])
        self.assertIn('k109', {k['id'] for k in batch})
        self.assertIn('k1', {k['id'] for k in batch})
        self.assertEqual(len(reachable(graph(batch), 'k0')), len(batch))


class MappingCaptureTests(unittest.IsolatedAsyncioTestCase):
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
        self.image = jpeg(texture())

    def send_scan(self, image=None):
        self.hub.on_frame(self.phone, pack({'type': 'frame', 'scanKeyframe': True, 'heading': 20}, image or self.image))
        self.phone.scan_frame['at'] -= 1200

    async def test_preview_does_not_replace_scan_capture_pose(self):
        self.send_scan()
        self.phone.seat = {'x': 4, 'y': 5}
        self.hub.on_frame(self.phone, pack({'type': 'frame', 'heading': 80}, b'preview'))
        await self.mapper.sample()
        f = self.mapper.keyframes[0]
        self.assertEqual(f['jpeg'], self.image)
        self.assertEqual((f['x'], f['y'], f['heading']), (1, 2, 20))

    async def test_missing_pose_does_not_block_capture(self):
        self.phone.seat = None
        self.phone.heading = None
        self.send_scan()
        await self.mapper.sample()
        self.assertEqual(len(self.mapper.keyframes), 1)
        self.assertIsNone(self.mapper.keyframes[0]['x'])
        tf, meta = align([{'id': 'k1', 'position': [0, .5, 0], 'forward': [0, 0, -1]}],
                         {'k1': self.mapper.keyframes[0]})
        self.assertGreater(tf['scale'], 0)
        self.assertIn('not registered', meta['method'])

    async def test_stale_scan_capture_is_not_reused(self):
        self.send_scan()
        self.phone.scan_frame['at'] = now_ms() - 3000
        await self.mapper.sample()
        self.assertEqual(self.mapper.keyframes, [])

    async def test_legacy_phone_still_supplies_frames(self):
        self.hub.on_frame(self.phone, pack({'type': 'frame', 'heading': 20}, self.image))
        await self.mapper.sample()
        self.assertEqual(self.mapper.keyframes[0]['jpeg'], self.image)

    async def test_candidates_bounded_and_sharp_frame_wins(self):
        for _ in range(10):
            self.send_scan()
        self.assertEqual(len(self.phone.scan_candidates), 4)
        self.send_scan(jpeg(cv2.GaussianBlur(texture(), (41, 41), 10)))
        await self.mapper.sample()
        self.assertEqual(self.mapper.keyframes[0]['jpeg'], self.image)
        self.assertEqual(len(self.phone.scan_candidates), 0)

    async def test_reset_during_selection_discards_old_result(self):
        self.send_scan()
        original = self.mapper.selector.choose
        def choose(*args):
            self.mapper.generation += 1
            return original(*args)
        with patch.object(self.mapper.selector, 'choose', choose):
            await self.mapper.sample()
        self.assertEqual(self.mapper.keyframes, [])

    async def test_archive_roundtrip_excludes_feature_arrays(self):
        self.send_scan()
        await self.mapper.sample()
        self.mapper._save()
        saved = json.loads((Path(self.tmp.name) / 'last.json').read_text())
        self.assertNotIn('_visual', saved['keyframes'][0])
        restored = Mapper(self.hub, ROOM, Path(self.tmp.name))
        self.assertEqual(len(restored.keyframes), 1)
        self.assertEqual(restored.pending, self.mapper.pending)

    def test_small_updates_flush_and_failures_back_off(self):
        self.mapper.keyframes = [frame(i) for i in range(6)]
        self.mapper.pending = {'k5'}
        self.mapper.pending_since = 100000
        self.assertFalse(self.mapper.ready_to_rebuild(105000))
        self.assertTrue(self.mapper.ready_to_rebuild(110001))
        self.mapper.last_attempt = 110001
        self.assertFalse(self.mapper.ready_to_rebuild(110002))
        self.mapper.running = True
        self.assertFalse(self.mapper.ready_to_rebuild(140000))

    async def test_failed_worker_retains_pending_and_current_map(self):
        self.mapper.keyframes = [frame(0) | {'jpeg': self.image}, frame(1, links={'k0': .5}) | {'jpeg': self.image}]
        self.mapper.pending = {'k0', 'k1'}
        self.mapper.last = {'version': 99}
        self.mapper.url = 'http://example.invalid'
        with patch('swarm.mapper._post', side_effect=RuntimeError('worker offline')):
            await self.mapper.rebuild()
        self.assertFalse(self.mapper.running)
        self.assertEqual(self.mapper.pending, {'k0', 'k1'})
        self.assertEqual(self.mapper.last['version'], 99)


if __name__ == '__main__':
    unittest.main()
