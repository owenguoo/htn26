"""Replay growing prefixes through the real whole-room worker, without pose input.

The input directory contains report.json selectedFrames and matching JPEGs. The
4245 selection was extracted across the complete video; no COLMAP poses enter
these requests. Output timing includes HTTP and model/mesh work, not extraction.
"""
import argparse
import json
import struct
import time
import urllib.request
from pathlib import Path


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('directory',type=Path)
    ap.add_argument('--url',default='http://127.0.0.1:8879')
    args=ap.parse_args();root=args.directory
    ids=json.loads((root/'report.json').read_text())['selectedFrames']
    results=[]
    for count in sorted(set([min(x,len(ids)) for x in (12,24,44,64,88,96)])):
        names=ids[:count];images=[(root/name).read_bytes() for name in names]
        head=json.dumps({'mode':'global','voxelResolution':64,'frames':[
            {'id':name,'size':len(data)} for name,data in zip(names,images)]}).encode()
        started=time.monotonic()
        request=urllib.request.Request(args.url+'/reconstruct',data=struct.pack('>I',len(head))+head+b''.join(images))
        try:
            with urllib.request.urlopen(request,timeout=180) as response: raw=response.read()
        except urllib.error.HTTPError as error:
            raise RuntimeError(error.read().decode()) from error
        n,=struct.unpack('>I',raw[:4]);meta=json.loads(raw[4:4+n])
        assert meta['mode']=='global' and meta['frames']==count
        assert raw[4+n:][:4]==b'glTF'
        (root/f'global-live-{count}.glb').write_bytes(raw[4+n:])
        results.append(meta|{'wallSeconds':round(time.monotonic()-started,3)})
        print(json.dumps({k:v for k,v in results[-1].items() if k not in ('cameras','bounds')}),flush=True)
    (root/'global-live-report.json').write_text(json.dumps(results,indent=2))


if __name__=='__main__': main()
