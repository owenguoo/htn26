// The console's Simulator tab: pick a floor plan, set up a scenario, watch the search play out,
// then run it many times to see what team size buys. The simulation itself runs in the hub
// (swarm/simulator.py); this page sets it up and plays back what it returns.
import { drawCone } from '/web/room.js';
import { tracePlan, samplePoints } from '/web/sim-scan.js';

const $ = (s) => document.querySelector(s);
const ACCENT = '#18834b', AMBER = '#d97706', RED = '#b72f36', WALL = '#466653';
const CONE_DRAW_SCALE = 0.6;   // as the console map: the wedge shows direction, not full range
const SPEEDS = [1, 2, 4, 8, 16, 32];

let envs = [];
let env = null;            // the floor plan on screen (from /api/sim/envs/{id})
let run = null;            // last /api/sim/compare result: the same hidden incident under each policy
let active = 0;            // which policy's run is on the map
let referee = true;        // judge's view: shows the hidden incident. Off = only what the commander knows
let playhead = 0, playing = false, lastTick = 0;
let mode = '2d';
let scene3d = null, scene3dLoading = null;
let casualty = null;       // operator-placed casualty {x, y}, or null for random
let placing = false;
let editing = null;        // {grid: string[][], cell, entries, scan?} while drawing a plan
let batch = null, batchSize = null, batchJob = null;
const scenario = { rescuers: 3, responders: 2 };

