import { loadRoom, makeView, drawRoom, drawCone } from '/web/room.js';

const $ = (s) => document.querySelector(s);
const params = new URLSearchParams(location.search);
const FPS = Number(params.get('fps')) || 2;          // frames per second sent to the hub
const WIDTH = Number(params.get('w')) || 480;         // frame width in px
const QUALITY = Number(params.get('q')) || 0.6;       // JPEG quality
const FAKE = params.has('fake');                     // no camera: send a generated test pattern

const store = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { v === null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch {} },
};

const state = {
  phoneId: store.get('swarm.phoneId') || randomId(),
  name: store.get('swarm.name') || '',
  seat: JSON.parse(store.get('swarm.seat') || 'null'),
  calYaw: store.get('swarm.calYaw') === null ? null : Number(store.get('swarm.calYaw')),
  index: null, color: '#4cc9f0',
  ws: null, connected: false, retry: 0,
  ori: null, yaw: null, pitch: null, absYaw: null,
  guide: null,  // current search assignment from the planner
  gps: null, gpsError: null,
  seq: 0, sent: 0, skipped: 0,
  room: null, stream: null,
};
store.set('swarm.phoneId', state.phoneId);
$('#name').value = state.name;

function randomId() {
  if (crypto.randomUUID) return crypto.randomUUID();
  return 'p-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
}

// ---------------------------------------------------------------- join
$('#joinBtn').addEventListener('click', async () => {
  $('#joinBtn').disabled = true;
  $('#joinError').textContent = '';
  state.name = $('#name').value.trim();
  store.set('swarm.name', state.name);

  // iOS: every permission request must start synchronously inside this tap.
  const oriPerm = typeof DeviceOrientationEvent !== 'undefined' &&
    typeof DeviceOrientationEvent.requestPermission === 'function'
    ? DeviceOrientationEvent.requestPermission().catch(() => 'denied')
    : Promise.resolve('granted');
  startGps();
  const camPerm = FAKE ? Promise.resolve(null) : navigator.mediaDevices?.getUserMedia({
    video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } },
    audio: false,
  });

  try {
    if (!FAKE && !camPerm) throw new Error('Camera API unavailable. This page must be opened over HTTPS.');
    const [ori, stream] = await Promise.all([oriPerm, camPerm]);
    if (ori !== 'granted') console.warn('orientation permission:', ori);
    state.stream = stream;
    await startLive();
  } catch (err) {
    $('#joinBtn').disabled = false;
    $('#joinError').textContent = err?.name === 'NotAllowedError'
      ? 'Camera permission was denied. Allow it in Settings › Safari › Camera, then reload.'
      : (err?.message || String(err));
  }
});

async function startLive() {
  $('#join').style.display = 'none';
  $('#live').classList.add('on');

  if (FAKE) {
    $('#video').style.display = 'none';
    $('#fakeCanvas').style.display = 'block';
  } else {
    const video = $('#video');
    video.srcObject = state.stream;
    await video.play().catch(() => {});
  }

  window.addEventListener('deviceorientation', onOrientation);
  window.addEventListener('deviceorientationabsolute', onAbsoluteOrientation); // Android: north-referenced
  keepAwake();
  state.room = await loadRoom();
  setupSeatMap();
  connect();
  setInterval(captureFrame, 1000 / FPS);
  setInterval(sendOrientation, 100);
  requestAnimationFrame(tickUi);
}

async function keepAwake() {
  const req = async () => {
    try { await navigator.wakeLock?.request('screen'); } catch {}
  };
  await req();
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') req(); });
}

// ---------------------------------------------------------------- socket
function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/ws/phone`);
  ws.binaryType = 'arraybuffer';
  state.ws = ws;

  ws.onopen = () => {
    state.retry = 0;
    ws.send(JSON.stringify({
      type: 'hello', phoneId: state.phoneId, name: state.name, seat: state.seat,
      ua: navigator.userAgent, sim: false,
    }));
  };
  ws.onmessage = (ev) => {
    if (typeof ev.data !== 'string') return;
    const msg = JSON.parse(ev.data);
    if (msg.type === 'ping') {
      ws.send(JSON.stringify({ type: 'pong', ts: msg.ts, tp: Date.now() }));
    } else if (msg.type === 'welcome') {
      state.connected = true;
      if (state.gps) sendJson({ type: 'gps', ...state.gps });
      state.index = msg.index;
      state.color = msg.color;
      $('#badge').textContent = `#${msg.index}`;
      $('#badge').style.color = msg.color;
      drawSeatMap();
    } else if (msg.type === 'command') {
      onCommand(msg);
    }
  };
  ws.onclose = () => {
    state.connected = false;
    if (state.ws !== ws) return;
    const delay = Math.min(500 * 2 ** state.retry++, 5000);
    setTimeout(connect, delay);
  };
  ws.onerror = () => ws.close();
}

