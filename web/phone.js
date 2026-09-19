import { loadRoom, makeView, drawRoom, drawCone } from '/web/room.js';
import { startSlam, cameraForward, slamDebug } from '/web/slam.js';

const $ = (s) => document.querySelector(s);
const params = new URLSearchParams(location.search);
const FPS = Number(params.get('fps')) || 2;          // frames per second sent to the hub
const WIDTH = Number(params.get('w')) || 480;         // frame width in px
const QUALITY = Number(params.get('q')) || 0.6;       // JPEG quality
const FAKE = params.has('fake');                     // no camera: send a generated test pattern
const SLAM = params.has('slam') && !FAKE;             // 8th Wall world tracking for position + heading
const SLAM_SCALE = params.get('slam') === 'responsive' ? 'responsive' : 'absolute';
const SLAM_POS_SMOOTHING = 0.08;     // per tracker update (~30/s): ~0.4 s to settle
const SLAM_HEADING_SMOOTHING = 0.25; // heading reacts faster than position

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
  world: null,  // shared picture from the hub: other phones, coverage, pings, progress
  pings: new Map(),  // id → {x, y, label, until}
  dets: null,   // detection boxes to draw: {boxes, until}
  audio: null,
  // SLAM mode: raw = latest tracker pose; origin = pose at calibration (your spot, facing the stage)
  slam: { raw: null, origin: null, status: 'starting', x: null, y: null, heading: null, lastSent: 0 },
  captureDue: false,
  gps: null, gpsError: null,
  seq: 0, sent: 0, skipped: 0,
  room: null, stream: null,
};
store.set('swarm.phoneId', state.phoneId);
$('#name').value = state.name;
if (SLAM) {
  $('#modeLink').href = '/';
  $('#modeLink').textContent = '← Standard mode';
}

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
  try { state.audio = new (window.AudioContext || window.webkitAudioContext)(); } catch {} // unlocked by this tap

  // iOS: every permission request must start synchronously inside this tap.
  const oriPerm = typeof DeviceOrientationEvent !== 'undefined' &&
    typeof DeviceOrientationEvent.requestPermission === 'function'
    ? DeviceOrientationEvent.requestPermission().catch(() => 'denied')
    : Promise.resolve('granted');
  startGps();
  const camPerm = FAKE || SLAM ? Promise.resolve(null) : navigator.mediaDevices?.getUserMedia({
    video: { facingMode: { ideal: 'environment' }, width: { ideal: 1280 }, height: { ideal: 720 } },
    audio: false,
  });

  try {
    if (!FAKE && !SLAM && !camPerm) throw new Error('Camera API unavailable. This page must be opened over HTTPS.');
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
  } else if (SLAM) {
    $('#video').style.display = 'none';
    $('#xrCanvas').style.display = 'block';
    await startSlam($('#xrCanvas'), {
      scale: SLAM_SCALE,
      onUpdate: onSlamUpdate,
      onRender: onSlamRender,
      onStatus: (s) => { if (s === 'failed') state.slam.status = 'camera failed'; },
      onError: (e) => { state.slam.status = 'error'; console.error('8th Wall:', e); },
    });
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
  if (SLAM) setInterval(sendSlamDebug, 2000);
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
      setPhase(msg.phase);
      $('#badge').textContent = `#${msg.index}`;
      $('#badge').style.color = msg.color;
      drawSeatMap();
    } else if (msg.type === 'command') {
      onCommand(msg);
    } else if (msg.type === 'phase') {
      setPhase(msg.phase);
    } else if (msg.type === 'world') {
      onWorld(msg);
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

  if (SLAM) { state.captureDue = true; return; } // grabbed in onSlamRender
  if (FAKE) {
    cap.width = WIDTH; cap.height = Math.round(WIDTH * 0.75);
    drawFakeFrame(capCtx, cap.width, cap.height);
  } else {
    const v = $('#video');
    if (!v.videoWidth) return;
    grabInto(v, v.videoWidth, v.videoHeight);
  }
  sendCapture();
}

function grabInto(src, sw, sh) {
  cap.width = WIDTH;
  cap.height = Math.round((WIDTH * sh) / sw);
  capCtx.drawImage(src, 0, 0, cap.width, cap.height);
}

