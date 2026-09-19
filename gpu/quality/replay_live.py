"""Replay real JPEGs through phone ingestion, visual selection, and the live worker.

Uses a separate artifact directory; never changes the running dashboard's map.
Two phone identities are replayed with no positions/headings to exercise that path.
"""
import argparse
import asyncio
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from swarm.hub import Hub, Phone, ROOM
from swarm.mapper import Mapper
from swarm.protocol import pack


async def main(args):
    paths = sorted(Path(args.input).glob('*.jpg'))
    if len(paths) < 6:
        raise SystemExit('Need at least six JPEGs')
    out = Path(args.output)
    if (out / 'last.json').exists():
        raise SystemExit('Choose a fresh output directory to preserve previous results')
    hub = Hub()
    mapper = hub.mapper = Mapper(hub, ROOM, out)
    mapper.url = args.url
    mapper.enabled = True
    phones = [Phone(id=f'replay-{i}', index=i, connected=True) for i in range(2)]
    for p in phones:
        hub.phones[p.id] = p
    reports, runs = [], []
    job = None
    for i, path in enumerate(paths):
        phone = phones[i % 2]
        hub.on_frame(phone, pack({'type': 'frame', 'scanKeyframe': True, 'seq': i}, path.read_bytes()))
        # Advance the candidate window without wall-clock waiting during replay.
        phone.scan_frame['at'] -= 1200
        mapper.sample_times.clear()
        start = time.monotonic()
        await mapper.sample()
        row = {'file': path.name, 'phone': phone.id, 'accepted': len(mapper.keyframes),
               'selectionMs': round((time.monotonic() - start) * 1000, 1),
               'status': mapper.selection_hints.get(phone.id)}
        reports.append(row)
        print(json.dumps(row), flush=True)
        if len(mapper.keyframes) >= 6 and job is None:
            job = asyncio.create_task(mapper.rebuild())
            await asyncio.sleep(0)  # later frames arrive while this request runs
    if job:
        await job
        runs.append({'version': mapper.version, 'error': mapper.error, 'last': mapper.last})
        if mapper.pending and not mapper.error:
            await mapper.rebuild()
            runs.append({'version': mapper.version, 'error': mapper.error, 'last': mapper.last})
    out.mkdir(parents=True, exist_ok=True)
    result = {'inputs': len(paths), 'archive': len(mapper.keyframes), 'runs': runs, 'frames': reports}
    (out / 'replay.json').write_text(json.dumps(result, indent=2))
    print(json.dumps({'archive': len(mapper.keyframes), 'versions': mapper.version, 'error': mapper.error}), flush=True)
    if mapper.version == 0 or mapper.error:
        raise SystemExit('Live replay did not complete successfully; inspect replay.json')


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--input', required=True)
    ap.add_argument('--output', required=True)
    ap.add_argument('--url', default='http://127.0.0.1:18766')
    asyncio.run(main(ap.parse_args()))