function sendJson(msg) {
  if (state.ws?.readyState === WebSocket.OPEN && state.connected) state.ws.send(JSON.stringify(msg));
}

// ---------------------------------------------------------------- capture
const cap = $('#capture');
const capCtx = cap.getContext('2d');

function captureFrame() {
  const ws = state.ws;
  if (!ws || ws.readyState !== WebSocket.OPEN || !state.connected) return;
  if (ws.bufferedAmount > 256 * 1024) { state.skipped++; return; } // latest wins: drop, don't queue

  let w, h;
  if (FAKE) {
    w = WIDTH; h = Math.round(WIDTH * 0.75);
    cap.width = w; cap.height = h;
    drawFakeFrame(capCtx, w, h);
  } else {
    const v = $('#video');
    if (!v.videoWidth) return;
    w = WIDTH; h = Math.round((WIDTH * v.videoHeight) / v.videoWidth);
    cap.width = w; cap.height = h;
    capCtx.drawImage(v, 0, 0, w, h);
  }

  const header = {
    type: 'frame', seq: state.seq++, tCapture: Date.now(),
    heading: currentHeading(), pitch: state.pitch, calibrated: state.calYaw !== null,
    orientation: state.ori,
  };
  cap.toBlob(async (blob) => {
    if (!blob || ws.readyState !== WebSocket.OPEN) return;
    ws.send(pack(header, await blob.arrayBuffer()));
    state.sent++;
  }, 'image/jpeg', QUALITY);
}

function pack(header, bytes) {
  const h = new TextEncoder().encode(JSON.stringify(header));
  const out = new Uint8Array(4 + h.length + bytes.byteLength);
  new DataView(out.buffer).setUint32(0, h.length); // big-endian
  out.set(h, 4);
  out.set(new Uint8Array(bytes), 4 + h.length);
  return out.buffer;
}

function drawFakeFrame(ctx, w, h) {
  const t = Date.now() / 1000;
  const hd = currentHeading() ?? (t * 20) % 360;
  ctx.fillStyle = '#10162c';
  ctx.fillRect(0, 0, w, h);
  // a "stage" that slides across the view as you turn
  const rel = ((hd + 540) % 360) - 180;
  const sx = w / 2 - rel * (w / 55);
  ctx.fillStyle = '#2b3a6e';
  ctx.fillRect(sx - w * 0.35, h * 0.35, w * 0.7, h * 0.2);
  ctx.fillStyle = state.color;
  ctx.beginPath();
  ctx.arc(w / 2 + Math.sin(t * 2) * w * 0.3, h * 0.75, 18, 0, Math.PI * 2);
  ctx.fill();
  ctx.fillStyle = '#fff';
  ctx.font = `bold ${Math.round(h / 7)}px system-ui`;
  ctx.fillText(`FAKE #${state.index ?? '?'}`, 16, h / 6);
  ctx.font = `${Math.round(h / 14)}px ui-monospace, monospace`;
  ctx.fillText(new Date().toLocaleTimeString(), 16, h - 16);
  if (!state._fakePreview) state._fakePreview = $('#fakeCanvas');
  const pv = state._fakePreview;
  pv.width = w; pv.height = h;
  pv.getContext('2d').drawImage(cap, 0, 0);
}