function sendCapture() {
  const ws = state.ws;
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
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
  if (SLAM && state.slam.heading !== null && state.slam.status === 'NORMAL') return state.slam.heading;
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
  if (SLAM && !calibrateSlam()) return;
  state.calYaw = state.yaw;
  store.set('swarm.calYaw', String(state.calYaw));
  $('#calBtn').textContent = 'Calibrated ✓ (tap to redo)';
  $('#calBtn').classList.remove('hot');
});
if (state.calYaw !== null) $('#calBtn').textContent = 'Calibrated ✓ (tap to redo)';
else $('#calBtn').classList.add('hot');

// ---------------------------------------------------------------- slam (8th Wall)
// Calibration ties the tracker to the room: the pose at that moment is "my tapped spot,
// facing the stage". After that, movement in tracker meters becomes movement in room meters.
function calibrateSlam() {
  const raw = state.slam.raw;
  if (!raw || state.slam.status !== 'NORMAL') {
    $('#calBtn').textContent = 'Tracking not ready: move the phone slowly';
    return false;
  }
  if (!state.seat) {
    $('#calBtn').textContent = 'Tap your spot on the map first';
    return false;
  }
  const [fx, fz] = raw.flat;
  state.slam.origin = { px: raw.px, pz: raw.pz, f: [fx, fz], r: [-fz, fx], seat: { ...state.seat } };
  state.slam.x = state.slam.y = state.slam.heading = null; // restart smoothing from the new anchor
  return true;
}

function onSlamUpdate(reality) {
  const s = state.slam;
  s.status = reality.trackingStatus || s.status;
  if (!reality.position || !reality.rotation) return;
  const f = cameraForward(reality.rotation);
  const len = Math.hypot(f[0], f[2]);
  if (len < 1e-3) return; // pointing straight up/down: no meaningful heading
  s.raw = { px: reality.position.x, pz: reality.position.z, flat: [f[0] / len, f[2] / len] };
  const o = s.origin;
  if (!o) return;
  const dx = s.raw.px - o.px, dz = s.raw.pz - o.pz;
  const forward = dx * o.f[0] + dz * o.f[1];
  const right = dx * o.r[0] + dz * o.r[1];
  const [ux, uz] = s.raw.flat;
  const heading = ((Math.atan2(ux * o.r[0] + uz * o.r[1], ux * o.f[0] + uz * o.f[1]) * 180) / Math.PI + 360) % 360;
  const x = o.seat.x + right;
  const y = o.seat.y - forward; // toward the stage is -y on the floor plan
  // Smooth out hand shake: blend each tracker update into the running pose.
  if (s.x === null) {
    s.x = x; s.y = y; s.heading = heading;
  } else {
    s.x += SLAM_POS_SMOOTHING * (x - s.x);
    s.y += SLAM_POS_SMOOTHING * (y - s.y);
    s.heading = (s.heading + SLAM_HEADING_SMOOTHING * signedDiff(heading, s.heading) + 360) % 360;
  }
  const now = Date.now();
  if (s.status === 'NORMAL' && now - s.lastSent > 100) {
    s.lastSent = now;
    sendJson({ type: 'slam', x: s.x, y: s.y, heading: s.heading, pitch: state.pitch });
  }
}

// Tracker diagnostics, shown on the dashboard tile's tooltip and in /api/state.
let motionEvents = 0;
window.addEventListener('devicemotion', () => { motionEvents++; });
function sendSlamDebug() {
  const c = $('#xrCanvas');
  sendJson({
    type: 'debug',
    slam: {
      status: state.slam.status, ...slamDebug, calibrated: !!state.slam.origin,
      canvas: [c.width, c.height], screen: [innerWidth, innerHeight, devicePixelRatio],
      motionEventsPer2s: motionEvents, xr8: window.XR8?.version?.() ?? null,
    },
  });
  motionEvents = 0;
}

