// Trace a floor plan off a 3D scan: which floor cells have a wall on them, which have furniture,
// which are open floor, and which aren't part of the building at all.
//
// The scan is assumed to be in meters with Y up (what Polycam, Scaniverse, RoomPlan and the VGGT
// worker all export). Scale and turn are there for the ones that aren't.

const FLOOR_PERCENTILE = 0.02;  // the floor is about where the lowest 2% of the scan is
const STEP_OVER_M = 0.3;        // anything lower than this you step over
const SEE_OVER_M = 1.2;         // anything that stops below this you can see across (tables, beds, sofas)
const HEAD_M = 1.9;             // above head height doesn't matter: door lintels, ceilings, lights
const MIN_HITS = 2;             // one stray point isn't a wall
export const MAX_CELLS = 40000; // swarm/simulator.py MAX_CELLS

/// points: Float32Array of x, y, z triples in meters, Y up.
/// Returns the plan and how the scan sits on it: plan x = scan x + offset[0], plan y = scan z + offset[2],
/// and the floor is at scan y = -offset[1].
export function tracePlan(points, { cell = 0.25, margin = 2 } = {}) {
  const n = Math.floor(points.length / 3);
  if (n < 100) throw new Error('That scan has almost nothing in it.');
  const stride = Math.max(1, Math.floor(n / 200000));
  const heights = [];
  let minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity;
  for (let i = 0; i < n; i++) {
    const x = points[i * 3], z = points[i * 3 + 2];
    if (x < minX) minX = x; if (x > maxX) maxX = x;
    if (z < minZ) minZ = z; if (z > maxZ) maxZ = z;
    if (i % stride === 0) heights.push(points[i * 3 + 1]);
  }
  heights.sort((a, b) => a - b);
  const floorY = heights[Math.floor(heights.length * FLOOR_PERCENTILE)];
  const cols = Math.ceil((maxX - minX) / cell) + 2 * margin;
  const rows = Math.ceil((maxZ - minZ) / cell) + 2 * margin;
  if (cols * rows > MAX_CELLS) {
    const needed = Math.sqrt(((maxX - minX) * (maxZ - minZ)) / (MAX_CELLS * 0.9));
    throw new Error(`This scan covers ${(maxX - minX).toFixed(0)} × ${(maxZ - minZ).toFixed(0)} m, too big for ${cell} m cells. `
      + `Use cells of ${(Math.ceil(needed * 20) / 20).toFixed(2)} m or more, or check the scale.`);
  }
  const ox = margin * cell - minX, oz = margin * cell - minZ;
  const floor = new Uint16Array(cols * rows), low = new Uint16Array(cols * rows), high = new Uint16Array(cols * rows);
  for (let i = 0; i < n; i++) {
    const h = points[i * 3 + 1] - floorY;
    if (h > HEAD_M || h < -STEP_OVER_M) continue;
    const c = Math.floor((points[i * 3] + ox) / cell), r = Math.floor((points[i * 3 + 2] + oz) / cell);
    const k = r * cols + c;
    const layer = h < STEP_OVER_M ? floor : h < SEE_OVER_M ? low : high;
    if (layer[k] < 65535) layer[k]++;
  }
  const grid = [];
  for (let r = 0; r < rows; r++) {
    let row = '';
    for (let c = 0; c < cols; c++) {
      const k = r * cols + c;
      row += high[k] >= MIN_HITS ? '#' : low[k] >= MIN_HITS ? 'o' : floor[k] >= 1 ? '.' : ' ';
    }
    grid.push(row);
  }
  return { grid, cols, rows, cell, offset: [ox, -floorY, oz] };
}

/// Points spread evenly over every surface in a loaded scan (three.js object), in world space.
/// Vertices alone won't do: a decimated wall is two big triangles, which is four points and a gap.
export function samplePoints(root, THREE, spacing) {
  const out = [];
  const a = new THREE.Vector3(), b = new THREE.Vector3(), c = new THREE.Vector3(), ab = new THREE.Vector3(), ac = new THREE.Vector3();
  let seed = 1;
  const rand = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
  root.updateMatrixWorld(true);
  root.traverse((o) => {
    const pos = o.geometry?.attributes?.position;
    if (!pos || (!o.isMesh && !o.isPoints)) return;
    if (o.isPoints) {
      for (let i = 0; i < pos.count; i++) { a.fromBufferAttribute(pos, i).applyMatrix4(o.matrixWorld); out.push(a.x, a.y, a.z); }
      return;
    }
    const index = o.geometry.index;
    const triangles = (index ? index.count : pos.count) / 3;
    for (let t = 0; t < triangles; t++) {
      const i0 = index ? index.getX(t * 3) : t * 3, i1 = index ? index.getX(t * 3 + 1) : t * 3 + 1, i2 = index ? index.getX(t * 3 + 2) : t * 3 + 2;
      a.fromBufferAttribute(pos, i0).applyMatrix4(o.matrixWorld);
      b.fromBufferAttribute(pos, i1).applyMatrix4(o.matrixWorld);
      c.fromBufferAttribute(pos, i2).applyMatrix4(o.matrixWorld);
      ab.subVectors(b, a); ac.subVectors(c, a);
      const area = ab.clone().cross(ac).length() / 2;
      const count = Math.min(2000, Math.max(1, Math.ceil(area / (spacing * spacing))));
      for (let k = 0; k < count; k++) {
        let u = rand(), v = rand();
        if (u + v > 1) { u = 1 - u; v = 1 - v; }
        out.push(a.x + ab.x * u + ac.x * v, a.y + ab.y * u + ac.y * v, a.z + ab.z * u + ac.z * v);
      }
    }
  });
  return new Float32Array(out);
}
