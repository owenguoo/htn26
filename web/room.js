// Floor-plan geometry shared by the phone page and the dashboard.
// Room coordinates are meters, drawn with the stage at the top of the map:
// x = 0 at stage center (+x = map right), y = 0 at the stage edge (+y = toward the back).
// Heading: degrees, 0 = facing the stage, clockwise when viewed from above.

export async function loadRoom() {
  const res = await fetch('/api/room');
  return res.json();
}

export function bounds(room) {
  return { x0: -room.width / 2, x1: room.width / 2, y0: -room.stage.depth, y1: room.depth };
}

// Fit the room into a w×h pixel box with padding; returns converters.
export function makeView(room, w, h, pad = 16) {
  const b = bounds(room);
  const scale = Math.min((w - 2 * pad) / (b.x1 - b.x0), (h - 2 * pad) / (b.y1 - b.y0));
  const ox = (w - scale * (b.x1 - b.x0)) / 2 - b.x0 * scale;
  const oy = (h - scale * (b.y1 - b.y0)) / 2 - b.y0 * scale;
  return {
    scale,
    toPx: (x, y) => [ox + x * scale, oy + y * scale],
    toRoom: (px, py) => [(px - ox) / scale, (py - oy) / scale],
  };
}

export function headingVector(deg) {
  const r = (deg * Math.PI) / 180;
  return [Math.sin(r), -Math.cos(r)];
}

export function drawRoom(ctx, room, view, { grid = true, colors = {} } = {}) {
  const c = {
    floor: colors.floor || 'rgba(255,255,255,0.03)',
    wall: colors.wall || 'rgba(255,255,255,0.35)',
    grid: colors.grid || 'rgba(255,255,255,0.06)',
    stage: colors.stage || 'rgba(255,255,255,0.18)',
    text: colors.text || 'rgba(255,255,255,0.6)',
  };
  const [ax, ay] = view.toPx(-room.width / 2, 0);
  const [bx, by] = view.toPx(room.width / 2, room.depth);
  ctx.fillStyle = c.floor;
  ctx.fillRect(ax, ay, bx - ax, by - ay);

  if (grid) {
    ctx.strokeStyle = c.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = Math.ceil(-room.width / 2); x <= room.width / 2; x++) {
      const [px] = view.toPx(x, 0);
      ctx.moveTo(px, ay); ctx.lineTo(px, by);
    }
    for (let y = 0; y <= room.depth; y++) {
      const [, py] = view.toPx(0, y);
      ctx.moveTo(ax, py); ctx.lineTo(bx, py);
    }
    ctx.stroke();
  }

  ctx.strokeStyle = c.wall;
  ctx.lineWidth = 2;
  ctx.strokeRect(ax, ay, bx - ax, by - ay);

  const [sx, sy] = view.toPx(-room.stage.width / 2, -room.stage.depth);
  const [ex, ey] = view.toPx(room.stage.width / 2, 0);
  ctx.fillStyle = c.stage;
  ctx.fillRect(sx, sy, ex - sx, ey - sy);
  ctx.fillStyle = c.text;
  ctx.font = `600 ${Math.max(10, view.scale * 0.6)}px ui-sans-serif, system-ui, sans-serif`;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText('STAGE', (sx + ex) / 2, (sy + ey) / 2);
}

// Filled view wedge from (x, y) along `heading`.
export function drawCone(ctx, view, x, y, heading, fovDeg, length, fill, stroke) {
  const [px, py] = view.toPx(x, y);
  const r = length * view.scale;
  // canvas angle 0 = +x; our heading 0 = -y (toward stage)
  const mid = ((heading - 90) * Math.PI) / 180;
  const half = (fovDeg / 2) * (Math.PI / 180);
  const grad = ctx.createRadialGradient(px, py, 0, px, py, r);
  grad.addColorStop(0, fill);
  grad.addColorStop(1, 'rgba(0,0,0,0)');
  ctx.beginPath();
  ctx.moveTo(px, py);
  ctx.arc(px, py, r, mid - half, mid + half);
  ctx.closePath();
  ctx.fillStyle = grad;
  ctx.fill();
  if (stroke) {
    ctx.strokeStyle = stroke;
    ctx.lineWidth = 1;
    ctx.stroke();
  }
}