function onSlamRender() {
  if (!state.captureDue) return;
  state.captureDue = false;
  const c = $('#xrCanvas');
  if (!c.width) return;
  grabInto(c, c.width, c.height);
  sendCapture();
}

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
    renderPhase();
    const o = state.slam.origin, raw = state.slam.raw;
    if (SLAM && o && raw) { // "I'm here now": re-anchor, and jump the pin instead of gliding
      Object.assign(o, { px: raw.px, pz: raw.pz, seat: { ...state.seat } });
      state.slam.x = state.slam.y = null;
    }
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
  const v = seatView;
  const w = state.world;
  // searched floor
  const cov = w?.coverage;
  if (cov) {
    const s = cov.cell * v.scale;
    ctx.fillStyle = 'rgba(122,229,130,0.22)';
    for (let r = 0; r < cov.rows; r++) {
      for (let col = 0; col < cov.cols; col++) {
        if (cov.cells.charCodeAt(r * cov.cols + col) !== 49) continue;
        const [x, y] = v.toPx(cov.x0 + col * cov.cell, r * cov.cell);
        ctx.fillRect(x, y, s + 0.5, s + 0.5);
      }
    }
  }
  drawRoom(ctx, state.room, v, { grid: false, colors: { floor: 'rgba(0,0,0,0)' } });
  $('#seatHint').textContent = state.seat ? 'Your spot (tap to move)' : 'Tap where you are on the map';
  // teammates
  for (const p of w?.phones || []) {
    if (p.id === state.phoneId) continue;
    const [x, y] = v.toPx(p.x, p.y);
    ctx.fillStyle = 'rgba(255,255,255,0.55)';
    ctx.beginPath(); ctx.arc(x, y, 3, 0, Math.PI * 2); ctx.fill();
  }
  // found candidate
  if (w?.candidate) {
    const [x, y] = v.toPx(w.candidate.x, w.candidate.y);
    const k = (performance.now() / 900) % 1;
    ctx.strokeStyle = `rgba(255,93,115,${1 - k})`;
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(x, y, 4 + k * 12, 0, Math.PI * 2); ctx.stroke();
    ctx.fillStyle = '#ff5d73';
    ctx.beginPath(); ctx.arc(x, y, 4, 0, Math.PI * 2); ctx.fill();
  }
  // pings
  for (const pg of activePings()) {
    const [x, y] = v.toPx(pg.x, pg.y);
    ctx.fillStyle = PING_COLOR;
    ctx.beginPath(); ctx.moveTo(x, y - 6); ctx.lineTo(x + 6, y); ctx.lineTo(x, y + 6); ctx.lineTo(x - 6, y); ctx.closePath(); ctx.fill();
  }
  // me
  const me = myPos();
  if (!me) return;
  const h = currentHeading();
  if (h !== null) {
    drawCone(ctx, v, me.x, me.y, h, state.room.cameraFovDeg, state.room.coneLength, hexA(state.color, 0.55));
  }
  const [px, py] = v.toPx(me.x, me.y);
  ctx.fillStyle = state.color;
  ctx.strokeStyle = '#05070f';
  ctx.lineWidth = 2;
  ctx.beginPath(); ctx.arc(px, py, 5, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
}

function hexA(hex, a) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`;
}

// ---------------------------------------------------------------- show phases
// The operator console moves everyone through lobby → calibrate → search → found → end.
let phase = null;
function setPhase(next) {
  phase = next;
  renderPhase();
}

function renderPhase() {
  const card = $('#phaseCard');
  const btn = $('#phaseBtn');
  card.classList.remove('on', 'full');
  btn.hidden = true;
  if (phase === 'lobby') {
    $('#phaseTitle').textContent = `You're in${state.index ? ` · #${state.index}` : ''}`;
    $('#phaseText').textContent = state.seat
      ? 'Hang tight, the search starts soon.'
      : 'Tap where you are on the map below, then hang tight.';
    card.classList.add('on');
  } else if (phase === 'calibrate') {
    $('#phaseTitle').textContent = 'Point at the stage';
    $('#phaseText').textContent = state.seat
      ? 'Hold your phone up toward the stage, then tap the button.'
      : 'First tap where you are on the map below.';
    btn.textContent = "I'm pointing at the stage";
    btn.hidden = !state.seat;
    card.classList.add('on');
  } else if (phase === 'end') {
    const s = state.world?.stats;
    $('#phaseTitle').textContent = 'Search complete';
    $('#phaseText').textContent = s?.m2
      ? `You searched ${s.m2} m², #${s.rank} of ${s.of}. Thanks for helping!`
      : 'Thanks for helping. You can close this page.';
    card.classList.add('on', 'full');
  }
}

$('#phaseBtn').addEventListener('click', () => {
  $('#calBtn').click(); // same calibration as the sheet's button
  if (state.calYaw !== null) {
    $('#phaseTitle').textContent = 'Calibrated ✓';
    $('#phaseText').textContent = 'Keep your phone up. The search starts soon.';
    $('#phaseBtn').hidden = true;
  }
});