// ---------------------------------------------------------------- orientation
// Direction the back camera points, from W3C deviceorientation angles (Z-X'-Y').
// Returns yaw (deg, clockwise, arbitrary zero on iOS) and pitch (deg, + = up).
function cameraYawPitch(alpha, beta, gamma) {
  const d = Math.PI / 180;
  const cA = Math.cos(alpha * d), sA = Math.sin(alpha * d);
  const cB = Math.cos(beta * d), sB = Math.sin(beta * d);
  const cG = Math.cos(gamma * d), sG = Math.sin(gamma * d);
  // back camera = device -Z axis, rotated into the world frame
  const vx = -(cA * sG + sA * sB * cG);
  const vy = -(sA * sG - cA * sB * cG);
  const vz = -(cB * cG);
  const yaw = (Math.atan2(vx, vy) / d + 360) % 360;
  const pitch = Math.asin(Math.max(-1, Math.min(1, vz))) / d;
  return { yaw, pitch };
}

function onOrientation(e) {
  if (e.alpha === null || e.beta === null || e.gamma === null) return;
  state.ori = { alpha: e.alpha, beta: e.beta, gamma: e.gamma, compass: e.webkitCompassHeading ?? null };
  const { yaw, pitch } = cameraYawPitch(e.alpha, e.beta, e.gamma);
  state.yaw = yaw;
  state.pitch = pitch;
}

function onAbsoluteOrientation(e) {
  if (e.alpha === null || e.beta === null || e.gamma === null) return;
  state.absYaw = cameraYawPitch(e.alpha, e.beta, e.gamma).yaw;
}

// Compass bearing the camera faces (0 = north), or null when the device has no compass.
function absoluteBearing() {
  if (state.absYaw !== null) return state.absYaw;
  const c = state.ori?.compass;
  return typeof c === 'number' ? c : null;
}

function currentHeading() {
  if (state.yaw === null) return null;
  return (state.yaw - (state.calYaw ?? 0) + 360) % 360;
}

function sendOrientation() {
  const heading = currentHeading();
  if (heading === null) return;
  sendJson({ type: 'orient', tCapture: Date.now(), heading, pitch: state.pitch, calibrated: state.calYaw !== null });
}

$('#calBtn').addEventListener('click', () => {
  if (state.yaw === null) {
    $('#calBtn').textContent = 'No motion sensor data';
    return;
  }
  state.calYaw = state.yaw;
  store.set('swarm.calYaw', String(state.calYaw));
  $('#calBtn').textContent = 'Calibrated ✓ (tap to redo)';
  $('#calBtn').classList.remove('hot');
});
if (state.calYaw !== null) $('#calBtn').textContent = 'Calibrated ✓ (tap to redo)';
else $('#calBtn').classList.add('hot');

// ---------------------------------------------------------------- gps
// Indoors this is typically accurate to tens of meters: useful for "which building",
// not "which seat".
let gpsWatch = null;
function startGps() {
  if (!navigator.geolocation) { state.gpsError = 'unsupported'; return; }
  if (gpsWatch !== null) navigator.geolocation.clearWatch(gpsWatch);
  state.gpsError = null;
  gpsWatch = navigator.geolocation.watchPosition((pos) => {
    const c = pos.coords;
    state.gps = {
      lat: c.latitude, lon: c.longitude, accuracy: c.accuracy,
      altitude: c.altitude, speed: c.speed, tFix: pos.timestamp,
    };
    state.gpsError = null;
    sendJson({ type: 'gps', ...state.gps });
  }, (err) => {
    state.gpsError = err.code === err.PERMISSION_DENIED ? 'denied (tap to retry)' : 'no fix';
  }, { enableHighAccuracy: true, maximumAge: 0, timeout: 30000 });
}

// Tapping the stats pill retries GPS (e.g. after allowing location in Settings).
$('#stats').parentElement.addEventListener('click', () => { if (!state.gps) startGps(); });

// ---------------------------------------------------------------- seat map
let seatView = null;

function setupSeatMap() {
  const c = $('#seatMap');
  const place = (ev) => {
    const r = c.getBoundingClientRect();
    const [x, y] = seatView.toRoom(ev.clientX - r.left, ev.clientY - r.top);
    const room = state.room;
    state.seat = {
      x: Math.max(-room.width / 2, Math.min(room.width / 2, x)),
      y: Math.max(0, Math.min(room.depth, y)),
    };
    store.set('swarm.seat', JSON.stringify(state.seat));
    sendJson({ type: 'seat', seat: state.seat });
    drawSeatMap();
  };
  c.addEventListener('pointerdown', place);
  window.addEventListener('resize', drawSeatMap);
  $('#toggleSheet').addEventListener('click', () => {
    const s = $('#sheet');
    s.classList.toggle('collapsed');
    $('#toggleSheet').textContent = s.classList.contains('collapsed') ? 'Map' : 'Hide';
    drawSeatMap();
  });
  drawSeatMap();
}

