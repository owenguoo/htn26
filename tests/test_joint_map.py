import json
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from swarm.hub import Hub, ROOM
from swarm.mapper import Mapper
from swarm.keyframes import working_batch, graph, reachable
from tests.test_mapping_capture import jpeg, texture


class JointMapTests(unittest.IsolatedAsyncioTestCase):
    def test_bounded_connected_batch_keeps_old_and_new_views(self):
        frames = [{'id': f'k{i}', 'pid': str(i % 2), 'quality': 100, 't': i,
                   'links': {f'k{j}': .5 for j in range(max(0, i-6), i)}} for i in range(40)]
        batch = working_batch(frames, [f'k{i}' for i in range(12)], {f'k{i}' for i in range(32,40)}, 24)
        ids = {k['id'] for k in batch}
        self.assertLessEqual(len(batch), 24)
        self.assertIn('k0', ids)
        self.assertTrue(ids & {f'k{i}' for i in range(32,40)})
        self.assertEqual(reachable(graph(batch), batch[0]['id']), ids)

    def test_joint_updates_keep_twenty_shared_views(self):
        frames = [{'id':f'k{i}', 'pid':'p', 't':i, 'quality':100,
                   'links':{f'k{j}':.5 for j in range(i)}} for i in range(32)]
        old = [f'k{i}' for i in range(24)]
        batch = working_batch(frames, old, {f'k{i}' for i in range(24,32)}, 24, stable=True)
        ids = {k['id'] for k in batch}
        self.assertEqual(len(ids), 24)
        self.assertGreaterEqual(len(ids & set(old)), 20)
        self.assertTrue(ids - set(old))

    def test_joint_alignment_requires_majority_consensus(self):
        from swarm.sections import register_joint
        cameras = [{'id':str(i), 'position':[i%4, 1, i//4]} for i in range(12)]
        placed = {c['id']:list(c['position']) for c in cameras}
        placed['11'] = [100, 20, 100]
        tf, meta = register_joint(cameras, placed)
        self.assertAlmostEqual(tf['scale'], 1)
        self.assertEqual(meta['rejectedViews'], 1)
        for i in range(6): placed[str(i)] = [i*13, i*7, i*i]
        with self.assertRaises(ValueError): register_joint(cameras, placed)

    async def test_replaces_map_preserves_files_and_holds_failed_update(self):
        with tempfile.TemporaryDirectory() as directory:
            hub = Hub(); hub.phase = 'search'
            mapper = Mapper(hub, ROOM, Path(directory)); mapper.mode = 'joint'; mapper.url = 'http://test'
            mapper.keyframes = [{'id':f'k{i}', 'pid':'p', 'jpeg':jpeg(texture()), 't':i,
                                 'quality':100, 'links':{f'k{j}':.5 for j in range(i)}} for i in range(8)]
            mapper.pending = {k['id'] for k in mapper.keyframes}
            def response(url, body):
                size = struct.unpack('>I',body[:4])[0]; request = json.loads(body[4:4+size])
                cameras = [{'id':k['id'], 'position':[int(k['id'][1:])%3,1,int(k['id'][1:])//3]} for i,k in enumerate(request['frames'])]
                meta = json.dumps({'cameras':cameras,'frames':len(cameras),'medianDepth':1,'points':100}).encode()
                return struct.pack('>I',len(meta))+meta+b'glTF-test'
            with patch('swarm.mapper._post', side_effect=response):
                await mapper.rebuild()
                original = mapper.last['url']
                await mapper.rebuild()
            self.assertEqual(len(mapper.sections), 1)
            self.assertNotEqual(mapper.last['url'], original)
            self.assertTrue((Path(directory)/Path(original).name).exists())
            self.assertEqual(mapper.last['mode'], 'joint')
            self.assertIsNone(mapper.consolidated)
            restored = Mapper(hub, ROOM, Path(directory))
            self.assertEqual(restored.sections, mapper.sections)
            previous = mapper.last
            mapper.pending = {'k7'}
            with patch('swarm.mapper._post', side_effect=RuntimeError('worker unavailable')):
                await mapper.rebuild()
            self.assertIs(mapper.last, previous)
            self.assertEqual(mapper.pending, {'k7'})
