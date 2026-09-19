import unittest
import numpy as np
from swarm.sections import register, section_batch
from swarm.mapper import place
from swarm.keyframes import VisualSelector, graph, reachable
from tests.test_mapping_capture import texture, jpeg

class SectionsTests(unittest.TestCase):
    def cameras(self):
        return [{'id':f'k{i}', 'position':p} for i,p in enumerate(
            [[0,1,0],[1,1,0],[0,1,1],[1,1,1]])]

    def test_recovers_shared_frame_and_rejects_disagreement(self):
        cameras=self.cameras()
        expected={'scale':2.,'rotateYDeg':32.,'offset':[4.,.2,-3.]}
        placed=place(expected,cameras)
        tf,meta=register(cameras,placed)
        self.assertAlmostEqual(tf['scale'],2.)
        self.assertAlmostEqual(tf['rotateYDeg'],32.)
        self.assertLess(meta['residualM'],.001)
        placed['k3']=[9,1,9]
        with self.assertRaises(ValueError): register(cameras,placed)

    def test_stationary_references_cannot_establish_scale(self):
        cameras=self.cameras()
        with self.assertRaises(ValueError): register(cameras, {c['id']:[0,1,0] for c in cameras})
        with self.assertRaises(ValueError): register(cameras, {'k0':[0,1,0]})

    def test_local_batch_keeps_references_and_new_views(self):
        frames=[{'id':f'k{i}','links':{f'k{j}':.5 for j in range(max(0,i-4),i)},'quality':100} for i in range(30)]
        placed={f'k{i}':[i,1,0] for i in range(20)}
        batch=section_batch(frames,placed,{f'k{i}' for i in range(20,30)})
        ids={k['id'] for k in batch}
        self.assertLessEqual(len(batch),12)
        self.assertGreaterEqual(len(ids & placed.keys()),3)
        self.assertTrue(ids & {f'k{i}' for i in range(20,30)})
        self.assertEqual(len(reachable(graph(batch),batch[0]['id'])),len(batch))

    def test_sharp_corner_cannot_rescue_blurred_frame(self):
        im=np.full((480,640,3),125,np.uint8)
        im[:160,:213]=texture()[:160,:213]
        visual,reason=VisualSelector().describe(jpeg(im))
        self.assertIsNone(visual)

class SectionLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def test_persistence_and_failed_registration_preserve_map(self):
        import tempfile,json,struct
        from pathlib import Path
        from unittest.mock import patch
        from swarm.hub import Hub, ROOM
        from swarm.mapper import Mapper
        with tempfile.TemporaryDirectory() as directory:
            hub=Hub(); mapper=Mapper(hub,ROOM,Path(directory));mapper.url='http://test'
            cameras=SectionsTests().cameras()
            mapper.keyframes=[{'id':c['id'],'pid':'phone','jpeg':jpeg(texture()),
                'links':{f'k{j}':.5 for j in range(i)},'quality':100,'t':i}
                for i,c in enumerate(cameras)]
            mapper.pending={c['id'] for c in cameras}
            def response():
                meta=json.dumps({'cameras':cameras,'medianDepth':1,'frames':len(cameras),
                     'points':10,'totalSeconds':.1}).encode()
                return struct.pack('>I',len(meta))+meta+b'fake-glb'
            with patch('swarm.mapper._post',side_effect=lambda *args:response()):
                await mapper.rebuild()
                anchors=dict(mapper.placed)
                mapper.keyframes.append({'id':'k4','pid':'phone','jpeg':jpeg(texture()),
                    'links':{'k3':.5},'quality':100,'t':4})
                cameras.append({'id':'k4','position':[2,1,1]})
                mapper.pending={'k4'}
                await mapper.rebuild()
                self.assertEqual(len(mapper.sections),2)
                self.assertTrue((Path(directory)/'scan-1.glb').exists())
                self.assertEqual({k:mapper.placed[k] for k in anchors},anchors)
                restored=Mapper(hub,ROOM,Path(directory))
                self.assertEqual(len(restored.sections),2)
                last=mapper.last
                cameras[0]['position']=[100,20,100]
                mapper.pending={'k4'}
                await mapper.rebuild()
                self.assertIs(mapper.last,last)
                self.assertEqual(mapper.pending,{'k4'})
                self.assertIsNotNone(mapper.error)