function drawSeatMap() {
  const c = $('#seatMap');
  if (!state.room || !c.clientWidth) return;
  const dpr = window.devicePixelRatio || 1;
  c.width = c.clientWidth * dpr;
  c.height = c.clientHeight * dpr;
  const ctx = c.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, c.clientWidth, c.clientHeight);
  seatView = makeView(state.room, c.clientWidth, c.clientHeight, 8);
  drawRoom(ctx, state.room, seatView, { grid: false });
  $('#seatHint').textContent = state.seat ? 'Your spot (tap to move)' : 'Tap where you are on the map';
  if (!state.seat) return;
  const h = currentHeading();
  if (h !== null) {
    drawCone(ctx, seatView, state.seat.x, state.seat.y, h, state.room.cameraFovDeg, state.room.coneLength,
      hexA(state.color, 0.55));
  }
  const [px, py] = seatView.toPx(state.seat.x, state.seat.y);
  ctx.fillStyle = state.color;
  ctx.beginPath();
  ctx.arc(px, py, 5, 0, Math.PI * 2);
  ctx.fill();
}

function hexA(hex, a) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`;
}

// ---------------------------------------------------------------- commands
let flashTimer = null;
function onCommand(msg) {
  if (msg.cmd === 'guide') {
    if (msg.clear) { state.guide = null; return; }
    const h = currentHeading();
    if (h === null) return;
    // store the target as a heading so the marker tracks turns between updates
    state.guide = { sector: msg.sector, target: (h + msg.delta + 360) % 360, t: Date.now() };
    return;
  }
  if (msg.cmd === 'flash') {
    const el = $('#flash');
    el.style.background = msg.color || state.color;
    el.textContent = msg.text || '';
    el.classList.add('on');
    clearTimeout(flashTimer);
    flashTimer = setTimeout(() => el.classList.remove('on'), msg.ttlMs || 1500);
  }
}

// ---------------------------------------------------------------- compass tape
const CARDINALS = { 0: 'N', 45: 'NE', 90: 'E', 135: 'SE', 180: 'S', 225: 'SW', 270: 'W', 315: 'NW' };
const SPAN = 120; // degrees visible across the tape

function signedDiff(a, b) { return ((a - b + 540) % 360) - 180; }

function guideOffset() {
  const g = state.guide;
  const h = currentHeading();
  if (!g || h === null || Date.now() - g.t > 3000) return null;
  return signedDiff(g.target, h);
}

function drawCompass() {
  const c = $('#compass');
  const w = c.clientWidth, h = c.clientHeight;
  if (!w) return;
  const dpr = window.devicePixelRatio || 1;
  if (c.width !== w * dpr) { c.width = w * dpr; c.height = h * dpr; }
  const ctx = c.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);

  const rel = currentHeading();
  const abs = absoluteBearing();
  const center = abs ?? rel;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  if (center === null) {
    ctx.fillStyle = '#8b93b0';
    ctx.font = '600 13px system-ui';
    ctx.fillText('No compass data', w / 2, h / 2);
    return;
  }
  const ppd = w / SPAN;
  ctx.save();
  ctx.beginPath(); ctx.rect(0, 0, w, h); ctx.clip();

  // ticks and labels
  for (let d = Math.ceil((center - SPAN / 2) / 5) * 5; d <= center + SPAN / 2; d += 5) {
    const x = w / 2 + (d - center) * ppd;
    const dd = ((d % 360) + 360) % 360;
    const major = dd % 15 === 0;
    ctx.strokeStyle = major ? 'rgba(255,255,255,0.7)' : 'rgba(255,255,255,0.3)';
    ctx.lineWidth = major ? 2 : 1;
    ctx.beginPath(); ctx.moveTo(x, h - (major ? 14 : 8)); ctx.lineTo(x, h - 2); ctx.stroke();
    if (major) {
      const card = abs !== null ? CARDINALS[dd] : null;
      ctx.fillStyle = card ? '#ffffff' : 'rgba(255,255,255,0.55)';
      ctx.font = card ? '800 14px system-ui' : '600 11px system-ui';
      ctx.fillText(card ?? String(dd), x, h - 24);
    }
  }

  // markers are placed by heading offset, so they work with or without a compass
  const markers = [];
  if (rel !== null && state.calYaw !== null) markers.push({ off: signedDiff(0, rel), label: 'STAGE', color: '#4cc9f0' });
  const g = guideOffset();
  if (g !== null) markers.push({ off: g, label: state.guide.sector, color: Math.abs(g) < 16 ? '#7ae582' : '#ffb703', big: true });
  for (const m of markers) {
    const edge = Math.abs(m.off) > SPAN / 2 - 8;
    const x = edge ? (m.off > 0 ? w - 22 : 22) : w / 2 + m.off * ppd;
    const label = edge ? (m.off > 0 ? `${m.label} ▶` : `◀ ${m.label}`) : m.label;
    ctx.font = `800 ${m.big ? 13 : 11}px system-ui`;
    const tw = ctx.measureText(label).width + 12;
    const bx = Math.max(2, Math.min(w - tw - 2, x - tw / 2));
    ctx.fillStyle = m.color;
    ctx.beginPath(); ctx.roundRect(bx, 3, tw, 18, 9); ctx.fill();
    ctx.fillStyle = '#05070f';
    ctx.fillText(label, bx + tw / 2, 12.5);
    if (!edge) { ctx.fillStyle = m.color; ctx.fillRect(x - 1, 21, 2, h - 21); }
  }
  ctx.restore();

  // center caret and readout
  ctx.fillStyle = '#ffffff';
  ctx.beginPath(); ctx.moveTo(w / 2 - 6, h); ctx.lineTo(w / 2 + 6, h); ctx.lineTo(w / 2, h - 8); ctx.fill();
  if (!markers.some((m) => Math.abs(m.off) * ppd < 40)) {
    const text = abs !== null
      ? `${Math.round(abs) % 360}° ${CARDINALS[Math.round(abs / 45) * 45 % 360]}`
      : `${Math.round(rel)}°`;
    ctx.font = '800 13px ui-monospace, monospace';
    const tw = ctx.measureText(text).width + 14;
    ctx.fillStyle = 'rgba(255,255,255,0.95)';
    ctx.beginPath(); ctx.roundRect(w / 2 - tw / 2, 3, tw, 18, 9); ctx.fill();
    ctx.fillStyle = '#05070f';
    ctx.fillText(text, w / 2, 12.5);
  }
}

function updateGuideBanner() {
  const el = $('#guide');
  const off = guideOffset();
  if (off === null) { el.classList.remove('on'); return; }
  const tilted = state.pitch !== null && Math.abs(state.pitch) > 65;
  const onTarget = Math.abs(off) < 16;
  el.classList.add('on');
  el.classList.toggle('ok', onTarget && !tilted);
  el.textContent = tilted ? 'Hold your phone up'
    : onTarget ? `Scanning ${state.guide.sector}…`
    : off > 0 ? `Turn right ${Math.round(off)}° →` : `← Turn left ${Math.round(-off)}°`;
}

// ---------------------------------------------------------------- ui loop
let lastUi = 0;
function tickUi(t) {
  drawCompass();
  updateGuideBanner();
  if (t - lastUi > 150) {
    lastUi = t;
    $('#connDot').classList.toggle('ok', state.connected);
    $('#connText').textContent = state.connected ? 'Live' : 'Reconnecting…';
    const gps = state.gps ? `GPS ±${Math.round(state.gps.accuracy)}m` : `GPS ${state.gpsError || '…'}`;
    $('#stats').textContent = `${state.sent} sent · ${gps}`;
    const h = currentHeading();
    $('#heading').textContent = h === null ? 'no gyro' : `${Math.round(h)}°${state.calYaw === null ? ' (uncal.)' : ''}`;
    if (!$('#sheet').classList.contains('collapsed')) drawSeatMap();
  }
  requestAnimationFrame(tickUi);
}
