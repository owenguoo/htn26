import { freshSighting } from '/web/inference-ui.js';
import { makeView, drawRoom, drawCone } from '/web/room.js';

const $ = (s) => document.querySelector(s);
const params = new URLSearchParams(location.search);
const THUMB_FPS = Number(params.get('thumb_fps')) || 10;

const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch {} },
};

let room = null;
let ws = null;
const phones = new Map();   // id → latest summary from the hub
const tiles = new Map();    // id → { el, img, url, ... }
const drawn = new Map();    // id → smoothed heading for the map
let hoverId = null;
let coverage = null;        // look-count grid from the hub
let planner = null;         // sector assignments + log from the hub
let target = null;          // mock candidate from the hub
let search = null;
let searchTime = 0;
let searchReceived = 0;
let phase = null;           // show phase from the hub
let pings = [];             // active pings from the hub
let sightings = [];         // possible sightings from detections
let dragPos = null;         // candidate position while the operator drags it
let frameCount = 0;         // thumbnails received, for a sanity check in the console

// ---------------------------------------------------------------- socket
function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws/dashboard?thumb_fps=${THUMB_FPS}`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => $('#pulse').classList.add('ok');
  ws.onclose = () => {
    search = null;
    renderTiles();
    $('#pulse').classList.remove('ok');
    setTimeout(connect, 1000);
  };
  ws.onmessage = (ev) => {
    if (typeof ev.data === 'string') onJson(JSON.parse(ev.data));
    else onFrame(ev.data);
  };
}

function onJson(msg) {
  if (msg.type === 'hello') {
    room = msg.room;
    $('#roomName').textContent = `${room.name} · ${room.width}×${room.depth} m`;
    setJoinUrl(store.get('swarm.joinUrl') || msg.joinUrl);
    resizeMap();
  } else if (msg.type === 'state') {
    search = msg.search;
    searchTime = msg.t;
    searchReceived = performance.now();
    coverage = msg.coverage || null;
    planner = msg.planner || null;
    target = msg.target || null;
    phase = msg.phase || null;
    pings = msg.pings || [];
    sightings = msg.sightings || [];
    renderPlanner();
    const seen = new Set();
    for (const p of msg.phones) {
      phones.set(p.id, p);
      seen.add(p.id);
    }
    for (const id of [...phones.keys()]) if (!seen.has(id)) phones.delete(id);
    renderTiles();
    renderStats();
    if (gpsView) updateGps();
  }
}

function onFrame(buf) {
  const view = new DataView(buf);
  const n = view.getUint32(0);
  const header = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 4, n)));
  const tile = tiles.get(header.phoneId);
  if (!tile) return;
  const url = URL.createObjectURL(new Blob([new Uint8Array(buf, 4 + n)], { type: 'image/jpeg' }));
  if (tile.pending) URL.revokeObjectURL(tile.pending); // superseded before it finished loading
  tile.pending = url;
  tile.img.onload = () => {
    if (tile.url) URL.revokeObjectURL(tile.url);
    tile.url = url;
    tile.pending = null;
  };
  tile.img.src = url;
  tile.placeholder.style.display = 'none';
  frameCount++;
}

function send(msg) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

// ---------------------------------------------------------------- join QR
function setJoinUrl(url) {
  $('#joinUrl').value = url;
  $('#qr').src = `/api/qr.svg?data=${encodeURIComponent(url)}`;
}
$('#joinUrl').addEventListener('change', (e) => {
  const url = e.target.value.trim();
  store.set('swarm.joinUrl', url);
  setJoinUrl(url);
});

// ---------------------------------------------------------------- tiles
function renderTiles() {
  const feeds = $('#feeds');
  for (const [id, t] of tiles) {
    if (!phones.has(id)) {
      t.el.remove();
      if (t.url) URL.revokeObjectURL(t.url);
      tiles.delete(id);
    }
  }
  for (const p of phones.values()) {
    let t = tiles.get(p.id);
    if (!t) t = createTile(p);
    t.el.style.setProperty('--c', p.color);
    t.el.classList.toggle('offline', !p.connected);
    if (p.hidden) {  // the operator hid this feed; the hub stops sending its frames here
      t.img.removeAttribute('src');
      t.placeholder.textContent = 'Hidden by operator';
      t.placeholder.style.display = '';
    } else if (t.placeholder.textContent === 'Hidden by operator') {
      t.placeholder.textContent = 'waiting for video…';
    }
    t.el.classList.toggle('hl', hoverId === p.id);
    t.who.innerHTML = `<i>#${p.index}</i> ${escapeHtml(p.name || (p.sim ? 'Sim' : 'Phone'))}`;
    const hd = p.pose?.heading;
    t.nums.textContent = [
      `${p.fps.toFixed(1)}fps`,
      p.latencyMs == null ? null : `${p.latencyMs}ms`,
      hd == null ? null : `${Math.round(hd)}°`,
      p.gps ? `GPS ±${Math.round(p.gps.accuracy)}m` : null,
    ].filter(Boolean).join(' · ');
    const tags = [];
    if (search?.sightings?.some(s => s.phoneId === p.id && s.matched && freshSighting(s, search, searchTime, searchReceived, performance.now()))) tags.push(['LIKELY SIGHTING', 'warn']);
    if (p.sim) tags.push(['SIM', '']);
    else if (p.device) tags.push([p.device.toUpperCase(), '']);
    if (!p.connected) tags.push(['OFFLINE', 'bad']);
    else if (p.stale) tags.push(['STALE', 'warn']);
    if (p.pitch != null && Math.abs(p.pitch) > 65) tags.push([p.pitch < 0 ? 'FLOOR' : 'CEILING', 'warn']); // not counted as coverage
    if (target?.foundBy === p.id) tags.push(['FOUND IT', 'bad']);
    if (target?.responders && p.id in target.responders) {
      tags.push(target.responders[p.id] ? ['ARRIVED', 'ok'] : ['RESPONDING', 'bad']);
    }
    const job = planner?.assignments?.[p.id];
    if (job) tags.push([`→ ${job.sector}`, job.onTarget ? 'ok' : 'warn']);
    if (p.pose?.source === 'slam') tags.push(['SLAM', 'ok']);
    if (!p.pose) tags.push(['NO SEAT', 'warn']);
    else if (!p.sim && !p.calibrated && p.pose.source === 'seat') tags.push(['UNCAL', 'warn']);
    t.tags.innerHTML = tags.map(([s, c]) => `<span class="tag ${c}">${s}</span>`).join('');
    const cap = t.el.querySelector('.cap');
    cap.textContent = p.caption ? p.caption.text : p.speaking ? '🎙 …' : '';
    cap.classList.toggle('on', !!(p.caption || p.speaking));
  }
  // keep tiles in join order
  const ordered = [...phones.values()].sort((a, b) => a.index - b.index);
  ordered.forEach((p, i) => {
    const el = tiles.get(p.id).el;
    if (feeds.children[i] !== el) feeds.insertBefore(el, feeds.children[i] || null);
  });
  let empty = feeds.querySelector('.empty');
  if (!phones.size && !empty) {
    empty = document.createElement('div');
    empty.className = 'empty';
    empty.innerHTML = '<b>Waiting for phones</b>Scan the QR code, or run the simulator.';
    feeds.appendChild(empty);
  } else if (phones.size && empty) {
    empty.remove();
  }
  // shrink tiles as the swarm grows
  const n = phones.size;
  feeds.style.setProperty('--tile', n > 36 ? '120px' : n > 16 ? '150px' : n > 6 ? '190px' : '260px');
  $('#feedCount').textContent = n;
}

