"""Replay growing photo batches through the real worker API; save artifacts and timings.

python gpu/quality/replay.py --url http://127.0.0.1:18766 --input .runtime/capture --output web/models/quality
"""
import argparse
import hashlib
import json
import struct
import time
import urllib.request
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument('--url', required=True)
ap.add_argument('--input', type=Path, required=True)
ap.add_argument('--output', type=Path, required=True)
ap.add_argument('--batches', default='8,12,16')
args = ap.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
paths = sorted(args.input.glob('*.jpg'))
report = []
for count in map(int, args.batches.split(',')):
    if not 2 <= count <= len(paths):
        raise ValueError(f'batch {count} requires more input photos')
    photos = [(p.stem, p.read_bytes()) for p in paths[:count]]
    header = json.dumps({'frames': [{'id': k, 'size': len(v)} for k, v in photos], 'maxPoints': 150000}).encode()
    body = struct.pack('>I', len(header)) + header + b''.join(v for _, v in photos)
    started = time.monotonic()
    request = urllib.request.Request(args.url.rstrip('/') + '/reconstruct', data=body,
                                     headers={'Content-Type': 'application/octet-stream'})
    with urllib.request.urlopen(request, timeout=180) as reply:
        raw = reply.read()
    n = struct.unpack('>I', raw[:4])[0]
    meta, glb = json.loads(raw[4:4+n]), raw[4+n:]
    if not glb.startswith(b'glTF') or len(meta['cameras']) != count:
        raise ValueError('invalid reconstruction response')
    meta.update(roundTripSeconds=round(time.monotonic() - started, 3), bytes=len(glb),
                sha256=hashlib.sha256(glb).hexdigest())
    stem = args.output / f'batch-{count}'
    stem.with_suffix('.glb').write_bytes(glb)
    stem.with_suffix('.json').write_text(json.dumps(meta, indent=2))
    report.append({k: v for k, v in meta.items() if k not in ('cameras', 'bounds')})
    (args.output / 'replay.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report[-1]), flush=True)