// ---------------------------------------------------------------- search heat
// The hub's `heat` (swarm/coverage.py `Coverage.snapshot`) is one base-36
// character per floor cell: that cell's probability relative to the hottest
// cell. Two things have to happen to it before it is worth looking at.
//
// 1. Equalisation, not a min/max stretch. The probability field has a shape
//    that defeats a linear ramp from both ends. Cells nobody has looked at yet
//    all hold exactly the *same* probability, so most of the map is one
//    plateau with dents worn into it where the cameras have swept — a linear
//    ramp paints that plateau at full strength and the map becomes a solid
//    sheet. Then one detection boost lifts a single cell far above the
//    plateau, the encoding is relative to the hottest cell, and the entire
//    plateau collapses into one or two of the 36 steps — a linear ramp now
//    paints it at nothing and the map goes blank apart from one dot. Ranking
//    the cells instead (a 36-bin histogram equalisation, ties sharing the
//    midpoint of their span) survives both: the plateau lands mid-tone, swept
//    floor fades out under it, and a boosted cell still tops the ramp.
// 2. One alpha per cell, applied once. The 2D map used to stamp a blurred disc
//    per cell at a radius of 1.8 cells, so about ten discs piled up on every
//    pixel and alpha .18 compounded to alpha .9 — a solid green sheet with
//    holes worn in it where the search had already been, which reads as the
//    exact inverse of what it means. Painting the grid once, at cell
//    resolution, and letting the scaler interpolate keeps the ramp honest.
export const HEAT_RGB = [24, 131, 75];
/// Alpha of the hottest cell. Everything below it falls off faster than linear
/// so that a broad "not looked at yet" field stays a wash and a real hotspot
/// still reads as a hotspot.
export const HEAT_MAX_ALPHA = 0.34;
const HEAT_GAMMA = 1.8;
/// `HEAT_LEVELS` in swarm/coverage.py: how many steps `heat` is encoded in.
const HEAT_STEPS = 36;
/// Below this much spread between the low percentile and the peak there is no
/// story to tell — an untouched map, or one that has been swept flat.
const HEAT_MIN_SPREAD = 0.04;
const HEAT_LOW_PERCENTILE = 0.05;

export function heatAlpha(level) {
  return HEAT_MAX_ALPHA * Math.pow(Math.min(1, Math.max(0, level)), HEAT_GAMMA);
}

/// Rank of each bin among all cells, 0..1, ties sharing the midpoint of the
/// span they occupy. `bins` holds one 0..HEAT_STEPS-1 index per cell.
export function heatEqualise(bins) {
  const n = bins.length;
  const counts = new Int32Array(HEAT_STEPS);
  for (let i = 0; i < n; i++) counts[bins[i]]++;
  const level = new Float64Array(HEAT_STEPS);
  let seen = 0;
  for (let v = 0; v < HEAT_STEPS; v++) {
    if (!counts[v]) continue;
    level[v] = n > 1 ? (seen + (counts[v] - 1) / 2) / (n - 1) : 1;
    seen += counts[v];
  }
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) out[i] = level[bins[i]];
  return out;
}

/// Row-major 0..1 levels for a coverage snapshot, or null when the field is
/// too flat to draw.
export function heatLevels(cov) {
  const n = (cov?.cols || 0) * (cov?.rows || 0);
  if (!cov?.heat || !n || cov.heat.length < n) return null;
  const bins = new Int32Array(n);
  for (let i = 0; i < n; i++) {
    const v = parseInt(cov.heat[i], 36);
    bins[i] = Number.isFinite(v) ? Math.min(HEAT_STEPS - 1, Math.max(0, v)) : 0;
  }
  const sorted = Int32Array.from(bins).sort();
  const spread = (sorted[n - 1] - sorted[Math.floor(n * HEAT_LOW_PERCENTILE)]) / (HEAT_STEPS - 1);
  if (!(spread > HEAT_MIN_SPREAD)) return null;
  return heatEqualise(bins);
}

/// The field as a cols×rows RGBA canvas, one pixel per cell. Draw it scaled up
/// with smoothing on; do not stamp it cell by cell. `alphaFor(level, index)`
/// defaults to the shared ramp — the 3D floor overrides it to fade the heat
/// where the live scan has no floor under it.
export function heatCanvas(cov, levels, alphaFor = heatAlpha, target = document.createElement('canvas')) {
  target.width = cov.cols;
  target.height = cov.rows;
  const g = target.getContext('2d');
  const img = g.createImageData(cov.cols, cov.rows);
  for (let i = 0; i < levels.length; i++) {
    img.data[i * 4] = HEAT_RGB[0];
    img.data[i * 4 + 1] = HEAT_RGB[1];
    img.data[i * 4 + 2] = HEAT_RGB[2];
    img.data[i * 4 + 3] = Math.round(255 * Math.min(1, Math.max(0, alphaFor(levels[i], i))));
  }
  g.putImageData(img, 0, 0);
  return target;
}