function createTile(p) {
  const el = document.createElement('div');
  el.className = 'tile';
  el.innerHTML = `<img alt=""><div class="placeholder">waiting for video…</div><div class="bar"></div>
    <div class="tags"></div><div class="cap"></div><div class="meta"><div class="who"></div><div class="nums"></div></div>`;
  const t = {
    el, img: el.querySelector('img'), placeholder: el.querySelector('.placeholder'),
    who: el.querySelector('.who'), nums: el.querySelector('.nums'), tags: el.querySelector('.tags'), url: null,
  };
  el.addEventListener('mouseenter', () => { hoverId = p.id; });
  el.addEventListener('mouseleave', () => { if (hoverId === p.id) hoverId = null; });
  tiles.set(p.id, t);
  $('#feeds').appendChild(el);
  return t;
}


function renderStats() {
  const live = [...phones.values()].filter((p) => p.connected);
  $('#sLive').textContent = live.length;
  $('#sPlaced').textContent = live.filter((p) => p.pose).length;
  $('#sFps').textContent = live.reduce((s, p) => s + p.fps, 0).toFixed(1);
  const lats = live.map((p) => p.latencyMs).filter((x) => x != null).sort((a, b) => a - b);
  $('#sLat').textContent = lats.length ? `${lats[Math.floor(lats.length / 2)]}ms` : '–';
  $('#sSearched').textContent = coverage ? `${Math.round(coverage.searched * 100)}%` : '–';
  const secs = target ? (target.searchMs / 1000).toFixed(1) : null;
  $('#sCand').textContent = !target ? '–' : target.foundBy ? `FOUND ${secs}s` : `Searching ${Math.floor(secs)}s`;
  $('#candStat').classList.toggle('found', !!target?.foundBy);
  $('#candBtn').textContent = target ? 'Remove candidate' : 'Add candidate';
  const unplaced = live.filter((p) => !p.pose).length;
  $('#legend').innerHTML = [
    `<span><i class="sw" style="background:${heatColor(0)}"></i>Ruled out</span>`,
    `<span><i class="sw" style="background:${heatColor(0.6)}"></i>Possible</span>`,
    `<span><i class="sw" style="background:${heatColor(1)}"></i>Most likely</span>`,
    '<span>Cone = camera view (55° FOV)</span>',
    unplaced ? `<span style="color:var(--warn)">${unplaced} phone${unplaced > 1 ? 's' : ''} not placed yet</span>` : '',
  ].join('');
}

