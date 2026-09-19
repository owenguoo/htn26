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
