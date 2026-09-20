import {test} from 'node:test';
import assert from 'node:assert/strict';
import {tracePlan} from '../web/sim-scan.js';

// A 4 × 3 m room scanned as points: floor everywhere, walls to 2.4 m all round with a doorway
// in the east wall, and a table. Centered on the origin, the way scanning apps export.
function room() {
  const pts = [];
  for (let x = -2; x <= 2; x += 0.05) for (let z = -1.5; z <= 1.5; z += 0.05) {
    pts.push(x, 0, z);
    const wall = Math.abs(x) > 1.95 || Math.abs(z) > 1.45;
    const doorway = x > 1.95 && Math.abs(z) < 0.5;
    if (wall && !doorway) for (let y = 0.1; y <= 2.4; y += 0.1) pts.push(x, y, z);
    if (doorway) pts.push(x, 2.2, z);                       // the lintel is over head height
    if (Math.abs(x + 1) < 0.4 && Math.abs(z) < 0.3) pts.push(x, 0.75, z, x, 0.7, z);  // table top
  }
  return new Float32Array(pts);
}

test('a scan traces to walls, furniture, floor and outside', () => {
  const plan = tracePlan(room(), {cell: 0.25, margin: 2});
  const at = (x, z) => plan.grid[Math.floor((z + plan.offset[2]) / 0.25)][Math.floor((x + plan.offset[0]) / 0.25)];
  assert.equal(at(0.5, 0.5), '.');
  assert.equal(at(-1.97, 0), '#');
  assert.equal(at(1.97, 0), '.', 'the doorway is open even though it has a lintel');
  assert.equal(at(-1, 0), 'o', 'a table blocks the way, not the view');
  assert.equal(plan.grid[0][0], ' ', 'nothing scanned out here');
  assert.ok(Math.abs(plan.offset[1]) < 0.05, 'the floor is found at the bottom of the scan');
});

test('a scan too big for its cells says what to do', () => {
  const pts = new Float32Array(3000);
  for (let i = 0; i < 1000; i++) { pts[i * 3] = (i % 2) * 400; pts[i * 3 + 2] = (i % 3) * 200; }
  assert.throws(() => tracePlan(pts, {cell: 0.25}), /check the scale/);
});
