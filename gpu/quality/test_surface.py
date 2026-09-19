"""Geometric regression tests; run with the GPU worker's Python (CUDA is not required)."""
import io
import json
import struct
import sys
import unittest
from pathlib import Path

import numpy as np
import trimesh
import DracoPy

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from surface import backproject, build_surface, level_scene, rotation_to_up, srgb_to_linear, supported_depth
from mesh_glb import export_mesh


class SurfaceTests(unittest.TestCase):
    def fixture(self):
        depth = np.full((2, 64, 64), 2, dtype=np.float32)
        intrinsics = np.repeat(np.array([[[60., 0, 31.5], [0, 60., 31.5], [0, 0, 1]]]), 2, axis=0)
        extrinsics = np.repeat(np.eye(4)[None, :3], 2, axis=0)
        return depth, np.ones_like(depth), intrinsics, extrinsics

    def test_backprojection_preserves_world_to_camera_convention(self):
        d, _, k, e = self.fixture()
        e[:, 0, 3] = .3
        p = backproject(d, k, e)
        q = p + e[:, None, None, :3, 3]
        np.testing.assert_allclose(q[..., 2], d)
        np.testing.assert_allclose(q[..., 0] / q[..., 2] * 60 + 31.5,
                                   np.broadcast_to(np.arange(64), d.shape), atol=1e-5)

    def test_unsupported_depths_rejected(self):
        d, c, k, e = self.fixture()
        good, _ = supported_depth(d, c, k, e)
        self.assertGreater(np.count_nonzero(good), 7000)
        d[1] *= 1.5
        bad, _ = supported_depth(d, c, k, e)
        self.assertEqual(np.count_nonzero(bad), 0)

    def test_depth_edges_do_not_bridge_foreground_to_background(self):
        d, c, k, e = self.fixture()
        d[:, :, 32:] = 4
        filtered, _ = supported_depth(d, c, k, e)
        self.assertEqual(np.count_nonzero(filtered[:, :, 31:33]), 0)
        meta, glb = build_surface(d, c, np.full((*d.shape, 3), .5), e, k, ['a', 'b'])
        scene = trimesh.load(io.BytesIO(glb), file_type='glb')
        mesh = next(iter(scene.geometry.values()))
        self.assertLess(mesh.edges_unique_length.max(), .2)
        self.assertGreater(meta['faces'], 100)
        self.assertTrue(np.isfinite(mesh.vertices).all())
        self.assertEqual(len(meta['cameras']), 2)

    def test_up_rotations_include_antiparallel_case(self):
        for up in ([0, 1, 0], [0, -1, 0], [1, 2, 3]):
            normalized = np.array(up) / np.linalg.norm(up)
            r = rotation_to_up(up)
            np.testing.assert_allclose(r @ normalized, [0, 1, 0], atol=1e-6)
            np.testing.assert_allclose(r @ r.T, np.eye(3), atol=1e-6)

    def test_floor_selection_ignores_higher_table(self):
        rng = np.random.default_rng(42)
        floor = rng.uniform(-2, 2, (12000, 3)); floor[:, 1] = 0
        table = rng.uniform(-.8, .8, (15000, 3)); table[:, 1] = .75
        wall = rng.uniform(-2, 2, (10000, 3)); wall[:, 2] = -2; wall[:, 1] = np.abs(wall[:, 1])
        points = np.concatenate([floor, table, wall])
        e = np.array([[[1., 0, 0, 0], [0, -1, 0, 1.5], [0, 0, -1, 0]]]*2)
        r, center, method, floor_by = level_scene(points, e, None, 2)
        self.assertEqual(floor_by, 'plane')
        self.assertAlmostEqual(center[1], 0, places=2)
        np.testing.assert_allclose(r, np.eye(3), atol=.01)

    def test_gltf_color_is_linear(self):
        np.testing.assert_allclose(srgb_to_linear(np.array([0, .5, 1])), [0, .21404114, 1], atol=1e-6)

    def test_compressed_glb_preserves_geometry_and_color_mapping(self):
        vertices = np.array([[0., 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]])
        faces = np.array([[0, 1, 2], [0, 1, 3]])
        colors = np.array([[0, 0, 0], [255, 0, 0], [0, 128, 0], [0, 0, 64]], dtype=np.uint8)
        glb = export_mesh(vertices, faces, colors)
        self.assertEqual(struct.unpack_from('<I', glb, 8)[0], len(glb))
        length = struct.unpack_from('<I', glb, 12)[0]
        document = json.loads(glb[20:20+length])
        decoded = DracoPy.decode(glb[28+length:28+length+document['buffers'][0]['byteLength']])
        self.assertEqual(len(decoded.faces), len(faces))
        for i, p in enumerate(decoded.points):
            j = np.argmin(np.linalg.norm(vertices - p, axis=1))
            self.assertLess(np.linalg.norm(vertices[j] - p), .0001)
            np.testing.assert_array_equal(colors[j], decoded.colors[i])
        ids = document['meshes'][0]['primitives'][0]['extensions']['KHR_draco_mesh_compression']['attributes']
        self.assertEqual(ids['POSITION'], decoded.get_attribute_by_type(DracoPy.AttributeType.POSITION)['unique_id'])
        self.assertEqual(ids['COLOR_0'], decoded.get_attribute_by_type(DracoPy.AttributeType.COLOR)['unique_id'])


if __name__ == '__main__':
    unittest.main()