// ---------------------------------------------------------------- api
async function api(path, options = {}) {
  const response = await fetch(path, { credentials: 'same-origin', ...options });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(typeof body.detail === 'string' ? body.detail : `Request failed (${response.status})`);
  return body;
}
const postJson = (path, body) => api(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

// ---------------------------------------------------------------- environments
async function loadEnvs(select) {
  envs = (await api('/api/sim/envs')).environments.filter((e) => !e.error);
  const pick = $('#envPick');
  pick.replaceChildren();
  for (const [label, list] of [['Built in', envs.filter((e) => e.builtin)], ['Yours', envs.filter((e) => !e.builtin)]]) {
    if (!list.length) continue;
    const group = document.createElement('optgroup');
    group.label = label;
    for (const e of list) group.append(new Option(`${e.name} · ${e.floorM2} m²`, e.id));
    pick.append(group);
  }
  const remembered = (() => { try { return localStorage.getItem('beacon.sim.env'); } catch { return null; } })();
  const id = [select, remembered, envs[0]?.id].find((v) => v && envs.some((e) => e.id === v));
  if (id) { pick.value = id; await openEnv(id); }
}

async function openEnv(id) {
  env = await api(`/api/sim/envs/${encodeURIComponent(id)}`);
  env.cells = env.grid.map((row) => [...row]);
  env.rows = env.cells.length; env.cols = env.cells[0].length;
  try { localStorage.setItem('beacon.sim.env', id); } catch {}
  run = null; casualty = null; batch = null; batchSize = null; playing = false; playhead = 0;
  setPlacing(false);
  $('#envNote').textContent = env.description + (env.source === 'layout' ? ' Replace it with the real scan when you have one.' : '');
  $('#envSize').textContent = `${env.width} × ${env.depth} m · ${env.floorM2} m² of floor`;
  $('#envDelete').hidden = env.builtin;
  hazardCells = null;
  $('#keyFire').hidden = !env.grid.some((row) => row.includes('f'));
  $('#keySmoke').hidden = !env.grid.some((row) => /[s~]/.test(row));
  layersKey = '';
  scene3d?.setEnv(env);
  renderRun(); renderBatch(); resize();
}

$('#envPick').addEventListener('change', (e) => openEnv(e.target.value));
$('#envDelete').addEventListener('click', async () => {
  if (!confirm(`Delete “${env.name}”? Its floor plan and scan are removed from this hub.`)) return;
  await api(`/api/sim/envs/${encodeURIComponent(env.id)}`, { method: 'DELETE' });
  await loadEnvs();
});

// ---------------------------------------------------------------- scenario
function stepper(minus, plus, out, key, lo, hi) {
  const set = (d) => { scenario[key] = Math.max(lo, Math.min(hi, scenario[key] + d)); $(out).textContent = scenario[key]; };
  $(minus).addEventListener('click', () => set(-1));
  $(plus).addEventListener('click', () => set(1));
}
stepper('#resMinus', '#resPlus', '#resN', 'rescuers', 1, 12);
stepper('#respMinus', '#respPlus', '#respN', 'responders', 1, 12);

function setPlacing(on) {
  placing = on;
  for (const b of document.querySelectorAll('#casMode button')) b.setAttribute('aria-pressed', String((b.dataset.cas === 'place') === (on || !!casualty)));
  $('#casHint').textContent = casualty ? `Placed at ${casualty.x.toFixed(1)}, ${casualty.y.toFixed(1)} m` : on ? 'Click the floor plan' : 'Somewhere random each run';
  hint(on ? 'Click where the casualty is' : '');
}
$('#casMode').addEventListener('click', (e) => {
  const b = e.target.closest('[data-cas]');
  if (!b) return;
  if (b.dataset.cas === 'random') { casualty = null; setPlacing(false); }
  else { if (mode === '3d') setMode('2d'); setPlacing(true); }
});

/// Every run is a new one: the team walks in at the first entry, searches with Beacon's planner,
/// and (unless placed) the casualty is somewhere different each time.
function params() {
  return {
    env: env.id, rescuers: scenario.rescuers, responders: Math.min(scenario.responders, scenario.rescuers),
    seed: Math.floor(Math.random() * 2 ** 31), maxTime: (Number($('#maxTime').value) || 10) * 60, victim: casualty,
  };
}

async function runOnce() {
  if (!env || editing) return;
  const btn = $('#runBtn');
  btn.disabled = true; btn.textContent = 'Simulating…';
  try {
    run = await postJson('/api/sim/compare', params());
    active = run.runs.length - 1;   // open on the commander; the baseline is one click away
    tileKey = '';
    const end = Math.max(...run.runs.map((r) => r.frames.at(-1)[0]));
    // pick a speed that plays the whole run in about twenty seconds
    $('#speed').value = String(SPEEDS.find((s) => end / s <= 24) ?? 32);
    playhead = 0; playing = true; lastTick = performance.now();
    renderRun();
  } catch (error) {
    run = null; renderRun();
    $('#runEmpty').textContent = error.message;
  } finally {
    btn.disabled = false; btn.textContent = 'Run simulation';
  }
}
$('#runBtn').addEventListener('click', runOnce);

// ---------------------------------------------------------------- run results + transport
const fmtClock = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
const fmtDuration = (s) => (s == null ? '–' : s < 90 ? `${Math.round(s)}<small> s</small>` : `${Math.floor(s / 60)}<small> m </small>${Math.round(s % 60)}<small> s</small>`);

const cur = () => run.runs[active];
const endOf = (r) => r.frames.at(-1)[0];

// Lower is better for everything except contacts and reward.
const SCORE_ROWS = [
  ['Elapsed', (m) => fmtClockLong(m.elapsed), (m) => -Math.round(m.elapsed)],
  ['Found after', (m) => (m.foundAt == null ? 'never' : fmtClockLong(m.foundAt)), (m) => -Math.round(m.foundAt ?? Infinity)],
  ['Areas checked', (m) => `${m.areasChecked} <small>(${m.physicalSearches} searched, ${m.voiceChecks} called in)</small>`, null],
  ['Unnecessary trips', (m) => m.unnecessaryTrips, (m) => -m.unnecessaryTrips],
  ['Physical contacts', (m) => m.physicalContacts, (m) => m.physicalContacts],
  ['Reward', (m) => m.reward.toFixed(1), (m) => m.reward],
];
const fmtClockLong = (s) => (s < 60 ? `${Math.round(s)} s` : `${Math.floor(s / 60)} m ${String(Math.round(s % 60)).padStart(2, '0')} s`);

function renderRun() {
  $('#runOut').hidden = !run;
  $('#runEmpty').hidden = !!run;
  $('#policyPick').hidden = !run;
  $('#playBtn').disabled = $('#scrub').disabled = !run;
  if (!run) {
    $('#runEmpty').textContent = 'Run a simulation: the same hidden incident is played twice, once per policy.';
    $('#log').innerHTML = '<div class="empty">Nothing yet</div>';
    $('#clock').textContent = '0:00 / 0:00';
    return;
  }
  $('#policyPick').replaceChildren(...run.runs.map((r, i) => {
    const b = document.createElement('button');
    b.type = 'button'; b.textContent = r.policy; b.dataset.policy = i; b.setAttribute('aria-pressed', String(i === active));
    return b;
  }));
  const ref = run.referee;
  const room = (id) => env.roomList[id]?.name ?? 'somewhere';
  $('#incident').innerHTML = referee
    ? `<b>Hidden incident.</b> Casualty in ${escapeHtml(room(ref.casualty.room))}, ${ref.casualty.responsive ? 'able to answer a call' : 'unable to answer'}.
       The witness pointed to ${escapeHtml(room(ref.witness.room))} (${{ right: 'right', neighbor: 'the room next door', wrong: 'wrong' }[ref.witness.was]}).
       ${ref.blockedDoors.length ? `${ref.blockedDoors.length} doorway${ref.blockedDoors.length === 1 ? '' : 's'} blocked.` : 'No doorways blocked.'}`
    : 'Commander’s view: only what crews and witnesses have reported.';
  $('#scoreHead').innerHTML = `<th></th>${run.runs.map((r, i) => `<th class="${i === active ? 'on' : ''}">${escapeHtml(r.policy)}</th>`).join('')}`;
  $('#scoreBody').innerHTML = SCORE_ROWS.map(([name, show, better]) => {
    const scores = better ? run.runs.map((r) => better(r.metrics)) : [];
    const top = Math.max(...scores);
    const tied = scores.every((v) => v === top);
    return `<tr><td>${name}</td>${run.runs.map((r, i) => `<td class="${better && !tied && scores[i] === top ? 'best' : ''}">${show(r.metrics)}</td>`).join('')}</tr>`;
  }).join('') + (referee ? `<tr class="ref"><td>False “clear” reports</td>${run.runs.map((r) => `<td>${r.metrics.falseClears}</td>`).join('')}</tr>` : '');
  $('#scrub').max = String(endOf(cur()));
  playhead = Math.min(playhead, endOf(cur()));
  $('#logTitle').textContent = `Radio · ${cur().policy}`;
  $('#log').innerHTML = cur().reports.map((e, i) => `<div class="ev k-${e.kind}${/found|rescued|timeout|blocked/.test(e.kind) ? ' hot' : ''}" data-ev="${i}">
    <time>${fmtClock(e.t)}</time><div>${e.crew != null ? `<b>#${e.crew + 1}</b> ` : ''}${escapeHtml(e.text)}</div></div>`).join('');
}

$('#policyPick').addEventListener('click', (e) => {
  const b = e.target.closest('[data-policy]');
  if (!b) return;
  active = Number(b.dataset.policy); tileKey = '';
  renderRun();
});
$('#refereeBtn').addEventListener('click', () => {
  referee = !referee;
  $('#refereeBtn').setAttribute('aria-pressed', String(referee));
  if (run) renderRun();
});

$('#log').addEventListener('click', (e) => {
  const row = e.target.closest('[data-ev]');
  if (row && run) { playhead = cur().reports[Number(row.dataset.ev)].t; playing = false; }
});
$('#playBtn').addEventListener('click', () => {
  if (!run) return;
  if (!playing && playhead >= endOf(cur())) playhead = 0;
  playing = !playing; lastTick = performance.now();
});
$('#scrub').addEventListener('input', (e) => { playhead = Number(e.target.value); playing = false; });
window.addEventListener('keydown', (e) => {
  if (e.target.closest?.('input, select, textarea, dialog') || e.metaKey || e.ctrlKey) return;
  if (e.key === ' ' && run) { e.preventDefault(); $('#playBtn').click(); }
  if (e.key === 'Escape' && placing) setPlacing(false);
});

/// Every crew's position at the playhead, eased between recorded frames.
function teamAt(t) {
  const frames = cur().frames;
  let lo = 0, hi = frames.length - 1;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (frames[mid][0] <= t) lo = mid; else hi = mid - 1; }
  const a = frames[lo], b = frames[Math.min(lo + 1, frames.length - 1)];
  const k = b[0] > a[0] ? Math.min(1, Math.max(0, (t - a[0]) / (b[0] - a[0]))) : 0;
  return a[1].map((p, i) => {
    const q = b[1][i];
    return { i, x: p[0] + (q[0] - p[0]) * k, y: p[1] + (q[1] - p[1]) * k,
      heading: p[2] + (((q[2] - p[2] + 540) % 360) - 180) * k, status: p[3],
      to: p.length > 4 ? [p[4], p[5]] : null,
      responding: p[3] === 'responding' || p[3] === 'with_casualty', upTo: lo };
  });
}

// ---------------------------------------------------------------- what the commander has been told
// One pixel per cell, tinted by the room's reported status at the playhead. Shared by the plan and 3D.
const ROOM_TINT = { unknown: [24, 131, 75, 46], voice_clear: [217, 119, 6, 60], searched_clear: [0, 0, 0, 0],
  found: [183, 47, 54, 56], unreachable: [90, 100, 95, 70] };
const ROOM_NOTE = { unknown: '', voice_clear: 'called in, no answer', searched_clear: '✓ searched', found: 'casualty here', unreachable: 'no way in' };
const heatTile = document.createElement('canvas');
let tileKey = '';
let roomStatus = [], blockedKnown = new Set();

function updateRooms() {
  if (!run) { tileKey = ''; roomStatus = []; blockedKnown = new Set(); return false; }
  const past = cur().timeline.filter((e) => e.t <= playhead);
  const key = `${active}:${past.length}`;
  if (key === tileKey) return false;
  tileKey = key;
  roomStatus = env.roomList.map(() => 'unknown');
  blockedKnown = new Set();
  for (const e of past) { if (e.door != null) blockedKnown.add(e.door); else roomStatus[e.room] = e.status; }
  heatTile.width = env.cols; heatTile.height = env.rows;
  const g = heatTile.getContext('2d');
  const img = g.createImageData(env.cols, env.rows);
  env.roomOf.forEach((room, cell) => { if (room >= 0) img.data.set(ROOM_TINT[roomStatus[room]], cell * 4); });
  g.putImageData(img, 0, 0);
  return true;
}

// ---------------------------------------------------------------- 2D plan
const canvas = $('#map');
const ctx = canvas.getContext('2d');
let view = null;
const floorLayer = document.createElement('canvas'), wallLayer = document.createElement('canvas');
let layersKey = '';

function plan() { return editing ?? env; }

function resize() {
  const p = plan();
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w || !p) return;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = w * dpr; canvas.height = h * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const width = p.cols * p.cell, depth = p.rows * p.cell, pad = 20;
  const scale = Math.min((w - 2 * pad) / width, (h - 2 * pad) / depth);
  const ox = (w - scale * width) / 2, oy = (h - scale * depth) / 2;
  view = { scale, toPx: (x, y) => [ox + x * scale, oy + y * scale], toRoom: (px, py) => [(px - ox) / scale, (py - oy) / scale] };
  layersKey = '';
}
new ResizeObserver(resize).observe($('#mapWrap'));