// ---------------------------------------------------------------- commands
let flashTimer = null;
function onCommand(msg) {
  if (msg.cmd === 'guide') {
    if (msg.clear) { state.guide = null; return; }
    if (msg.kind === 'look') {
      state.guide = {
        kind: 'look', sector: msg.sector, compass: msg.compass ?? null, heading: msg.heading ?? null,
        distance: msg.distance ?? null, t: Date.now(), until: Date.now() + (msg.untilMs ?? 20000),
      };
      return;
    }
    const h = currentHeading();
    if (h === null) return;
    // store the target as a heading so the marker tracks turns between updates
    state.guide = {
      sector: msg.sector, target: (h + msg.delta + 360) % 360, t: Date.now(),
      kind: msg.kind || 'search', distance: msg.distance ?? null,
    };
    return;
  }
  if (msg.cmd === 'ping') {
    if (!state.pings.has(msg.id)) beep(1175, 0.09, 2);
    state.pings.set(msg.id, { x: msg.x, y: msg.y, label: msg.label, until: Date.now() + (msg.ttlMs || 12000) });
    return;
  }
  if (msg.cmd === 'message') {
    showToast(`📣 ${msg.text}`, msg.ttlMs || 8000);
    beep(660, 0.12);
    return;
  }
  if (msg.cmd === 'detections') {
    state.dets = { boxes: msg.boxes || [], until: Date.now() + (msg.ttlMs || 1500) };
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
  if (!g || h === null) return null;
  if (g.kind === 'look') {
    if (Date.now() > g.until) return null;
    if (g.compass !== null) {
      const abs = absoluteBearing(); // real-world direction needs this phone's compass
      return abs === null ? null : signedDiff(g.compass, abs);
    }
    return signedDiff(g.heading, h);
  }
  if (Date.now() - g.t > 3000) return null;
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
  if (g !== null) {
    const respond = state.guide.kind === 'respond';
    markers.push({
      off: g, big: true,
      label: respond ? `CANDIDATE ${state.guide.distance}m` : state.guide.sector,
      color: respond ? '#ff5d73' : Math.abs(g) < 16 ? '#7ae582' : state.guide.kind === 'look' ? '#4cc9f0' : '#ffb703',
    });
  }
  for (const t of worldTargets()) {
    if (t.kind === 'candidate' && state.guide?.kind === 'respond') continue; // already shown as the guide marker
    markers.push({ off: t.off, label: `${t.label} ${t.dist.toFixed(0)}m`, color: t.color });
  }
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
  const g = state.guide;
  if (off === null && g?.kind === 'look' && g.compass !== null && Date.now() < g.until) {
    el.className = 'on'; // asked for a real-world direction, but this phone has no compass
    el.textContent = `Face ${g.sector} (no compass on this phone)`;
    return;
  }
  if (off === null) { el.classList.remove('on'); return; }
  const tilted = state.pitch !== null && Math.abs(state.pitch) > 65;
  const onTarget = Math.abs(off) < 16;
  el.classList.add('on');
  if (state.guide.kind === 'respond') {
    // walking to a found candidate: always red, direction + distance
    el.classList.remove('ok');
    el.classList.add('alert');
    const dist = `${state.guide.distance} m`;
    el.textContent = onTarget ? `↑ Candidate ahead · ${dist}`
      : off > 0 ? `Turn right ${Math.round(off)}° → · ${dist}` : `← Turn left ${Math.round(-off)}° · ${dist}`;
    return;
  }
  el.classList.remove('alert');
  if (state.guide.kind === 'look') {
    el.classList.toggle('ok', onTarget);
    const name = state.guide.sector;
    el.textContent = onTarget ? `Facing ${name} ✓ hold it`
      : off > 0 ? `Face ${name} · turn right ${Math.round(off)}° →` : `← Face ${name} · turn left ${Math.round(-off)}°`;
    return;
  }
  el.classList.toggle('ok', onTarget && !tilted);
  el.textContent = tilted ? 'Hold your phone up'
    : onTarget ? `Scanning ${state.guide.sector}…`
    : off > 0 ? `Turn right ${Math.round(off)}° →` : `← Turn left ${Math.round(-off)}°`;
}

// ---------------------------------------------------------------- shared world: mini-map, pings, AR
const PING_COLOR = '#ffd166';
const CAM_HEIGHT = 1.3;    // m, a phone held up at chest height
const TARGET_HEIGHT = 1.0; // m, roughly a seated person / tabletop

// Where I am on the floor plan: live SLAM position if calibrated, else the tapped spot.
function myPos() {
  if (SLAM && state.slam.origin && state.slam.x !== null) return { x: state.slam.x, y: state.slam.y };
  return state.seat;
}

function onWorld(msg) {
  state.world = msg;
  for (const pg of msg.pings || []) {
    if (!state.pings.has(pg.id)) {
      state.pings.set(pg.id, { x: pg.x, y: pg.y, label: pg.label, until: Date.now() + 12000 - pg.ageMs });
    }
  }
  if (phase === 'end') renderPhase(); // personal stats may have changed
}

function activePings() {
  const now = Date.now();
  for (const [id, pg] of state.pings) if (pg.until < now) state.pings.delete(id);
  return [...state.pings.values()];
}

// Pings and the found candidate, relative to where I'm looking: {off (deg), dist (m), label, color, kind}
function worldTargets() {
  const me = myPos();
  const h = currentHeading();
  if (!me || h === null) return [];
  const rel = (x, y) => {
    const bearing = (Math.atan2(x - me.x, -(y - me.y)) * 180) / Math.PI;
    return { off: signedDiff(bearing, h), dist: Math.hypot(x - me.x, y - me.y) };
  };
  const out = activePings().map((pg) => ({ ...rel(pg.x, pg.y), label: `◆ ${pg.label}`, color: PING_COLOR, kind: 'ping' }));
  const c = state.world?.candidate;
  if (c) out.push({ ...rel(c.x, c.y), label: 'CANDIDATE', color: '#ff5d73', kind: 'candidate' });
  return out;
}

// Project a direction + distance into the camera view, using heading, tilt and field of view.
function project(offDeg, dist, w, h) {
  const hf = (state.room.cameraFovDeg * Math.PI) / 180;
  const vf = 2 * Math.atan(Math.tan(hf / 2) * (h / w));
  const off = (offDeg * Math.PI) / 180;
  if (Math.abs(off) >= Math.PI / 2) return null;
  const elev = Math.atan2(TARGET_HEIGHT - CAM_HEIGHT, Math.max(dist, 0.3));
  const dv = elev - ((state.pitch ?? 0) * Math.PI) / 180;
  if (Math.abs(dv) >= Math.PI / 2) return null;
  const x = w / 2 + (Math.tan(off) / Math.tan(hf / 2)) * (w / 2);
  const y = h / 2 - (Math.tan(dv) / Math.tan(vf / 2)) * (h / 2);
  return x < -60 || x > w + 60 || y < -60 || y > h + 60 ? null : [x, y];
}

// Map a 0..1 point in the captured frame to screen pixels (the video is shown object-fit: cover).
function frameToScreen(nx, ny, W, H) {
  const v = $('#video');
  if (SLAM || FAKE || !v.videoWidth) return [nx * W, ny * H];
  const s = Math.max(W / v.videoWidth, H / v.videoHeight);
  const dx = (W - v.videoWidth * s) / 2, dy = (H - v.videoHeight * s) / 2;
  return [dx + nx * v.videoWidth * s, dy + ny * v.videoHeight * s];
}

function drawAR() {
  const c = $('#ar');
  const W = c.clientWidth, H = c.clientHeight;
  if (!W || !state.room) return;
  const dpr = window.devicePixelRatio || 1;
  if (c.width !== W * dpr || c.height !== H * dpr) { c.width = W * dpr; c.height = H * dpr; }
  const ctx = c.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);

  // detection boxes from the model
  if (state.dets && state.dets.until > Date.now()) {
    ctx.lineWidth = 3;
    ctx.font = '700 13px system-ui';
    for (const b of state.dets.boxes) {
      const [x0, y0] = frameToScreen(b.x, b.y, W, H);
      const [x1, y1] = frameToScreen(b.x + b.w, b.y + b.h, W, H);
      ctx.strokeStyle = '#ff5d73';
      ctx.strokeRect(x0, y0, x1 - x0, y1 - y0);
      const label = [b.label, b.score != null ? `${Math.round(b.score * 100)}%` : null].filter(Boolean).join(' ');
      if (label) {
        const tw = ctx.measureText(label).width + 10;
        ctx.fillStyle = '#ff5d73';
        ctx.fillRect(x0, y0 - 20, tw, 20);
        ctx.fillStyle = '#fff';
        ctx.fillText(label, x0 + 5, y0 - 6);
      }
    }
  }

  // markers floating in the camera view
  const targets = worldTargets();
  const g = guideOffset();
  if (g !== null && state.guide.kind === 'respond') {
    targets.push({ off: g, dist: state.guide.distance ?? 3, label: 'CANDIDATE', color: '#ff5d73', kind: 'candidate' });
  }
  const seen = new Set();
  for (const t of targets) {
    if (t.kind === 'candidate' && seen.has('candidate')) continue;
    seen.add(t.kind);
    const p = project(t.off, t.dist, W, H);
    if (!p) continue;
    const [x, y] = p;
    const r = Math.max(9, Math.min(22, 60 / Math.max(t.dist, 1)));
    ctx.fillStyle = t.color;
    ctx.strokeStyle = 'rgba(0,0,0,0.6)';
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(x, y - r); ctx.lineTo(x + r, y); ctx.lineTo(x, y + r); ctx.lineTo(x - r, y); ctx.closePath();
    ctx.fill(); ctx.stroke();
    const label = `${t.label.replace(/^◆ /, '')} · ${t.dist.toFixed(1)} m`;
    ctx.font = '800 14px system-ui';
    const tw = ctx.measureText(label).width + 16;
    ctx.fillStyle = 'rgba(0,0,0,0.7)';
    ctx.beginPath(); ctx.roundRect(x - tw / 2, y - r - 30, tw, 22, 11); ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(label, x, y - r - 19);
  }
}