// ---------------------------------------------------------------- map
const canvas = $('#map');
const ctx = canvas.getContext('2d');
let view = null;

function resizeMap() {
  const wrap = $('#mapWrap');
  if (!canvas.clientWidth || !canvas.clientHeight) return; // hidden (GPS tab) or not laid out yet
  const dpr = window.devicePixelRatio || 1;
  canvas.width = wrap.clientWidth * dpr;
  canvas.height = wrap.clientHeight * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  if (room) view = makeView(room, wrap.clientWidth, wrap.clientHeight, 24);
}
new ResizeObserver(resizeMap).observe($('#mapWrap'));

// ---- candidate: drag it around the floor plan
let lastDragSend = 0;
function candidatePx() {
  return null; // the audience screen never shows (or lets anyone drag) the hidden candidate; use /console
}
function roomPoint(e) {
  const r = canvas.getBoundingClientRect();
  const [x, y] = view.toRoom(e.clientX - r.left, e.clientY - r.top);
  return {
    x: Math.max(-room.width / 2, Math.min(room.width / 2, x)),
    y: Math.max(0, Math.min(room.depth, y)),
  };
}
canvas.addEventListener('mousedown', (e) => {
  const c = view && candidatePx();
  if (!c) return;
  const r = canvas.getBoundingClientRect();
  if (Math.hypot(c[0] - (e.clientX - r.left), c[1] - (e.clientY - r.top)) <= 16) {
    dragPos = roomPoint(e);
    e.preventDefault();
  }
});
window.addEventListener('mousemove', (e) => {
  if (!dragPos) return;
  dragPos = roomPoint(e);
  const now = performance.now();
  if (now - lastDragSend > 80) {
    lastDragSend = now;
    send({ type: 'target', ...dragPos });
  }
});
window.addEventListener('mouseup', () => {
  if (!dragPos) return;
  send({ type: 'target', ...dragPos });
  dragPos = null;
});
$('#candBtn').addEventListener('click', () => {
  if (target) send({ type: 'target', remove: true });
  else send({ type: 'target', x: 0, y: room.depth / 2, responders: Number($('#respN').value) });
});
$('#respN').addEventListener('change', (e) => send({ type: 'target', responders: Number(e.target.value) }));

function drawSightings() {
  if (target?.foundBy) return;
  for (const sg of sightings) {
    if (sg.confidence < 0.4) continue;
    const [x, y] = view.toPx(sg.x, sg.y);
    const k = (performance.now() / 700) % 1;
    ctx.save();
    ctx.strokeStyle = '#ff5d73';
    ctx.lineWidth = 2;
    ctx.setLineDash([6, 5]);
    ctx.lineDashOffset = -k * 11;
    ctx.beginPath(); ctx.arc(x, y, 16, 0, Math.PI * 2); ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = '#ff5d73';
    ctx.font = '800 12px ui-sans-serif, system-ui';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(`POSSIBLE ${Math.round(sg.confidence * 100)}%`, x, y - 26);
    ctx.restore();
  }
}