function drawLayers() {
  const p = plan();
  const key = `${canvas.width}x${canvas.height}:${p.id ?? 'edit'}:${editing?.version ?? 0}`;
  if (key === layersKey) return;
  layersKey = key;
  const dpr = window.devicePixelRatio || 1;
  for (const layer of [floorLayer, wallLayer]) {
    layer.width = canvas.width; layer.height = canvas.height;
    layer.getContext('2d').setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  const f = floorLayer.getContext('2d'), wl = wallLayer.getContext('2d');
  const size = p.cell * view.scale;
  for (let r = 0; r < p.rows; r++) {
    for (let c = 0; c < p.cols; c++) {
      const ch = p.cells[r][c];
      if (ch === ' ') continue;
      const [x, y] = view.toPx(c * p.cell, r * p.cell);
      // floor under everything; walls, furniture and hazards over the search map
      f.fillStyle = ch === '_' || ch === '~' ? '#e9efeb' : '#fff';
      f.fillRect(x - 0.4, y - 0.4, size + 0.8, size + 0.8);
      const over = { '#': WALL, o: '#c2d6c9', f: '#e4572e', s: 'rgba(95,106,100,.5)', '~': 'rgba(95,106,100,.5)',
        d: editing ? 'rgba(107,79,187,.35)' : null }[ch];
      const bleed = ch === 's' || ch === '~' ? 0 : 0.4;   // see-through cells mustn't overlap, or the seams show
      if (over) { wl.fillStyle = over; wl.fillRect(x - bleed, y - bleed, size + 2 * bleed, size + 2 * bleed); }
    }
  }
}

function label(text, x, y, background, foreground = '#fff') {
  ctx.save();
  ctx.font = '600 10px "Geist", ui-sans-serif, system-ui';
  const width = ctx.measureText(text).width + 12;
  x = Math.max(width / 2 + 4, Math.min(canvas.clientWidth - width / 2 - 4, x));
  y = Math.max(13, y);
  ctx.fillStyle = background;
  ctx.beginPath(); ctx.roundRect(x - width / 2, y - 9, width, 18, 5); ctx.fill();
  ctx.fillStyle = foreground;
  ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.fillText(text, x, y + .5);
  ctx.restore();
}

function personGlyph(x, y, color, dashed = false) {
  ctx.save();
  ctx.translate(x, y);
  ctx.fillStyle = '#fff'; ctx.strokeStyle = color; ctx.lineWidth = 2;
  if (dashed) ctx.setLineDash([3, 3]);
  ctx.beginPath(); ctx.arc(0, 0, 10, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
  ctx.setLineDash([]);
  ctx.fillStyle = color;
  ctx.beginPath(); ctx.arc(0, -3.5, 2.7, 0, Math.PI * 2); ctx.fill();
  ctx.beginPath(); ctx.roundRect(-4.5, .5, 9, 5.5, 3); ctx.fill();
  ctx.restore();
}

function drawEntries(p) {
  for (const e of p.entryPoints || []) {
    const [x, y] = view.toPx(e.x, e.y);
    ctx.save();
    ctx.fillStyle = '#6b4fbb'; ctx.strokeStyle = '#fff'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.roundRect(x - 7, y - 7, 14, 14, 4); ctx.fill(); ctx.stroke();
    ctx.restore();
    label(e.name.toUpperCase(), x, y - 18, '#6b4fbb');
  }
}

function draw2d(team) {
  const p = plan();
  const W = canvas.clientWidth, H = canvas.clientHeight;
  ctx.clearRect(0, 0, W, H);
  drawLayers();
  ctx.drawImage(floorLayer, 0, 0, W, H);
  if (run && !editing) {
    const [ax, ay] = view.toPx(0, 0), [bx, by] = view.toPx(p.cols * p.cell, p.rows * p.cell);
    ctx.save();
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(heatTile, ax, ay, bx - ax, by - ay);
    ctx.restore();
  }
  ctx.drawImage(wallLayer, 0, 0, W, H);
  drawFlames(p);
  if (editing) {   // a grid to draw against
    ctx.strokeStyle = 'rgba(23,55,38,.07)'; ctx.lineWidth = 1; ctx.beginPath();
    const step = Math.max(1, Math.round(1 / p.cell));
    for (let c = 0; c <= p.cols; c += step) { const [x, y0] = view.toPx(c * p.cell, 0), [, y1] = view.toPx(0, p.rows * p.cell); ctx.moveTo(x, y0); ctx.lineTo(x, y1); }
    for (let r = 0; r <= p.rows; r += step) { const [x0, y] = view.toPx(0, r * p.cell), [x1] = view.toPx(p.cols * p.cell, 0); ctx.moveTo(x0, y); ctx.lineTo(x1, y); }
    ctx.stroke();
  }
  ctx.fillStyle = '#597562'; ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
  ctx.font = `500 ${Math.max(10, Math.min(13, view.scale * 0.5))}px "Geist", ui-sans-serif, system-ui`;
  if (editing || !p.roomList) for (const room of p.rooms || []) { const [x, y] = view.toPx(room.x, room.y); ctx.fillText(room.name, x, y); }
  else {
    for (const room of p.roomList) {
      const [x, y] = view.toPx(room.x, room.y);
      const note = run ? ROOM_NOTE[roomStatus[room.id]] : '';
      ctx.fillStyle = '#466653'; ctx.fillText(room.name, x, y - (note ? 7 : 0));
      if (note) {
        ctx.save(); ctx.font = '500 10px "Geist", ui-sans-serif, system-ui';
        ctx.fillStyle = { voice_clear: '#9a5a05', found: RED, unreachable: '#5a645f' }[roomStatus[room.id]] ?? ACCENT;
        ctx.fillText(note, x, y + 7); ctx.restore();
      }
    }
    drawDoors(p);
  }
  drawEntries(p);
  if (editing) return;
  if (batch && batchSize != null && !playing) drawBatchDots();

  if (run && team) {
    // where each rescuer has been
    const frames = cur().frames;
    ctx.lineWidth = 1.5; ctx.lineJoin = 'round';
    for (const a of team) {
      ctx.strokeStyle = 'rgba(24,131,75,.35)';
      ctx.beginPath();
      for (let k = 0; k <= a.upTo; k++) { const [x, y] = view.toPx(frames[k][1][a.i][0], frames[k][1][a.i][1]); if (k) ctx.lineTo(x, y); else ctx.moveTo(x, y); }
      ctx.lineTo(...view.toPx(a.x, a.y));
      ctx.stroke();
    }
    for (const a of team) {
      if (!a.responding) drawCone(ctx, view, a.x, a.y, a.heading, env.fovDeg, env.rangeM * CONE_DRAW_SCALE, 'rgba(24,131,75,0.16)');
      if (a.to) {
        ctx.save();
        ctx.strokeStyle = a.responding ? AMBER : 'rgba(24,131,75,.55)'; ctx.lineWidth = 1.25; ctx.setLineDash([4, 4]);
        ctx.beginPath(); ctx.moveTo(...view.toPx(a.x, a.y)); ctx.lineTo(...view.toPx(a.to[0], a.to[1])); ctx.stroke();
        ctx.restore();
      }
    }
  }
  // the casualty: the operator always knows where; the team doesn't until someone sees them
  const m = run ? cur().metrics : null;
  const found = m?.foundAt != null && playhead >= m.foundAt;
  const v = run ? (referee || found ? run.referee.casualty : null) : casualty;
  if (v) {
    const [x, y] = view.toPx(v.x, v.y);
    const rescued = m?.outcome === 'rescued' && playhead >= m.elapsed - 0.5;
    if (found) {
      const k = (performance.now() / 1100) % 1;
      ctx.strokeStyle = `rgba(183,47,54,${.7 * (1 - k)})`; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.arc(x, y, 13 + k * 22, 0, Math.PI * 2); ctx.stroke();
    }
    personGlyph(x, y, found ? RED : '#597562', !found);
    label(rescued ? 'RESCUED' : found ? 'FOUND' : 'CASUALTY', x, y - 23, found ? RED : '#597562');
  }
  for (const a of team || []) {
    const [x, y] = view.toPx(a.x, a.y);
    const color = a.responding ? AMBER : ACCENT;
    ctx.save();
    ctx.translate(x, y);
    ctx.shadowColor = 'rgba(23,55,38,.16)'; ctx.shadowBlur = 7; ctx.shadowOffsetY = 2;
    ctx.rotate(a.heading * Math.PI / 180);
    ctx.fillStyle = color;
    ctx.beginPath(); ctx.moveTo(0, -16); ctx.lineTo(5, -8); ctx.lineTo(-5, -8); ctx.closePath(); ctx.fill();
    ctx.rotate(-a.heading * Math.PI / 180);
    ctx.strokeStyle = '#fff'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(0, 0, 10, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    ctx.shadowColor = 'transparent';
    ctx.fillStyle = '#fff'; ctx.font = '600 10px "Geist Mono", ui-monospace, monospace';
    ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
    ctx.fillText(String(a.i + 1), 0, .5);
    ctx.restore();
  }
}

/// Blocked doorways: the ones crews have run into, plus (referee only) the ones nobody has found yet.
function drawDoors(p) {
  if (!run) return;
  for (const door of p.doors) {
    const known = blockedKnown.has(door.id);
    if (!known && !(referee && run.referee.blockedDoors.includes(door.id))) continue;
    const [x, y] = view.toPx(door.x, door.y);
    const r = Math.max(7, p.cell * view.scale * 1.1);
    ctx.save();
    ctx.strokeStyle = RED; ctx.lineWidth = 2.5; ctx.lineCap = 'round';
    if (!known) { ctx.globalAlpha = .55; ctx.setLineDash([3, 4]); }
    ctx.beginPath(); ctx.moveTo(x - r, y - r); ctx.lineTo(x + r, y + r); ctx.moveTo(x + r, y - r); ctx.lineTo(x - r, y + r); ctx.stroke();
    ctx.restore();
    if (known) label('BLOCKED', x, y - r - 12, RED);
  }
}

/// Fire flickers: each burning cell gets a brighter core that breathes out of step with its neighbors.
let hazardCells = null, hazardKey = '';
function drawFlames(p) {
  const key = `${p.id ?? 'edit'}:${editing?.version ?? 0}`;
  if (!hazardCells || key !== hazardKey) {
    hazardKey = key; hazardCells = [];
    p.cells.forEach((row, r) => row.forEach((ch, c) => { if (ch === 'f') hazardCells.push([r, c]); }));
  }
  if (!hazardCells.length) return;
  const t = performance.now() / 260, size = p.cell * view.scale;
  for (const [r, c] of hazardCells) {
    const [x, y] = view.toPx((c + .5) * p.cell, (r + .5) * p.cell);
    const k = .5 + .5 * Math.sin(t + r * 1.7 + c * 2.3);
    ctx.fillStyle = `rgba(255,${Math.round(170 + 60 * k)},60,${.45 + .4 * k})`;
    ctx.beginPath(); ctx.arc(x, y, size * (.22 + .2 * k), 0, Math.PI * 2); ctx.fill();
  }
}

function hint(text) { $('#mapHint').textContent = text; $('#mapHint').hidden = !text; }

function roomPoint(e) {
  const r = canvas.getBoundingClientRect();
  return view.toRoom(e.clientX - r.left, e.clientY - r.top);
}

canvas.addEventListener('click', (e) => {
  if (!placing || !view || editing) return;
  const [x, y] = roomPoint(e);
  const c = Math.floor(x / env.cell), r = Math.floor(y / env.cell);
  if (env.roomOf[r * env.cols + c] < 0) { hint('That isn’t open floor. Click somewhere a person could be.'); return; }
  casualty = { x: (c + .5) * env.cell, y: (r + .5) * env.cell };
  run = null; renderRun();
  setPlacing(false);
});

// ---------------------------------------------------------------- frame loop
function frame(now) {
  requestAnimationFrame(frame);
  if (!plan() || !view) return;
  if (run && playing) {
    const end = endOf(cur());
    playhead = Math.min(end, playhead + (now - lastTick) / 1000 * Number($('#speed').value));
    if (playhead >= end) playing = false;
  }
  lastTick = now;
  $('#playBtn').textContent = playing ? 'Pause' : 'Play';
  canvas.style.cursor = placing || editing ? 'crosshair' : 'default';
  const team = run && !editing ? teamAt(playhead) : null;
  const heatChanged = updateRooms();
  if (run) {
    $('#scrub').value = String(playhead);
    $('#clock').textContent = `${fmtClock(playhead)} / ${fmtClock(endOf(cur()))}`;
    for (const row of document.querySelectorAll('#log .ev')) row.classList.toggle('future', cur().reports[Number(row.dataset.ev)].t > playhead);
  }
  if (mode === '3d' && scene3d && !editing) {
    const m = run ? cur().metrics : null;
    const found = m?.foundAt != null && playhead >= m.foundAt;
    scene3d.render({
      team, heat: run ? heatTile : null, heatChanged,
      casualty: run ? (referee || found ? run.referee.casualty : null) : casualty,
      found, rescued: m?.outcome === 'rescued' && playhead >= m.elapsed - 0.5,
    });
  } else {
    draw2d(team);
  }
}

// ---------------------------------------------------------------- 3D
async function setMode(next) {
  if (editing && next === '3d') return;
  mode = next;
  for (const b of document.querySelectorAll('#viewModes button')) b.setAttribute('aria-pressed', String(b.dataset.mode === mode));
  $('#map').hidden = mode === '3d';
  $('#scene3d').hidden = mode !== '3d';
  if (mode !== '3d') { scene3d?.hide(); hint(''); resize(); return; }
  if (placing) setPlacing(false);
  if (!scene3d) {
    hint('Loading 3D…');
    scene3dLoading ??= import('/web/sim-scene3d.js').then(({ createSimScene }) => {
      scene3d = createSimScene($('#scene3d'));
      return scene3d;
    }).catch((error) => { scene3dLoading = null; throw error; });
    try { await scene3dLoading; } catch { hint('3D is unavailable. Check WebGL and your internet connection.'); mode = '2d'; return setMode('2d'); }
    hint('');
  }
  if (mode === '3d') { scene3d.setEnv(env); scene3d.show(); tileKey = ''; }
}
$('#viewModes').addEventListener('click', (e) => { const b = e.target.closest('[data-mode]'); if (b) setMode(b.dataset.mode); });

// ---------------------------------------------------------------- compare team sizes
const sizes = new Set([1, 2, 3, 4, 6]);
function renderChips() {
  $('#sizeChips').replaceChildren(...[1, 2, 3, 4, 5, 6, 8, 10, 12].map((n) => {
    const b = document.createElement('button');
    b.type = 'button'; b.textContent = n; b.setAttribute('aria-pressed', String(sizes.has(n)));
    b.setAttribute('aria-label', `${n} rescuer${n === 1 ? '' : 's'}`);
    b.addEventListener('click', () => { if (sizes.has(n)) sizes.delete(n); else if (sizes.size < 8) sizes.add(n); renderChips(); });
    return b;
  }));
  $('#batchBtn').disabled = !sizes.size;
}
renderChips();

$('#batchBtn').addEventListener('click', async () => {
  if (batchJob) { await api(`/api/sim/batch/${batchJob}`, { method: 'DELETE' }); return; }
  const { victim, rescuers, ...base } = params();
  $('#batchProgress').hidden = false; $('#batchBar').value = 0; $('#batchMsg').textContent = 'Starting…';
  $('#batchBtn').textContent = 'Cancel'; $('#batchBtn').classList.remove('primary');
  try {
    const job = await postJson('/api/sim/batch', { ...base, teamSizes: [...sizes], runs: Number($('#batchRuns').value) || 40 });
    batchJob = job.job;
    for (;;) {
      await new Promise((resolve) => setTimeout(resolve, 400));
      const status = await api(`/api/sim/batch/${batchJob}`);
      $('#batchBar').max = status.total; $('#batchBar').value = status.done;
      $('#batchMsg').textContent = `${status.done} of ${status.total} runs`;
      if (status.status === 'running') continue;
      if (status.status === 'done') { batch = status.result; batchSize = null; $('#batchProgress').hidden = true; renderBatch(); }
      else $('#batchMsg').textContent = status.status === 'cancelled' ? 'Cancelled.' : `Couldn’t finish: ${status.error}`;
      break;
    }
  } catch (error) {
    $('#batchMsg').textContent = error.message;
  } finally {
    batchJob = null;
    $('#batchBtn').textContent = 'Run comparison'; $('#batchBtn').classList.add('primary');
  }
});

function niceMax(v) {
  const step = [5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600].find((s) => v / s <= 5) ?? 3600;
  return { max: Math.ceil(v / step) * step, step };
}
const fmtSeconds = (s) => (s < 60 ? `${Math.round(s)} s` : `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, '0')}`);

function renderBatch() {
  const out = $('#batchOut');
  out.hidden = !batch;
  if (!batch) { out.replaceChildren(); return; }
  const rowsData = batch.sizes;
  const { max, step } = niceMax(Math.max(...rowsData.map((s) => s.find.p90)));
  const W = 680, left = 96, right = 64, rowH = 34, top = 8, bottom = 26;
  const H = top + rowsData.length * rowH + bottom;
  const x = (v) => left + (W - left - right) * Math.min(1, v / max);
  let svg = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Time to find the casualty by team size: median and the range 8 in 10 runs fell in">`;
  for (let v = 0; v <= max; v += step) {
    svg += `<line class="grid-line" x1="${x(v)}" x2="${x(v)}" y1="${top}" y2="${H - bottom}"/>`
      + `<text class="axis" x="${x(v)}" y="${H - 8}" text-anchor="middle">${fmtSeconds(v)}</text>`;
  }
  rowsData.forEach((s, i) => {
    const cy = top + i * rowH + rowH / 2;
    svg += `<g data-size="${s.rescuers}" class="${s.rescuers === batchSize ? 'on' : ''}">
      <rect class="rowbg" x="0" y="${cy - rowH / 2}" width="${W}" height="${rowH}" rx="6"/>
      <text class="name" x="8" y="${cy + 4}">${s.rescuers} rescuer${s.rescuers === 1 ? '' : 's'}</text>
      <rect class="band" x="${x(s.find.p10)}" y="${cy - 5}" width="${Math.max(2, x(s.find.p90) - x(s.find.p10))}" height="10" rx="4"/>
      <circle class="median" cx="${x(s.find.median)}" cy="${cy}" r="6"/>
      <text class="val" x="${W - 8}" y="${cy + 4}" text-anchor="end">${fmtSeconds(s.find.median)}</text>
      <rect class="hit" x="0" y="${cy - rowH / 2}" width="${W}" height="${rowH}"/></g>`;
  });
  svg += '</svg>';
  const pct = (v) => `${Math.round(v * 100)}%`;
  const table = `<table class="bt"><thead><tr><th>Team</th><th>Found</th><th>Find, median</th><th>8 in 10 runs</th><th>Rescue, median</th><th>Searched at find</th><th>Walked each</th></tr></thead><tbody>${
    rowsData.map((s) => `<tr data-size="${s.rescuers}" class="${s.rescuers === batchSize ? 'on' : ''}"><td>${s.rescuers}</td><td>${pct(s.foundRate)}</td><td>${fmtSeconds(s.find.median)}</td>
      <td>${fmtSeconds(s.find.p10)} – ${fmtSeconds(s.find.p90)}</td><td>${fmtSeconds(s.rescue.median)}</td>
      <td>${s.searchedAtFind == null ? '–' : pct(s.searchedAtFind)}</td><td>${Math.round(s.walkedPerRescuerM)} m</td></tr>`).join('')}</tbody></table>`;
  out.innerHTML = `<h3>Time to find the casualty</h3>
    <div class="sub">Median, and the range 8 in 10 runs fell in · ${batch.runsPerSize} runs per team size, same casualties for every size · a run that times out counts as the full ${Math.round(batch.maxTime / 60)} min</div>
    <div class="chart" id="batchChart">${svg}<div class="tip" hidden></div></div>${table}
    <div class="scale" id="dotScale" ${batchSize == null ? 'hidden' : ''}>On the plan: where the casualty was, for the ${batchSize}-rescuer runs ·
      quick <i></i> slow · <span class="x">✕</span> never found</div>
    <div class="hint faint" style="font-size:12px;margin-top:8px" ${batchSize != null ? 'hidden' : ''}>Click a team size to see on the plan where casualties took longest to find.</div>`;
  const chart = $('#batchChart'), tip = chart.querySelector('.tip');
  chart.addEventListener('mousemove', (e) => {
    const g = e.target.closest('[data-size]');
    if (!g) { tip.hidden = true; return; }
    const s = rowsData.find((r) => r.rescuers === Number(g.dataset.size));
    tip.innerHTML = `<b>${s.rescuers} rescuer${s.rescuers === 1 ? '' : 's'}</b> · found in ${pct(s.foundRate)} of runs<br>`
      + `Find: median ${fmtSeconds(s.find.median)} · 8 in 10 within ${fmtSeconds(s.find.p10)} – ${fmtSeconds(s.find.p90)}<br>Rescue: median ${fmtSeconds(s.rescue.median)}`;
    const box = chart.getBoundingClientRect();
    tip.style.left = `${Math.max(140, Math.min(box.width - 140, e.clientX - box.left))}px`; tip.style.top = `${e.clientY - box.top}px`;
    tip.hidden = false;
  });
  chart.addEventListener('mouseleave', () => { tip.hidden = true; });
  out.onclick = (e) => {
    const g = e.target.closest('[data-size]');
    if (!g) return;
    const n = Number(g.dataset.size);
    batchSize = batchSize === n ? null : n;
    if (batchSize != null) { playing = false; if (mode === '3d') setMode('2d'); }
    renderBatch();
  };
}

/// Where the casualty was in each run of the selected team size, shaded by how long the find took.
function drawBatchDots() {
  const rows = batch.runs.filter((r) => r.rescuers === batchSize);
  const slowest = Math.max(1, ...rows.map((r) => r.foundAt ?? 0));
  for (const r of rows) {
    const [x, y] = view.toPx(r.x, r.y);
    ctx.save();
    if (r.foundAt == null) {
      ctx.strokeStyle = RED; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.moveTo(x - 4, y - 4); ctx.lineTo(x + 4, y + 4); ctx.moveTo(x + 4, y - 4); ctx.lineTo(x - 4, y + 4); ctx.stroke();
    } else {
      const k = Math.sqrt(r.foundAt / slowest);  // one hue, light → dark: #cfead9 → #0d4a2a
      ctx.fillStyle = `rgb(${Math.round(207 - 194 * k)},${Math.round(234 - 160 * k)},${Math.round(217 - 175 * k)})`;
      ctx.strokeStyle = '#fff'; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.arc(x, y, 6, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
    }
    ctx.restore();
  }
}

// ---------------------------------------------------------------- new environment + plan editor
$('#envNew').addEventListener('click', () => $('#newDialog').showModal());
$('#newClose').addEventListener('click', () => $('#newDialog').close());

function startEditing(state) {
  editing = { version: 0, entryPoints: [], rooms: [], ...state };
  editing.rows = editing.cells.length; editing.cols = editing.cells[0].length;
  playing = false; run = null; renderRun();
  if (mode === '3d') setMode('2d');
  $('#editBar').hidden = false;
  $('#scanTools').hidden = !editing.scan;
  $('#transport').hidden = true;
  $('#editName').value = state.name || '';
  $('#mapTitle').textContent = 'Drawing a floor plan';
  $('#envSize').textContent = `${editing.cols * editing.cell} × ${editing.rows * editing.cell} m`;
  editMessage(editing.scan ? 'Traced from the scan. Close gaps in the walls, paint a Door across every doorway, and mark where the team comes in.'
    : 'Drag to draw. Paint a Door across every doorway (that is what divides the plan into rooms), and mark at least one entry.');
  setTool(editing.scan ? 'entry' : '#');
  resize();
}

function stopEditing() {
  editing = null;
  $('#editBar').hidden = true; $('#editMsg').hidden = true; $('#transport').hidden = false;
  $('#mapTitle').textContent = 'Floor plan';
  if (env) $('#envSize').textContent = `${env.width} × ${env.depth} m · ${env.floorM2} m² of floor`;
  resize();
}

function editMessage(text, error = false) {
  $('#editMsg').hidden = !text; $('#editMsg').textContent = text; $('#editMsg').classList.toggle('err', error);
}

let tool = '#';
function setTool(next) {
  tool = next;
  for (const b of document.querySelectorAll('#tools button')) b.setAttribute('aria-pressed', String(b.dataset.tool === tool));
}
$('#tools').addEventListener('click', (e) => { const b = e.target.closest('[data-tool]'); if (b) setTool(b.dataset.tool); });

$('#newCopy').addEventListener('click', () => {
  $('#newDialog').close();
  startEditing({ name: `${env.name} (edited)`, cell: env.cell, cells: env.cells.map((row) => row.map((ch) => (ch === '_' ? '.' : ch))),
    entryPoints: env.entryPoints.map((e) => ({ ...e })), rooms: env.rooms, wallHeightM: env.wallHeightM });
});
$('#newBlank').addEventListener('click', () => {
  $('#newDialog').close();
  const cols = 40, rows = 30;
  const cells = Array.from({ length: rows }, (_, r) => Array.from({ length: cols }, (_, c) => (r === 0 || c === 0 || r === rows - 1 || c === cols - 1 ? '#' : '.')));
  startEditing({ name: '', cell: 0.5, cells });
});

let painting = false;
function paint(e) {
  const [x, y] = roomPoint(e);
  const c0 = Math.floor(x / editing.cell), r0 = Math.floor(y / editing.cell);
  const size = Math.max(1, Math.min(8, Number($('#brush').value) || 1)), from = -Math.floor((size - 1) / 2);
  for (let dr = from; dr < from + size; dr++) for (let dc = from; dc < from + size; dc++) {
    const r = r0 + dr, c = c0 + dc;
    if (r < 0 || c < 0 || r >= editing.rows || c >= editing.cols) continue;
    // hazards fill open floor: a fire brushed along a wall doesn't knock the wall down
    if ((tool === 'f' || tool === 's') && !'.fsd'.includes(editing.cells[r][c])) continue;
    editing.cells[r][c] = tool;
  }
  editing.version++;
}
canvas.addEventListener('mousedown', (e) => {
  if (!editing || !view) return;
  e.preventDefault();
  if (tool === 'entry') {
    const [x, y] = roomPoint(e);
    const near = editing.entryPoints.findIndex((p) => Math.hypot(p.x - x, p.y - y) * view.scale < 12);
    if (near >= 0) editing.entryPoints.splice(near, 1);
    else if (x >= 0 && y >= 0 && x <= editing.cols * editing.cell && y <= editing.rows * editing.cell) {
      editing.entryPoints.push({ name: `Entry ${editing.entryPoints.length + 1}`, x: Number(x.toFixed(2)), y: Number(y.toFixed(2)) });
    }
    return;
  }
  painting = true; paint(e);
});
window.addEventListener('mousemove', (e) => { if (painting && editing) paint(e); });
window.addEventListener('mouseup', () => { painting = false; });

$('#editCancel').addEventListener('click', stopEditing);
$('#editSave').addEventListener('click', async () => {
  const name = $('#editName').value.trim();
  if (!name) { editMessage('Give it a name first.', true); $('#editName').focus(); return; }
  if (!editing.entryPoints.length) { editMessage('Mark where the team comes in: pick Entry, then click a doorway.', true); return; }
  $('#editSave').disabled = true;
  try {
    const scan = editing.scan;
    const saved = await postJson('/api/sim/envs', {
      name, cell: editing.cell, grid: editing.cells.map((row) => row.join('')), entries: editing.entryPoints, rooms: editing.rooms,
      wallHeightM: editing.wallHeightM, source: scan ? 'scan' : 'drawn',
      scan: scan ? { scale: scan.scale, rotateYDeg: scan.rotateYDeg, offset: scan.offset } : undefined,
    });
    if (scan) {
      editMessage('Uploading the scan…');
      await api(`/api/sim/envs/${saved.id}/scan`, { method: 'PUT', headers: { 'Content-Type': 'model/gltf-binary' }, body: scan.file });
    }
    stopEditing();
    await loadEnvs(saved.id);
  } catch (error) {
    editMessage(error.message, true);
  } finally {
    $('#editSave').disabled = false;
  }
});

// ---- from a 3D scan
$('#newScan').addEventListener('click', () => $('#scanFile').click());
$('#scanFile').addEventListener('change', async () => {
  const file = $('#scanFile').files[0];
  $('#scanFile').value = '';
  if (!file) return;
  $('#newDialog').close();
  hint('Reading the scan…');
  try {
    const [THREE, { GLTFLoader }, { DRACOLoader }] = await Promise.all([
      import('three'), import('three/addons/loaders/GLTFLoader.js'), import('three/addons/loaders/DRACOLoader.js')]);
    const loader = new GLTFLoader();
    const draco = new DRACOLoader();
    draco.setDecoderPath('https://cdn.jsdelivr.net/npm/three@0.170.0/examples/jsm/libs/draco/gltf/');
    loader.setDRACOLoader(draco);
    const url = URL.createObjectURL(file);
    let gltf;
    try { gltf = await loader.loadAsync(url); } finally { URL.revokeObjectURL(url); }
    const scan = { file, root: gltf.scene, THREE, scale: 1, rotateYDeg: 0 };
    const traced = trace(scan, Number($('#scanCell').value) || 0.25);
    startEditing({ name: file.name.replace(/\.glb$/i, ''), ...traced, scan });
  } catch (error) {
    alert(`Couldn’t use that scan: ${error.message}`);
  } finally {
    hint('');
  }
});

function trace(scan, cell) {
  scan.root.scale.setScalar(scan.scale);
  scan.root.rotation.y = scan.rotateYDeg * Math.PI / 180;
  const plan = tracePlan(samplePoints(scan.root, scan.THREE, cell / 2), { cell });
  scan.offset = plan.offset.map((v) => Number(v.toFixed(3)));
  return { cell, cells: plan.grid.map((row) => [...row]) };
}

$('#scanRetrace').addEventListener('click', () => {
  if (!editing?.scan) return;
  if (editing.version && !confirm('Retracing replaces the walls you’ve drawn. Go ahead?')) return;
  const scan = editing.scan;
  scan.scale = Number($('#scanScale').value) || 1;
  scan.rotateYDeg = Number($('#scanTurn').value) || 0;
  try {
    const traced = trace(scan, Number($('#scanCell').value) || 0.25);
    Object.assign(editing, traced, { rows: traced.cells.length, cols: traced.cells[0].length, entryPoints: [], version: 0 });
    editMessage(`Retraced: ${editing.cols * editing.cell} × ${editing.rows * editing.cell} m.`);
    resize();
  } catch (error) { editMessage(error.message, true); }
});

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

loadEnvs().catch((error) => { $('#envNote').textContent = `Couldn’t load environments: ${error.message}`; });
requestAnimationFrame(frame);