function updateWorldUi() {
  const w = state.world;
  if (w) {
    const pct = Math.round(w.searched * 100);
    $('#progText').innerHTML = `Room <b>${pct}%</b> searched · ${w.searchers} searcher${w.searchers === 1 ? '' : 's'}`;
    $('#progBar').style.width = `${pct}%`;
    $('#progMine').textContent = w.stats?.m2 ? `You: ${w.stats.m2} m²` : '';
  }
  const lf = $('#lookingFor');
  const show = w?.lookingFor && (phase === 'search' || phase === 'found');
  lf.classList.toggle('on', !!show);
  if (show) lf.innerHTML = `Looking for · <b>${escapeHtml(w.lookingFor)}</b>`;
}

let toastTimer = null;
function showToast(text, ttl) {
  const el = $('#toast');
  el.textContent = text;
  el.classList.remove('on');
  void el.offsetWidth; // restart the drop-in animation
  el.classList.add('on');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('on'), ttl);
}

// Short beep(s); vibration isn't available to web pages on iOS, so sound carries alerts.
function beep(freq = 880, dur = 0.12, times = 1) {
  const a = state.audio;
  if (!a) return;
  a.resume?.();
  for (let i = 0; i < times; i++) {
    const t0 = a.currentTime + i * (dur + 0.06);
    const o = a.createOscillator(), g = a.createGain();
    o.frequency.value = freq;
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(0.25, t0 + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    o.connect(g).connect(a.destination);
    o.start(t0);
    o.stop(t0 + dur + 0.02);
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (ch) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

// ---------------------------------------------------------------- ui loop
let lastUi = 0;
function tickUi(t) {
  drawCompass();
  updateGuideBanner();
  drawAR();
  if (t - lastUi > 150) {
    lastUi = t;
    $('#connDot').classList.toggle('ok', state.connected);
    $('#connText').textContent = state.connected ? 'Live' : 'Reconnecting…';
    const gps = state.gps ? `GPS ±${Math.round(state.gps.accuracy)}m` : `GPS ${state.gpsError || '…'}`;
    const why = state.slam.status !== 'NORMAL' && slamDebug.reason && slamDebug.reason !== 'UNSPECIFIED' ? ` ${slamDebug.reason}` : '';
    const slam = SLAM ? ` · SLAM ${state.slam.status}${why}${state.slam.origin ? '' : ' (uncal.)'}` : '';
    $('#stats').textContent = `${state.sent} sent · ${gps}${slam}`;
    const h = currentHeading();
    $('#heading').textContent = h === null ? 'no gyro' : `${Math.round(h)}°${state.calYaw === null ? ' (uncal.)' : ''}`;
    updateWorldUi();
    if (!$('#sheet').classList.contains('collapsed')) drawSeatMap();
  }
  requestAnimationFrame(tickUi);
}