// The audience only sees evidence: the hidden candidate is never drawn, only the confirmed find.
function drawCandidate() {
  if (!target?.foundBy || !target.fix) return;
  const t = { x: target.fix[0], y: target.fix[1] };
  const [cx, cy] = view.toPx(t.x, t.y);
  ctx.save();
  // responders: line to the candidate with distance
  for (const [pid, arrived] of Object.entries(target.responders || {})) {
    const p = phones.get(pid);
    if (!p?.pose) continue;
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    ctx.strokeStyle = arrived ? '#7ae582' : '#ff5d73';
    ctx.lineWidth = 2;
    ctx.setLineDash(arrived ? [] : [6, 5]);
    ctx.beginPath(); ctx.moveTo(px, py); ctx.lineTo(cx, cy); ctx.stroke();
    ctx.setLineDash([]);
    const d = Math.hypot(p.pose.x - t.x, p.pose.y - t.y);
    ctx.fillStyle = ctx.strokeStyle;
    ctx.font = '700 11px ui-monospace, monospace';
    ctx.textAlign = 'center';
    ctx.fillText(arrived ? '✓' : `${d.toFixed(1)} m`, (px + cx) / 2, (py + cy) / 2 - 6);
  }
  if (target.foundBy) {
    const pulse = (performance.now() / 900) % 1;
    ctx.strokeStyle = `rgba(255,93,115,${1 - pulse})`;
    ctx.lineWidth = 3;
    ctx.beginPath(); ctx.arc(cx, cy, 10 + pulse * 28, 0, Math.PI * 2); ctx.stroke();
    ctx.fillStyle = '#ff5d73';
    ctx.beginPath(); ctx.arc(cx, cy, 10, 0, Math.PI * 2); ctx.fill();
    const finder = phones.get(target.foundBy);
    ctx.font = '800 12px ui-sans-serif, system-ui';
    ctx.textAlign = 'center';
    const sure = target.confidence != null ? ` · ${Math.round(target.confidence * 100)}%` : '';
    ctx.fillText(`FOUND by #${finder?.index ?? '?'}${sure}`, cx, cy - 18);
  }
  ctx.restore();
}

canvas.addEventListener('mousemove', (e) => {
  if (!view) return;
  const r = canvas.getBoundingClientRect();
  const c = candidatePx();
  canvas.style.cursor = dragPos ? 'grabbing'
    : c && Math.hypot(c[0] - (e.clientX - r.left), c[1] - (e.clientY - r.top)) <= 16 ? 'grab' : '';
  let best = null, bestD = 14;
  for (const p of phones.values()) {
    if (!p.pose) continue;
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    const d = Math.hypot(px - (e.clientX - r.left), py - (e.clientY - r.top));
    if (d < bestD) { best = p.id; bestD = d; }
  }
  hoverId = best;
  for (const [id, t] of tiles) t.el.classList.toggle('hl', id === best);
});
canvas.addEventListener('mouseleave', () => { hoverId = null; });

function lerpAngle(a, b, k) {
  const d = ((b - a + 540) % 360) - 180;
  return (a + d * k + 360) % 360;
}

// 0 = not looked (black), 1 = looked (red)

// probability heatmap: dark = ruled out, red → yellow = where the candidate most likely is
function heatColor(level) {
  const stops = [[0, [0, 0, 0]], [0.35, [110, 14, 20]], [0.7, [230, 60, 40]], [1, [255, 214, 90]]];
  let i = 1;
  while (i < stops.length - 1 && level > stops[i][0]) i++;
  const [a, ca] = stops[i - 1], [b, cb] = stops[i];
  const t = Math.max(0, Math.min(1, (level - a) / (b - a)));
  const c = ca.map((v, k) => Math.round(v + (cb[k] - v) * t));
  return `rgb(${c[0]},${c[1]},${c[2]})`;
}

