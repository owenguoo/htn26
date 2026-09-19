"""Fuse VGGT depth predictions into observed surfaces, without filling unseen space.

All distances are relative to the model's median depth: monocular output has no metric scale.
This module also runs on saved predictions, independently of CUDA/model loading.
"""
from __future__ import annotations

import time

import cv2
import numpy as np
import open3d as o3d
from mesh_glb import export_mesh


def srgb_to_linear(colors):
    c = np.clip(colors, 0, 1)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def backproject(depth, intrinsic, extrinsic):
    n, h, w = depth.shape
    yy, xx = np.mgrid[:h, :w]
    cam = np.stack(((xx - intrinsic[:, 0, 2, None, None]) / intrinsic[:, 0, 0, None, None] * depth,
                    (yy - intrinsic[:, 1, 2, None, None]) / intrinsic[:, 1, 1, None, None] * depth, depth), -1)
    return np.einsum('sji,shwj->shwi', extrinsic[:, :3, :3], cam - extrinsic[:, None, None, :3, 3])


def supported_depth(depth, confidence, intrinsic, extrinsic, neighbors=6, tolerance=.035):
    """Retain depths corroborated by another camera; depth edges never become stretched faces."""
    n, h, w = depth.shape
    confidence = confidence.reshape(depth.shape)
    valid = np.isfinite(depth) & (depth > 0) & np.isfinite(confidence)
    if not valid.any():
        raise ValueError('no finite depth predictions')
    # A global median cut removed entire low-texture walls. Use a gentle per-view cut,
    # then require geometric evidence from another view rather than confidence alone.
    for i in range(n):
        if not valid[i].any():
            continue
        valid[i] &= confidence[i] >= np.percentile(confidence[i][valid[i]], 10)
        d = np.where(np.isfinite(depth[i]), depth[i], 0).astype(np.float32)
        span = cv2.dilate(d, np.ones((3, 3), np.uint8)) - cv2.erode(d, np.ones((3, 3), np.uint8))
        valid[i] &= span < np.maximum(d, 1e-6) * .08
    world = backproject(depth, intrinsic, extrinsic)
    valid &= np.isfinite(world).all(axis=-1)
    out = np.zeros_like(depth, dtype=np.float32)
    def project(xyz, j):
        q = xyz @ extrinsic[j, :3, :3].T + extrinsic[j, :3, 3]
        z = q[:, 2]
        uv = q @ intrinsic[j].T
        denom = np.maximum(z, 1e-8)
        x = np.rint(uv[:, 0] / denom).clip(-1, w).astype(np.int32)
        y = np.rint(uv[:, 1] / denom).clip(-1, h).astype(np.int32)
        k = np.flatnonzero((z > 0) & (x >= 0) & (x < w) & (y >= 0) & (y < h))
        observed = depth[j, y[k], x[k]]
        agree = valid[j, y[k], x[k]] & (np.abs(observed - z[k]) < tolerance * z[k])
        return k[agree]
    for i in range(n):
        idx = np.flatnonzero(valid[i])
        xyz = world[i].reshape(-1, 3)[idx]
        votes = np.zeros(len(xyz), np.uint8)
        # Nearby phones may face opposite walls. Rank actual overlap on a sparse
        # probe, then do dense consistency checks only against the best six views.
        probe = xyz[::max(1, len(xyz) // 1000)]
        order = sorted((j for j in range(n) if j != i), key=lambda j: len(project(probe, j)), reverse=True)
        for j in order[:neighbors]:
            votes[project(xyz, j)] += 1
        keep = idx[votes >= 1]
        out[i].flat[keep] = depth[i].flat[keep]
    return out, {'inputPixels': int(depth.size), 'supportedPixels': int(np.count_nonzero(out))}


def rotation_to_up(up):
    up = np.asarray(up, dtype=float)
    up /= max(np.linalg.norm(up), 1e-8)
    target = np.array([0., 1., 0.])
    v, c = np.cross(up, target), np.clip(up @ target, -1, 1)
    if c < -.9999:
        return np.diag([1., -1., -1.])
    skew = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + skew + skew @ skew / max(1 + c, 1e-8)


def level_scene(vertices, extrinsic, ups, unit):
    rotation = extrinsic[:, :3, :3]
    positions = -np.einsum('sji,sj->si', rotation, extrinsic[:, :3, 3])
    grav = [rotation[i].T @ np.asarray(u, float) for i, u in enumerate(ups or [])
            if i < len(rotation) and u is not None and np.isfinite(u).all() and np.linalg.norm(u) > .1]
    if len(grav) >= max(2, len(rotation) // 2):
        up = np.median([g / np.linalg.norm(g) for g in grav], axis=0)
        method = 'gravity'
    else:
        up, method = -np.median(rotation[:, 1, :], axis=0), 'camera-up'
    up /= max(np.linalg.norm(up), 1e-8)
    # Search several broad planes; a wall often has more support than the floor.
    rng = np.random.default_rng(0)
    sample = vertices[rng.choice(len(vertices), min(30000, len(vertices)), replace=False)]
    cloud = o3d.geometry.PointCloud(o3d.utility.Vector3dVector(sample))
    o3d.utility.random.seed(0)
    low, high = np.percentile(sample @ up, [5, 95])
    floor_point = None
    for _ in range(6):
        if len(cloud.points) < 1000:
            break
        plane, inliers = cloud.segment_plane(distance_threshold=unit * .012, ransac_n=3, num_iterations=300)
        p = np.asarray(cloud.points)[inliers]
        normal = np.asarray(plane[:3])
        if normal @ up < 0:
            normal = -normal
        height = np.median(p @ up)
        # Low, broad, below the cameras, and plausibly horizontal. Prefer the low
        # plane over a larger tabletop. This remains a heuristic, not semantic floor detection.
        horizontal = normal @ up > np.cos(np.deg2rad(12 if method == 'gravity' else 40))
        broad = len(p) > len(sample) * .045
        low_enough = height < low + .18 * (high - low)
        below_cameras = np.median((positions - np.median(p, axis=0)) @ normal) > unit * .12
        if horizontal and broad and low_enough and below_cameras:
            floor_point = np.median(p, axis=0)
            if method != 'gravity':
                up, method = normal, 'floor-plane'
            break
        cloud = cloud.select_by_index(inliers, invert=True)
    # Fix yaw to the retained first camera. A shortest-arc up rotation alone becomes
    # unstable when camera-up is nearly -Y: tiny floor normal changes can spin the map.
    forward = rotation[0, 2] - up * (rotation[0, 2] @ up)
    if np.linalg.norm(forward) > .1:
        forward /= np.linalg.norm(forward)
        level = np.stack([np.cross(forward, up), up, -forward])
    else:
        level = rotation_to_up(up)
    leveled = vertices @ level.T
    center = np.median(leveled, axis=0)
    center[1] = (floor_point @ level.T)[1] if floor_point is not None else np.percentile(leveled[:, 1], 2)
    return level, center, method, 'plane' if floor_point is not None else 'lower-bound-estimate'


def build_surface(depth, confidence, rgb, extrinsic, intrinsic, ids, ups=None, max_faces=300000, voxel_resolution=128):
    t0 = time.monotonic()
    depth = np.asarray(depth, dtype=np.float32)
    unit = float(np.median(depth[np.isfinite(depth) & (depth > 0)]))
    filtered, quality = supported_depth(depth, confidence, intrinsic, extrinsic)
    t_filter = time.monotonic()
    if np.count_nonzero(filtered) < 1000:
        raise ValueError('too little overlapping geometry: capture sharper views with more overlap')
    voxel = unit / voxel_resolution
    volume = o3d.pipelines.integration.ScalableTSDFVolume(
        voxel_length=voxel, sdf_trunc=voxel * 4,
        color_type=o3d.pipelines.integration.TSDFVolumeColorType.RGB8,
        depth_sampling_stride=2)
    n, h, w = depth.shape
    for i in range(n):
        color = o3d.geometry.Image(np.ascontiguousarray(np.clip(rgb[i] * 255, 0, 255).astype(np.uint8)))
        d = o3d.geometry.Image(np.ascontiguousarray(filtered[i]))
        rgbd = o3d.geometry.RGBDImage.create_from_color_and_depth(
            color, d, depth_scale=1, depth_trunc=unit * 8, convert_rgb_to_intensity=False)
        k = intrinsic[i]
        pinhole = o3d.camera.PinholeCameraIntrinsic(w, h, k[0, 0], k[1, 1], k[0, 2], k[1, 2])
        ext = np.eye(4)
        ext[:3] = extrinsic[i, :3]
        volume.integrate(rgbd, pinhole, ext)
    t_integrate = time.monotonic()
    mesh = volume.extract_triangle_mesh()
    if len(mesh.triangles) < 100:
        raise ValueError('insufficient surface coverage')
    labels, counts, areas = mesh.cluster_connected_triangles()
    # Discard tiny disconnected specks, retaining furniture and separated wall/floor patches.
    remove = (np.asarray(counts)[np.asarray(labels)] < 80) & (np.asarray(areas)[np.asarray(labels)] < unit ** 2 * .01)
    mesh.remove_triangles_by_mask(remove)
    mesh.remove_unreferenced_vertices()
    t_extract = time.monotonic()
    raw_faces = len(mesh.triangles)
    if len(mesh.triangles) > max_faces:
        mesh = mesh.simplify_quadric_decimation(max_faces)
    mesh.remove_degenerate_triangles()
    mesh.remove_unreferenced_vertices()
    t_fusion = time.monotonic()
    vertices = np.asarray(mesh.vertices)
    level, center, method, floor = level_scene(vertices, extrinsic, ups, unit)
    vertices = (vertices @ level.T - center).astype(np.float32)
    # glTF COLOR_0 is linear. Source images/TSDF colors are sRGB; exporting them
    # unchanged applies gamma twice in Three.js and washes out the photograph.
    colors = np.round(srgb_to_linear(np.asarray(mesh.vertex_colors)) * 255).astype(np.uint8)
    glb = export_mesh(vertices, np.asarray(mesh.triangles), colors)
    rotation = extrinsic[:, :3, :3]
    positions = -np.einsum('sji,sj->si', rotation, extrinsic[:, :3, 3]) @ level.T - center
    forwards = rotation[:, 2, :] @ level.T
    cameras = [{'id': ids[i], 'position': positions[i].round(5).tolist(), 'forward': forwards[i].round(5).tolist()} for i in range(n)]
    meta = {'frames': n, 'points': len(vertices), 'faces': len(mesh.triangles), 'representation': 'surface',
            'leveledBy': method, 'floorBy': floor, 'medianDepth': round(unit, 5), 'cameras': cameras,
            'bounds': [vertices.min(0).tolist(), vertices.max(0).tolist()], 'colorSpace': 'linear',
            'compression': 'draco',
            'voxelSize': voxel, 'quality': quality,
            'rawFaces': raw_faces, 'integrationSeconds': round(t_integrate - t_filter, 3),
            'extractionSeconds': round(t_extract - t_integrate, 3), 'decimationSeconds': round(t_fusion - t_extract, 3),
            'filterSeconds': round(t_filter - t0, 3), 'fusionSeconds': round(t_fusion - t_filter, 3),
            'postprocessSeconds': round(time.monotonic() - t0, 3)}
    return meta, glb
