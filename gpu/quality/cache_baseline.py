"""One isolated baseline run; capture predictions so geometry experiments share identical input.

Use a saved copy of the unmodified worker, never the running production worker.
"""
import argparse
import importlib.util
import json
from pathlib import Path

import numpy as np
import torch

ap = argparse.ArgumentParser()
ap.add_argument('--worker', type=Path, required=True)
ap.add_argument('--input', type=Path, required=True)
ap.add_argument('--output', type=Path, required=True)
ap.add_argument('--checkpoint', type=Path, required=True)
ap.add_argument('--no-cache', action='store_true', help='measure baseline without diagnostic prediction I/O')
args = ap.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('baseline', args.worker)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
worker.load(args.checkpoint)
original = worker.model


def capture(images):
    prediction = original(images)
    extrinsic, intrinsic = worker.encoding_to_camera(prediction['pose_enc'].float(), images.shape[-2:])
    def cpu(t):
        return t.detach().float().cpu().numpy()[0]
    np.savez(args.output / 'prediction.npz',
             depth=cpu(prediction['depth'])[..., 0], confidence=cpu(prediction['depth_conf']),
             rgb=cpu(prediction['images']).transpose(0, 2, 3, 1),
             extrinsic=cpu(extrinsic), intrinsic=cpu(intrinsic))
    return prediction


if not args.no_cache:
    worker.model = capture
paths = sorted(args.input.glob('*.jpg'))
metadata, glb = worker.reconstruct([p.read_bytes() for p in paths], [p.stem for p in paths], 150000)
(args.output / 'baseline.glb').write_bytes(glb)
(args.output / 'baseline.json').write_text(json.dumps(metadata, indent=2))
print(json.dumps(metadata), flush=True)