function drawCoverage() {
  if (!coverage?.heat) return;
  const { cols, rows, cell, x0, heat } = coverage;
  const s = cell * view.scale;
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      ctx.fillStyle = heatColor(parseInt(heat[r * cols + c], 36) / 35);
      const [px, py] = view.toPx(x0 + c * cell, r * cell);
      ctx.fillRect(px, py, s + 0.5, s + 0.5); // +0.5 hides hairline seams between cells
    }
  }
}

function drawMap() {
  requestAnimationFrame(drawMap);
  if (!room || !view || !canvas.clientWidth) return;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  ctx.clearRect(0, 0, w, h);
  drawCoverage();
  drawRoom(ctx, room, view, { colors: { floor: 'rgba(0,0,0,0)' } });
  drawPlanner();

  const list = [...phones.values()].filter((p) => p.pose).sort((a, b) => a.index - b.index);
  // cones first so dots and labels sit on top
  for (const p of list) {
    const target = p.pose.heading;
    if (target == null || phase === 'lobby') { drawn.delete(p.id); continue; } // lobby: locations only
    const prev = drawn.get(p.id);
    const hd = prev == null ? target : lerpAngle(prev, target, 0.25);
    drawn.set(p.id, hd);
    const hot = hoverId === p.id;
    const alpha = !p.connected ? 0.08 : hot ? 0.7 : hoverId ? 0.12 : 0.38;
    drawCone(ctx, view, p.pose.x, p.pose.y, hd, room.cameraFovDeg, room.coneLength,
      hexA(p.color, alpha), hot ? p.color : null);
  }
  for (const p of list) {
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    const hot = hoverId === p.id;
    ctx.globalAlpha = p.connected ? 1 : 0.35;
    ctx.fillStyle = p.color;
    ctx.beginPath();
    ctx.arc(px, py, hot ? 7 : 5, 0, Math.PI * 2);
    ctx.fill();
    ctx.strokeStyle = '#05070f';
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.fillStyle = '#e9edff';
    ctx.font = `700 ${hot ? 13 : 11}px ui-sans-serif, system-ui`;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText(String(p.index), px + 8, py);
    ctx.globalAlpha = 1;
  }
  drawSightings();
  drawCandidate();
  drawPings();
}

function drawPings() {
  const k = (performance.now() / 1000) % 1;
  for (const pg of pings) {
    const [x, y] = view.toPx(pg.x, pg.y);
    ctx.save();
    ctx.globalAlpha = Math.max(0.3, 1 - (Date.now() - pg.t) / 12000);
    ctx.strokeStyle = `rgba(255,209,102,${1 - k})`;
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(x, y, 8 + k * 22, 0, Math.PI * 2); ctx.stroke();
    ctx.fillStyle = '#ffd166';
    ctx.beginPath(); ctx.moveTo(x, y - 9); ctx.lineTo(x + 9, y); ctx.lineTo(x, y + 9); ctx.lineTo(x - 9, y); ctx.closePath(); ctx.fill();
    ctx.font = '700 12px ui-sans-serif, system-ui';
    ctx.textAlign = 'center';
    ctx.fillText(pg.label, x, y - 16);
    ctx.restore();
  }
}

function hexA(hex, a) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`;
}

function escapeHtml(s) {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

$('#resetCov').addEventListener('click', () => send({ type: 'reset_coverage' }));
$('#plannerBtn').addEventListener('click', () => send({ type: 'planner', enabled: !planner?.enabled }));

function renderPlanner() {
  const on = !!planner?.enabled;
  $('#plannerBtn').textContent = `Planner: ${on ? 'on' : 'off'}`;
  $('#plannerBtn').classList.toggle('on', on);
  const logEl = $('#plog');
  logEl.classList.toggle('on', on || !!planner?.log?.length);
  logEl.innerHTML = (planner?.log || []).slice(-5).reverse().map((e) => {
    const p = e.phoneId && phones.get(e.phoneId);
    const who = p ? `<b style="color:${p.color}">#${p.index}</b> ` : '';
    const t = new Date(e.t).toLocaleTimeString([], { hour12: false });
    return `<div><time>${t}</time>${who}${escapeHtml(e.text)}</div>`;
  }).join('') || '<div>Planner idle: waiting for placed, calibrated phones</div>';
}

