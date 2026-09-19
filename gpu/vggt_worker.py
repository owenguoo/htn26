"""Persistent VGGT-Omega worker: phone images -> fused, colored, Draco-compressed surface GLB.

The model stays loaded between batches. --representation points retains the original point-cloud
pipeline for comparison; the default surface pipeline needs requirements-surface.txt as well.

Runs on 127.0.0.1 only; the hub reaches it through an SSH tunnel. Standard library HTTP, so it
needs nothing beyond the pod's existing venv.

    POST /reconstruct   body: [uint32 BE header length][JSON header][JPEG bytes back to back]
                        header: {"frames": [{"id": "...", "size": <bytes>, "up": [x, y, z] | null}, ...],
                                 "maxPoints": 150000}
                        "up" (optional): gravity-up in that camera's axes (x right, y down, z forward),
                        from the phone's motion sensors. Used to level the scene when given.
                        reply:  [uint32 BE header length][JSON metadata][GLB bytes]
    GET  /health        {"ready": true, "gpu": "...", "busy": false, "runs": n}

    OMP_NUM_THREADS=8 venv/bin/python vggt_worker.py --checkpoint model.pt --port 8765
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import cv2
import numpy as np
import torch
import trimesh

ROOT = Path(__file__).resolve().parent.parent  # /workspace/swarm-map-test
sys.path.insert(0, os.environ.get("VGGT_ROOT", str(ROOT / "vggt-omega")))
from vggt_omega.models import VGGTOmega  # noqa: E402
from vggt_omega.utils.load_fn import load_and_preprocess_images  # noqa: E402
from vggt_omega.utils.pose_enc import encoding_to_camera  # noqa: E402

MAX_FRAMES = 48
model = None
representation = 'surface'
lock = threading.Lock()
stats = {"runs": 0, "busy": False, "loadedSeconds": None}


def load(checkpoint: Path) -> None:
    global model
    t0 = time.monotonic()
    m = VGGTOmega().eval()
    m.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True))
    model = m.to("cuda")
    stats["loadedSeconds"] = round(time.monotonic() - t0, 1)
    print(f"model loaded in {stats['loadedSeconds']}s", flush=True)


def reconstruct(jpegs: list[bytes], ids: list[str], max_points: int, ups: list | None = None, voxel_resolution: int = 128) -> tuple[dict, bytes]:
    started = time.monotonic()
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for i, data in enumerate(jpegs):
            p = Path(tmp) / f"{i:04d}.jpg"
            p.write_bytes(data)
            paths.append(str(p))
        images = load_and_preprocess_images(paths, image_resolution=512).to("cuda")
    torch.cuda.reset_peak_memory_stats()
    torch.cuda.synchronize()
    t_fwd = time.monotonic()
    with torch.inference_mode(), torch.autocast("cuda", dtype=torch.bfloat16):
        prediction = model(images)
    torch.cuda.synchronize()
    inference_s = time.monotonic() - t_fwd
    peak_gb = torch.cuda.max_memory_allocated() / 1024 ** 3

    # ---- same post-processing as reconstruct.py
    extrinsic, intrinsic = encoding_to_camera(prediction["pose_enc"].float(), images.shape[-2:])

    def array(t):
        return t.detach().float().cpu().numpy()[0]

    extrinsic, intrinsic = array(extrinsic), array(intrinsic)
    depth, confidence = array(prediction["depth"])[..., 0], array(prediction["depth_conf"])
    confidence = confidence.reshape(depth.shape)
    rgb = np.transpose(array(prediction["images"]), (0, 2, 3, 1))
    if representation == 'surface':
        from surface import build_surface
        meta, glb = build_surface(depth, confidence, rgb, extrinsic, intrinsic, ids, ups, voxel_resolution=voxel_resolution,
                                  max_faces=max(20000, min(300000, max_points * 2)))
        meta.update(source="VGGT-Omega-1B-512", inferenceSeconds=round(inference_s, 3),
                    totalSeconds=round(time.monotonic() - started, 3), peakAllocatedGB=round(peak_gb, 2),
                    units="unregistered scene units; Y up; floor estimate in floorBy")
        return meta, glb
    n, h, w = depth.shape
    yy, xx = np.meshgrid(np.arange(h), np.arange(w), indexing="ij")
    cam_pts = np.stack([(xx[None] - intrinsic[:, 0, 2, None, None]) / intrinsic[:, 0, 0, None, None] * depth,
                        (yy[None] - intrinsic[:, 1, 2, None, None]) / intrinsic[:, 1, 1, None, None] * depth,
                        depth], axis=-1)
    rotation, translation = extrinsic[:, :3, :3], extrinsic[:, :3, 3]
    points = np.einsum("sij,shwj->shwi", rotation.transpose(0, 2, 1), cam_pts - translation[:, None, None, :])
    valid = np.isfinite(points).all(axis=-1) & np.isfinite(confidence) & (depth > 0)
    valid &= confidence >= np.percentile(confidence[valid], 50)
    for i in range(n):
        dil = cv2.dilate(depth[i], np.ones((3, 3), np.uint8))
        ero = cv2.erode(depth[i], np.ones((3, 3), np.uint8))
        valid[i] &= (dil - ero) / np.maximum(depth[i], 1e-6) < 0.05
    points, colors = points[valid], (np.clip(rgb[valid], 0, 1) * 255).astype(np.uint8)
    if len(points) < 1000:
        raise ValueError("too few reliable points: need brighter, sharper, overlapping views")
    low, high = np.percentile(points, [1, 99], axis=0)
    span = np.maximum(high - low, 1e-6)
    keep = ((points >= low - span * 0.15) & (points <= high + span * 0.15)).all(axis=1)
    points, colors = points[keep], colors[keep]
    # level: +Y should be up. Best: gravity from each phone's sensors, taken into world axes by that
    # camera's rotation. Otherwise assume cameras were held level (their image-up is up), which tilts
    # the scene by however much people pointed their phones down.
    grav = [rotation[i].T @ np.asarray(u, float) for i, u in enumerate(ups or []) if u is not None and i < n]
    if len(grav) >= max(2, n // 2):
        up, leveled_by = np.median([g / max(np.linalg.norm(g), 1e-8) for g in grav], axis=0), "gravity"
    else:
        up, leveled_by = -np.median(rotation[:, 1, :], axis=0), "camera-up"
    up /= max(np.linalg.norm(up), 1e-8)
    target = np.array([0.0, 1.0, 0.0])
    v, cosine = np.cross(up, target), np.clip(np.dot(up, target), -1, 1)
    if cosine < -0.9999:
        level = np.diag([1.0, -1.0, -1.0])
    else:
        skew = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
        level = np.eye(3) + skew + skew @ skew / max(1 + cosine, 1e-8)
    points = points @ level.T
    center = np.median(points, axis=0)
    center[1] = np.percentile(points[:, 1], 2)  # floor-ish at y = 0
    points -= center
    extent = np.max(np.percentile(points, 99, axis=0) - np.percentile(points, 1, axis=0))
    voxel = max(extent / 350, 1e-6)
    _, keep = np.unique(np.floor(points / voxel).astype(np.int64), axis=0, return_index=True)
    if len(keep) > max_points:
        keep = np.random.default_rng(0).choice(keep, max_points, replace=False)
    points, colors = points[keep].astype(np.float32), colors[keep]

    # cameras in the output frame: where each was, and which way its lens pointed
    positions = -np.einsum("sji,sj->si", rotation, translation) @ level.T - center
    forwards = rotation[:, 2, :] @ level.T  # camera +Z (optical axis) in world, then leveled
    cameras = [{"id": ids[i], "position": positions[i].round(4).tolist(), "forward": forwards[i].round(4).tolist()}
               for i in range(n)]

    glb = trimesh.Scene(trimesh.PointCloud(vertices=points, colors=colors)).export(file_type="glb")
    meta = {"source": "VGGT-Omega-1B-512", "frames": n, "points": int(len(points)),
            "inferenceSeconds": round(inference_s, 2), "totalSeconds": round(time.monotonic() - started, 2),
            "peakAllocatedGB": round(peak_gb, 2), "units": "unregistered scene units, leveled, floor near y=0",
            "leveledBy": leveled_by, "medianDepth": round(float(np.median(depth[depth > 0])), 4),
            "cameras": cameras,
            "bounds": [points.min(axis=0).tolist(), points.max(axis=0).tolist()]}
    return meta, glb


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # quieter than the default per-request stderr line
        pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/health":
            return self._send(404, b"{}", "application/json")
        body = {"ready": model is not None, "gpu": torch.cuda.get_device_name(), "representation": representation, **stats}
        self._send(200, json.dumps(body).encode(), "application/json")

    def do_POST(self):
        if self.path != "/reconstruct":
            return self._send(404, b"{}", "application/json")
        try:
            raw = self.rfile.read(int(self.headers["Content-Length"]))
            (n,) = struct.unpack(">I", raw[:4])
            header = json.loads(raw[4:4 + n])
            frames, off, jpegs, ids, ups = header["frames"][:MAX_FRAMES], 4 + n, [], [], []
            for f in frames:
                jpegs.append(raw[off:off + f["size"]])
                ids.append(str(f["id"]))
                ups.append(f.get("up"))
                off += f["size"]
            if len(jpegs) < 2:
                raise ValueError("need at least 2 frames")
            with lock:  # one reconstruction at a time on the GPU
                stats["busy"] = True
                try:
                    meta, glb = reconstruct(jpegs, ids, int(header.get("maxPoints", 150000)), ups,
                                            max(64, min(128, int(header.get("voxelResolution", 128)))))
                finally:
                    stats["busy"] = False
            stats["runs"] += 1
            head = json.dumps(meta).encode()
            print(f"run {stats['runs']}: {meta['frames']} frames, {meta['points']} points, leveled by {meta['leveledBy']}, "
                  f"{meta['inferenceSeconds']}s inference, {meta['totalSeconds']}s total", flush=True)
            self._send(200, struct.pack(">I", len(head)) + head + glb, "application/octet-stream")
        except Exception as e:
            print(f"error: {e}", flush=True)
            self._send(500, json.dumps({"error": str(e)[:300]}).encode(), "application/json")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", type=Path, default=ROOT / "model.pt")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--representation", choices=['surface', 'points'], default='surface',
                    help="surface fuses agreeing depth views; points preserves the original pipeline")
    a = ap.parse_args()
    representation = a.representation
    if representation == 'surface':
        import surface  # fail at startup if optional GPU-worker dependencies are missing
    load(a.checkpoint)
    print(f"listening on 127.0.0.1:{a.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()
