"""Compare geometry settings on identical saved VGGT predictions (no model/GPU required)."""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from surface import build_surface

ap = argparse.ArgumentParser()
ap.add_argument('prediction', type=Path)
ap.add_argument('output', type=Path)
args = ap.parse_args()
data = np.load(args.prediction)
meta, glb = build_surface(**dict(data), ids=[str(i) for i in range(len(data['depth']))])
args.output.with_suffix('.glb').write_bytes(glb)
args.output.with_suffix('.json').write_text(json.dumps(meta, indent=2))
print(json.dumps(meta), flush=True)