// sector grid, assigned sectors, and phone → target lines
function drawPlanner() {
  if (!planner?.enabled) return;
  const { sectorSize: s, cols, rows } = planner;
  const x0 = -room.width / 2;
  ctx.save();
  ctx.strokeStyle = 'rgba(255,255,255,0.14)';
  ctx.lineWidth = 1;
  ctx.fillStyle = 'rgba(255,255,255,0.28)';
  ctx.font = '600 10px ui-monospace, monospace';
  ctx.textAlign = 'left';
  ctx.textBaseline = 'top';
  for (let c = 0; c < cols; c++) {
    for (let r = 0; r < rows; r++) {
      const [px, py] = view.toPx(x0 + c * s, r * s);
      const [qx, qy] = view.toPx(Math.min(x0 + (c + 1) * s, room.width / 2), Math.min((r + 1) * s, room.depth));
      ctx.strokeRect(px, py, qx - px, qy - py);
      ctx.fillText(`${String.fromCharCode(65 + c)}${r + 1}`, px + 3, py + 3);
    }
  }
  for (const [pid, job] of Object.entries(planner.assignments)) {
    const p = phones.get(pid);
    if (!p?.pose) continue;
    const c = job.sector.charCodeAt(0) - 65, r = Number(job.sector.slice(1)) - 1;
    const [px, py] = view.toPx(x0 + c * s, r * s);
    const [qx, qy] = view.toPx(x0 + (c + 1) * s, (r + 1) * s);
    ctx.strokeStyle = p.color;
    ctx.lineWidth = 2;
    ctx.strokeRect(px + 1, py + 1, qx - px - 2, qy - py - 2);
    const [ax, ay] = view.toPx(p.pose.x, p.pose.y);
    ctx.setLineDash([5, 5]);
    ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo((px + qx) / 2, (py + qy) / 2); ctx.stroke();
    ctx.setLineDash([]);
  }
  ctx.restore();
}

// ---------------------------------------------------------------- gps map
// Real-world map of each phone's browser GPS fix. Indoors, expect tens of meters of error.
let gpsView = null;
const gpsMarkers = new Map(); // id → { dot, ring, label }
let gpsFitted = false;

document.querySelectorAll('.tab').forEach((btn) => btn.addEventListener('click', () => {
  document.querySelectorAll('.tab').forEach((b) => b.classList.toggle('on', b === btn));
  const gps = btn.dataset.view === 'gps';
  $('#mapWrap').classList.toggle('gps', gps);
  if (gps) {
    if (!gpsView) initGps();
    gpsView.invalidateSize();
    updateGps();
  } else {
    resizeMap();
  }
}));

function initGps() {
  gpsView = L.map('gpsMap', { zoomControl: true, attributionControl: true }).setView([43.4723, -80.5449], 16);
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19, className: 'osm-dark',
    attribution: '&copy; OpenStreetMap contributors',
  }).addTo(gpsView);
}

function updateGps() {
  const withFix = [...phones.values()].filter((p) => p.gps);
  for (const [id, m] of gpsMarkers) {
    if (!withFix.some((p) => p.id === id)) {
      m.dot.remove(); m.ring.remove(); gpsMarkers.delete(id);
    }
  }
  for (const p of withFix) {
    const ll = [p.gps.lat, p.gps.lon];
    let m = gpsMarkers.get(p.id);
    if (!m) {
      m = {
        ring: L.circle(ll, { radius: p.gps.accuracy, color: p.color, weight: 1, fillOpacity: 0.12 }).addTo(gpsView),
        dot: L.circleMarker(ll, { radius: 6, color: '#05070f', weight: 2, fillColor: p.color, fillOpacity: 1 })
          .bindTooltip('', { permanent: true, direction: 'right', offset: [8, 0] }).addTo(gpsView),
      };
      gpsMarkers.set(p.id, m);
    }
    m.ring.setLatLng(ll).setRadius(p.gps.accuracy);
    m.dot.setLatLng(ll).setTooltipContent(`#${p.index} ±${Math.round(p.gps.accuracy)}m`);
  }
  if (!gpsFitted && withFix.length) {
    gpsFitted = true;
    gpsView.fitBounds(L.latLngBounds(withFix.map((p) => [p.gps.lat, p.gps.lon])).pad(0.5), { maxZoom: 19 });
  }
}

window.swarmDebug = () => ({ phones: phones.size, frames: frameCount });
connect();
requestAnimationFrame(drawMap);

setInterval(renderTiles, 250);
