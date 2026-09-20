import { frameKey, freshSighting, scoreLabel } from '/web/inference-ui.js';
import { makeView, drawRoom, drawCone } from '/web/room.js';

const $ = (s) => document.querySelector(s);
// Before a search the show sits in "calibrate": every phone is scanning the
// marker, and the operator cannot start until all of them have locked on.
const IDLE_PHASE = 'calibrate';
const RUNNING_PHASES = ['search', 'found'];

let ws = null;
let room = null;
let st = null;               // latest hub state
const phones = new Map();    // id → summary
const thumbs = new Map();    // id → object URL
const sourceFrames = new Map();
let snapshotAt = 0;
let drawReference = null;
let searchBusy = false;
let dragPos = null;          // candidate position while dragging
let markerDrag = null;       // marker position while dragging
let armingMarker = false;    // next map click drops the marker
const MARKER_COLOR = '#6b4fbb';
let lastDragSend = 0;

// ---------------------------------------------------------------- socket
function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws/dashboard?role=console&thumb_fps=2`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => setConn(true);
  ws.onclose = () => { setConn(false); setTimeout(connect, 1000); };
  ws.onmessage = (ev) => (typeof ev.data === 'string' ? onJson(JSON.parse(ev.data)) : onFrame(ev.data));
}

function setConn(live) {
  if (!live) { st = null; clearSourceFrames(); renderSearch(); renderAnalysis(); }
}

function send(msg) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

function onJson(msg) {
  if (msg.type === 'hello') {
    room = msg.room;
    $('#roomName').textContent = `${room.width} × ${room.depth} m`;
    $('#joinQr').src = `/api/qr.svg?data=${encodeURIComponent(msg.joinUrl)}`;
    $('#joinUrl').textContent = msg.joinUrl;
    resizeMap();
    if (mapMode === '3d') setMapMode('3d');
  } else if (msg.type === 'mission') {
    onMission(msg);
  } else if (msg.type === 'state') {
    st = msg;
    snapshotAt = performance.now();
    phones.clear();
    for (const p of msg.phones) phones.set(p.id, p);
    for (const id of [...thumbs.keys()]) if (!phones.has(id)) { URL.revokeObjectURL(thumbs.get(id)); thumbs.delete(id); }
    render();
  }
}

function onFrame(buf) {
  const n = new DataView(buf).getUint32(0);
  const header = JSON.parse(new TextDecoder().decode(new Uint8Array(buf, 4, n)));
  const { phoneId } = header;
  const url = URL.createObjectURL(new Blob([new Uint8Array(buf, 4 + n)], { type: 'image/jpeg' }));
  if (phoneId === viewing) {
    const key = frameKey(header);
    if (sourceFrames.has(key)) URL.revokeObjectURL(sourceFrames.get(key).url);
    sourceFrames.set(key, { ...header, bytes: buf.byteLength, url: URL.createObjectURL(new Blob([new Uint8Array(buf, 4 + n)], {type: 'image/jpeg'})) });
    while (sourceFrames.size > 24 || [...sourceFrames.values()].reduce((n, frame) => n + frame.bytes, 0) > 8_000_000) {
      const first = sourceFrames.keys().next().value;
      URL.revokeObjectURL(sourceFrames.get(first).url);
      sourceFrames.delete(first);
    }
  }
  if (thumbs.has(phoneId)) URL.revokeObjectURL(thumbs.get(phoneId));
  thumbs.set(phoneId, url);
  const img = document.querySelector(`img[data-thumb="${CSS.escape(phoneId)}"]`);
  if (img) {
    img.src = url;
    img.closest('.camera-preview').querySelector('.placeholder').hidden = true;
  }
  if (phoneId === viewing) { $('#vImg').src = url; $('#vNone').style.display = 'none'; }
}

// ---------------------------------------------------------------- render
function render() {
  renderViewer();
  renderSearch();
  renderStart();
  renderMarkerBtn();
  renderMetrics();
  renderControls();
  renderPhones();
  renderLog();
}

// Connected is not the same as alive: a killed app can leave the socket open
// until the hub's silence sweep notices, so a phone with no recent frame is not
// counted as live anywhere on the console.
function isLive(p) {
  return p.connected && !p.stale;
}

// A phone counts as ready once it reports the marker locked (`calibrated`).
function readiness() {
  const live = [...phones.values()].filter(isLive);
  const scanned = live.filter((p) => p.calibrated);
  return { live: live.length, scanned: scanned.length, ready: live.length > 0 && scanned.length === live.length };
}

function running() {
  return RUNNING_PHASES.includes(st?.phase);
}

function renderStart() {
  const { live, scanned, ready } = readiness();
  const on = running();
  const btn = $('#startBtn');
  btn.textContent = on ? 'End search' : 'Start search';
  btn.classList.toggle('primary', !on);
  btn.disabled = !on && !ready;
  const hint = $('#startHint');
  hint.textContent = on ? `${live} phone${live === 1 ? '' : 's'} searching`
    : !live ? 'Waiting for phones to join'
    : ready ? `All ${live} phone${live === 1 ? '' : 's'} scanned the marker`
    : `${scanned} of ${live} phones have scanned the marker`;
  hint.classList.toggle('ready', !on && ready);
}

$('#markerBtn').addEventListener('click', () => {
  if (st?.marker) { send({ type: 'marker', remove: true }); armingMarker = false; }
  else armingMarker = !armingMarker;
  renderMarkerBtn();
});

function renderMarkerBtn() {
  const btn = $('#markerBtn');
  const placed = !!st?.marker;
  btn.textContent = placed ? 'Clear marker' : armingMarker ? 'Click the map…' : 'Place marker';
  btn.classList.toggle('arming', armingMarker && !placed);
  if (placed) armingMarker = false;
}

$('#startBtn').addEventListener('click', () => {
  send({ type: 'phase', phase: running() ? 'end' : 'search' });
});

function fmtClock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

function renderMetrics() {
  const live = [...phones.values()].filter(isLive);
  const { scanned, ready } = readiness();
  $('#mLive').textContent = live.length;
  $('#mPlaced').textContent = live.filter((p) => p.pose).length;
  $('#mScanned').textContent = `${scanned}/${live.length}`;
  $('#mScannedBox').classList.toggle('alert', live.length > 0 && !ready && !running());
  $('#mSearched').textContent = `${Math.round((st.coverage?.searched || 0) * 100)}%`;
}

function renderControls() {
  const scan = st.scan;
  $('#scanToggle').disabled = !scan?.configured;
  $('#scanToggle').textContent = scan?.enabled ? 'Stop scan' : 'Start scan';
  $('#scanToggle').setAttribute('aria-pressed', String(!!scan?.enabled));
  $('#scanRebuild').disabled = !scan?.configured || scan.running || scan.paused || scan.keyframes < 2;
  $('#scanReset').disabled = !scan || (!scan.keyframes && !scan.last);
  $('#scanStatus').textContent = !scan?.configured ? 'Connect a scanning GPU worker to start.'
    : scan.error ? `Scan failed: ${scan.error}`
    : scan.running ? `Building room from ${scan.batchSize} views…`
    : !scan.enabled ? 'Ready to scan'
    : scan.paused ? 'Leave Lobby to capture room views.'
    : `${scan.keyframes} views captured${scan.last ? ' · Room map ready' : ' · Move slowly with overlapping views'}`;
  if (mapMode === '3d' && scene3d) {
    $('#mapStatus').textContent = scene3d.status() === 'failed' ? 'Room map could not load.'
      : scene3d.status() === 'ready' ? 'Drag to orbit · Scroll to zoom · Click a camera to open its feed'
      : 'Room layout · Waiting for a reconstructed scan';
  }
  $('#plannerSw').classList.toggle('on', !!st.planner?.enabled);
  const t = st.target;
  const s = $('#candStatus');
  s.classList.toggle('found', !!t?.foundBy);
  if (st.search?.mode === 'real') {
    s.textContent = st.search.confirmation ? `Visual sighting confirmed · Phone ${st.search.confirmation.phoneId} · target location unknown` : 'No confirmed sighting';
  } else if (!t) {
    s.textContent = 'No candidate placed';
  } else if (t.foundBy) {
    const f = phones.get(t.foundBy);
    const arrived = Object.values(t.responders).filter(Boolean).length;
    const total = Object.keys(t.responders).length;
    const sure = t.confidence != null ? ` (${Math.round(t.confidence * 100)}% sure)` : '';
    s.textContent = `Found by #${f?.index ?? '?'}${sure} in ${(t.searchMs / 1000).toFixed(1)}s · ${arrived}/${total} responders arrived`;
  } else {
    const top = (st.sightings || []).reduce((a, b) => (b.confidence > (a?.confidence ?? 0) ? b : a), null);
    s.textContent = `Hidden at (${t.x.toFixed(1)}, ${t.y.toFixed(1)}) · `
      + (top && top.confidence >= 0.4 ? `possible sighting ${Math.round(top.confidence * 100)}%` : 'searching');
  }
  $('#respN').textContent = t ? t.respondersWanted : respondersPref;
  $('#lookingFor').textContent = st.lookingFor ? `Looking for: ${st.lookingFor}` : '';
  const top = st.likely?.[0];
  $('#likely').textContent = top ? `Most likely: ${top.sector} · ${Math.round(top.share * 100)}%` : '';
  const m = st.mission || {};
  renderAutonomy(m);
  $('#candBtn').disabled = st.search?.mode === 'real';
  $('#candBtn').textContent = t ? 'Remove candidate' : 'Place candidate';
  $('#candBtn').classList.toggle('primary', !t);
}

function phoneStatus(p) {
  const out = [];
  const t = st.target;
  if (t?.foundBy === p.id) out.push(['Found it', 'r']);
  if (t?.responders && p.id in t.responders) out.push(t.responders[p.id] ? ['Arrived', 'w'] : ['Responding', 'r']);
  const job = st.planner?.assignments?.[p.id];
  if (job) out.push([`→ ${job.sector}`, job.onTarget ? 'w' : '']);
  if (!p.connected) out.push(['Offline', '']);
  else if (p.stale) out.push(['No signal', 'r']);
  if (p.pitch != null && Math.abs(p.pitch) > 65) out.push([p.pitch < 0 ? 'Floor' : 'Ceiling', '']);
  if (p.hidden) out.push(['Hidden', '']);
  if (p.speaking) out.push(['🎙 Speaking', 'w']);
  if (p.oldPage && !p.sim && p.connected) out.push(['Old page · reload', 'r']);
  return out;
}

function renderPhones() {
  const list = [...phones.values()].sort((a, b) => a.index - b.index);
  $('#phoneCount').textContent = list.length;
  $('#phonesEmpty').hidden = list.length > 0;
  const body = $('#phones');
  body.hidden = !list.length;
  // Preserve cards so incoming state retains video elements and expanded details.
  const existing = new Map([...body.children].map((card) => [card.dataset.id, card]));
  list.forEach((p, i) => {
    let card = existing.get(p.id);
    if (!card) {
      card = document.createElement('article');
      card.className = 'camera-card';
      card.dataset.id = p.id;
      card.innerHTML = `<button class="camera-open" data-act="open">
        <div class="camera-preview"><span class="placeholder"></span><img class="thumb" alt="" data-thumb="${escapeHtml(p.id)}"></div>
        <div class="camera-title"><span class="idx mono muted"></span><span class="name"></span><span class="st"></span></div>
        <div class="camera-caption"></div></button>
        <details class="camera-details"><summary>Camera details</summary><dl>
        <dt>Device</dt><dd class="device"></dd><dt>Position</dt><dd class="pos"></dd>
        <dt>Heading</dt><dd class="hd"></dd><dt>Frames / second</dt><dd class="fps"></dd>
        <dt>Latency</dt><dd class="lat"></dd></dl>
        <div class="actions"><button class="btn sm" data-act="hide"></button></div></details>`;
      if (thumbs.has(p.id)) card.querySelector('img').src = thumbs.get(p.id);
    }
    existing.delete(p.id);
    if (body.children[i] !== card) body.insertBefore(card, body.children[i] || null);
    card.classList.toggle('off', !isLive(p));
    card.querySelector('.thumb').classList.toggle('hidden', p.hidden);
    card.querySelector('.placeholder').textContent = p.connected ? 'Waiting for video…' : 'Camera offline';
    card.querySelector('.placeholder').hidden = thumbs.has(p.id);
    card.querySelector('.idx').textContent = `#${p.index}`;
    card.querySelector('.name').textContent = p.name || 'Phone';
    card.querySelector('.camera-open').setAttribute('aria-label', `Open camera ${p.index}: ${p.name || 'Phone'}`);
    card.querySelector('.camera-caption').textContent = p.caption?.text || '';
    card.querySelector('.device').textContent = p.device || 'Unknown';
    const pose = p.pose;
    card.querySelector('.pos').textContent = pose ? `${pose.x.toFixed(1)}, ${pose.y.toFixed(1)} · ${pose.source}` : 'Not placed';
    card.querySelector('.hd').textContent = pose?.heading != null ? `${Math.round(pose.heading)}°` : '–';
    card.querySelector('.fps').textContent = p.fps.toFixed(1);
    card.querySelector('.lat').textContent = p.latencyMs != null ? `${p.latencyMs} ms` : '–';
    const liveBadge = !p.connected ? ['Offline · last frame', ''] : p.stale ? ['No signal', 'r'] : ['Live', 'w'];
    card.querySelector('.st').innerHTML = [liveBadge, ...phoneStatus(p).filter(([label]) => label !== 'Offline' && label !== 'No signal')].map(([s, c]) => `<span class="badge ${c}">${s}</span>`).join('');
    card.querySelector('[data-act="hide"]').textContent = p.hidden ? 'Show camera' : 'Hide camera';
  });
  for (const card of existing.values()) card.remove();
  updateCameraNavigation();
}

function updateCameraNavigation() {
  const track = $('#phones');
  $('#cameraPrev').disabled = track.scrollLeft <= 1;
  $('#cameraNext').disabled = track.scrollLeft + track.clientWidth >= track.scrollWidth - 1;
}

function scrollCameras(direction) {
  const track = $('#phones');
  const card = track.firstElementChild;
  track.scrollBy({ left: direction * (card ? card.offsetWidth + 16 : track.clientWidth), behavior: 'smooth' });
}
$('#cameraPrev').addEventListener('click', () => scrollCameras(-1));
$('#cameraNext').addEventListener('click', () => scrollCameras(1));
$('#phones').addEventListener('scroll', updateCameraNavigation, { passive: true });
window.addEventListener('resize', updateCameraNavigation);
$('#phones').addEventListener('click', (e) => {
  const action = e.target.closest('[data-act]');
  const card = e.target.closest('.camera-card');
  const p = card && phones.get(card.dataset.id);
  if (!p || !action) return;
  if (action.dataset.act === 'hide') send({ type: 'hide', phoneId: p.id, hidden: !p.hidden });
  else openViewer(p.id);
});

// ---------------------------------------------------------------- expanded feed
let viewing = null; // phone id shown large
let showHud = (() => { try { return localStorage.getItem('swarm.hud') !== '0'; } catch { return true; } })();

function openViewer(id) {
  clearSourceFrames();
  viewing = id;
  $('#vImg').removeAttribute('src');
  $('#vNone').style.display = '';
  if (thumbs.has(id)) { $('#vImg').src = thumbs.get(id); $('#vNone').style.display = 'none'; }
  $('#viewer').classList.add('on');
  send({ type: 'focus', phoneId: id }); // hub streams this phone faster while it's open
  renderViewer();
}

function closeViewer() {
  viewing = null;
  clearSourceFrames();
  clearHud();
  $('#viewer').classList.remove('on');
  send({ type: 'focus', phoneId: null });
}

function stepViewer(d) {
  const list = [...phones.values()].sort((a, b) => a.index - b.index);
  const i = list.findIndex((p) => p.id === viewing);
  if (list.length) openViewer(list[(i + d + list.length) % list.length].id);
}

function renderViewer() {
  if (!viewing) return;
  renderAnalysis();
  const p = phones.get(viewing);
  if (!p) { closeViewer(); return; }
  $('#vNum').textContent = `#${p.index}`;
  const cap = $('#vCap');
  cap.textContent = p.caption ? p.caption.text : p.speaking ? '…' : '';
  cap.classList.toggle('on', !!(p.caption || p.speaking));
  $('#vName').textContent = p.name || 'Phone';
  $('#vDevice').textContent = p.device || '';
  $('#vBadges').innerHTML = phoneStatus(p).map(([s, c]) => `<span class="badge ${c}">${s}</span>`).join('');
  $('#vHide').textContent = p.hidden ? 'Show on projector' : 'Hide from projector';
  const pose = p.pose;
  const job = st.planner?.assignments?.[p.id];
  $('#vTask').textContent = p.task || (job ? `searching ${job.sector}${job.gain ? ` · ${(job.gain * 100).toFixed(1)}% find chance` : ''}` : 'idle');
  $('#vPos').textContent = pose ? `${pose.x.toFixed(1)}, ${pose.y.toFixed(1)} · ${pose.source}` : 'not placed';
  $('#vHd').textContent = pose?.heading != null ? `${Math.round(pose.heading)}°` : '–';
  $('#vPitch').textContent = p.pitch != null ? `${Math.round(p.pitch)}°` : '–';
  $('#vFps').textContent = p.fps.toFixed(1);
  $('#vLat').textContent = p.latencyMs != null ? `${p.latencyMs}ms` : '–';
  $('#vM2').textContent = `${p.searchedM2 ?? 0} m²`;
}

$('#vClose').addEventListener('click', closeViewer);
$('#vHud').addEventListener('click', toggleHud);
$('#vHud').classList.toggle('on', showHud);
function toggleHud() {
  showHud = !showHud;
  try { localStorage.setItem('swarm.hud', showHud ? '1' : '0'); } catch {}
  $('#vHud').classList.toggle('on', showHud);
}

// ---------------------------------------------------------------- phone HUD mirror
// Redraws what's on the viewed phone's screen over its feed, from the description the phone sends.
const CARD = { 0: 'N', 45: 'NE', 90: 'E', 135: 'SE', 180: 'S', 225: 'SW', 270: 'W', 315: 'NW' };
const TONES = { ok: ['#7ae582', '#04210a'], alert: ['#ff5d73', '#ffffff'], warn: ['#ffb703', '#1a1200'] };

function clearHud() {
  const c = $('#vHudCanvas');
  c.getContext('2d').clearRect(0, 0, c.width, c.height);
}

function drawHud() {
  requestAnimationFrame(drawHud);
  if (!viewing) return;
  const c = $('#vHudCanvas');
  const img = $('#vImg');
  const ctx = c.getContext('2d');
  const box = img.getBoundingClientRect(), host = c.parentElement.getBoundingClientRect();
  const W = box.width, H = box.height;
  const dpr = window.devicePixelRatio || 1;
  c.style.left = `${box.left - host.left}px`;
  c.style.top = `${box.top - host.top}px`;
  c.style.width = `${W}px`;
  c.style.height = `${H}px`;
  if (c.width !== Math.round(W * dpr) || c.height !== Math.round(H * dpr)) {
    c.width = Math.round(W * dpr); c.height = Math.round(H * dpr);
  }
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);
  const hud = phones.get(viewing)?.hud;
  if (!showHud || !hud || !W || !img.getAttribute('src')) return;

  // the phone's screen shows a crop of the frame: dim what the person can't see
  let sx = 0, sy = 0, sw = W, sh = H;
  if (hud.screen) {
    const [a, b, e, f] = hud.screen;
    sx = Math.max(0, a * W); sy = Math.max(0, b * H);
    sw = Math.min(W, e * W) - sx; sh = Math.min(H, f * H) - sy;
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.fillRect(0, 0, W, sy); ctx.fillRect(0, sy + sh, W, H - sy - sh);
    ctx.fillRect(0, sy, sx, sh); ctx.fillRect(sx + sw, sy, W - sx - sw, sh);
    ctx.strokeStyle = 'rgba(255,255,255,0.35)';
    ctx.lineWidth = 1;
    ctx.strokeRect(sx + 0.5, sy + 0.5, sw - 1, sh - 1);
  }
  const k = sw / 390; // scale phone-sized HUD elements to the drawn screen (≈ iPhone width in CSS px)
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';

  // detection boxes and AR markers live in frame coordinates
  for (const d of hud.dets || []) {
    ctx.strokeStyle = '#ff5d73';
    ctx.lineWidth = 2;
    ctx.strokeRect(d.x * W, d.y * H, d.w * W, d.h * H);
  }
  for (const m of hud.ar || []) {
    const x = m.x * W, y = m.y * H, r = Math.max(6, m.r * sh);
    ctx.fillStyle = m.color;
    ctx.strokeStyle = 'rgba(0,0,0,0.6)';
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(x, y - r); ctx.lineTo(x + r, y); ctx.lineTo(x, y + r); ctx.lineTo(x - r, y); ctx.closePath();
    ctx.fill(); ctx.stroke();
    pill(ctx, x, y - r - 13 * k, m.label, 'rgba(0,0,0,0.7)', '#fff', 12 * k);
  }

  // screen-space HUD, stacked from the top of the phone's screen
  let top = sy + 8 * k;
  if (hud.compass) { drawTape(ctx, sx + 8 * k, top, sw - 16 * k, 40 * k, hud.compass, k); top += 48 * k; }
  if (hud.banner) {
    const [bg, fg] = TONES[hud.banner.tone] || TONES.warn;
    pill(ctx, sx + sw / 2, top + 16 * k, hud.banner.text, bg, fg, 15 * k, true);
    top += 40 * k;
  }
  if (hud.lookingFor) { pill(ctx, sx + sw / 2, top + 12 * k, hud.lookingFor, 'rgba(12,17,32,0.85)', '#eef2ff', 12 * k); top += 30 * k; }
  if (hud.toast) { pill(ctx, sx + sw / 2, top + 14 * k, hud.toast, 'rgba(255,255,255,0.95)', '#05070f', 13 * k, true); top += 36 * k; }
  if (hud.card) {
    const cy = sy + sh * 0.42;
    ctx.fillStyle = 'rgba(0,0,0,0.8)';
    ctx.beginPath(); ctx.roundRect(sx + 16 * k, cy - 40 * k, sw - 32 * k, 80 * k, 14 * k); ctx.fill();
    ctx.fillStyle = '#fff';
    ctx.font = `700 ${18 * k}px Geist, system-ui`;
    ctx.fillText(hud.card.title, sx + sw / 2, cy - 12 * k);
    ctx.fillStyle = '#a1a1a1';
    ctx.font = `${12 * k}px Geist, system-ui`;
    ctx.fillText(hud.card.text, sx + sw / 2, cy + 14 * k);
  }
}

function pill(ctx, x, y, text, bg, fg, size, bold = false) {
  ctx.font = `${bold ? 700 : 600} ${size}px Geist, system-ui`;
  const w = ctx.measureText(text).width + size * 1.4, h = size * 1.9;
  ctx.fillStyle = bg;
  ctx.beginPath(); ctx.roundRect(x - w / 2, y - h / 2, w, h, h / 2); ctx.fill();
  ctx.fillStyle = fg;
  ctx.fillText(text, x, y + 0.5);
}

function drawTape(ctx, x0, y0, w, h, cmp, k) {
  const SPAN = 120, ppd = w / SPAN, cx = x0 + w / 2;
  ctx.save();
  ctx.fillStyle = 'rgba(12,17,32,0.82)';
  ctx.beginPath(); ctx.roundRect(x0, y0, w, h, 10 * k); ctx.fill(); ctx.clip();
  for (let d = Math.ceil((cmp.center - SPAN / 2) / 5) * 5; d <= cmp.center + SPAN / 2; d += 5) {
    const x = cx + (d - cmp.center) * ppd;
    const dd = ((d % 360) + 360) % 360;
    const major = dd % 15 === 0;
    ctx.strokeStyle = major ? 'rgba(255,255,255,0.7)' : 'rgba(255,255,255,0.3)';
    ctx.lineWidth = major ? 1.5 : 1;
    ctx.beginPath(); ctx.moveTo(x, y0 + h - (major ? 10 : 6) * k); ctx.lineTo(x, y0 + h - 2); ctx.stroke();
    if (major) {
      const card = cmp.abs ? CARD[dd] : null;
      ctx.fillStyle = card ? '#fff' : 'rgba(255,255,255,0.55)';
      ctx.font = `${card ? 800 : 600} ${(card ? 11 : 9) * k}px system-ui`;
      ctx.fillText(card ?? String(dd), x, y0 + h - 18 * k);
    }
  }
  for (const m of cmp.markers) {
    const edge = Math.abs(m.off) > SPAN / 2 - 8;
    const x = edge ? (m.off > 0 ? x0 + w - 18 * k : x0 + 18 * k) : cx + m.off * ppd;
    const label = edge ? (m.off > 0 ? `${m.label} ▶` : `◀ ${m.label}`) : m.label;
    ctx.font = `800 ${(m.big ? 10 : 9) * k}px system-ui`;
    const tw = ctx.measureText(label).width + 10 * k;
    const bx = Math.max(x0 + 2, Math.min(x0 + w - tw - 2, x - tw / 2));
    ctx.fillStyle = m.color;
    ctx.beginPath(); ctx.roundRect(bx, y0 + 2 * k, tw, 14 * k, 7 * k); ctx.fill();
    ctx.fillStyle = '#05070f';
    ctx.fillText(label, bx + tw / 2, y0 + 9.5 * k);
  }
  ctx.restore();
  ctx.fillStyle = '#fff';
  ctx.beginPath(); ctx.moveTo(cx - 5 * k, y0 + h); ctx.lineTo(cx + 5 * k, y0 + h); ctx.lineTo(cx, y0 + h - 6 * k); ctx.fill();
}
requestAnimationFrame(drawHud);
$('#vHide').addEventListener('click', () => {
  const p = phones.get(viewing);
  if (p) send({ type: 'hide', phoneId: p.id, hidden: !p.hidden });
});
$('#viewer').addEventListener('click', (e) => { if (e.target === $('#viewer')) closeViewer(); });

function renderLog() {
  const log = [...(st.planner?.log || [])].reverse().slice(0, 5);
  if (!log.length) { $('#log').innerHTML = '<div class="empty">Nothing yet</div>'; return; }
  $('#log').innerHTML = log.map((e) => {
    const p = e.phoneId && phones.get(e.phoneId);
    const who = p ? `<b>#${p.index}</b> ` : '';
    const t = new Date(e.t).toLocaleTimeString([], { hour12: false });
    const hot = /FOUND|dispatched/.test(e.text) ? ' hot' : '';
    return `<div class="ev${hot}"><time>${t}</time><div>${who}${escapeHtml(e.text)}</div></div>`;
  }).join('');
}

// ---------------------------------------------------------------- mission control
const runs = new Map(); // id → {el, acts}
$('#mcForm').addEventListener('submit', (e) => {
  e.preventDefault();
  const text = $('#mcInput').value.trim();
  if (!text) return;
  send({ type: 'mission', text });
  $('#mcInput').value = '';
});

function onMission(ev) {
  let run = runs.get(ev.id);
  if (ev.event === 'start') {
    const el = document.createElement('div');
    el.className = 'mc';
    el.innerHTML = `<div class="cmd"><b></b><span class="ms"></span></div><div class="acts"></div>
      <div class="reply"><span class="spin"></span>Thinking…</div>`;
    el.querySelector('b').textContent = ev.text;
    $('#mcFeed').prepend(el);
    run = { el };
    runs.set(ev.id, run);
    while ($('#mcFeed').children.length > 3) $('#mcFeed').lastElementChild.remove();
    return;
  }
  if (!run) return;
  if (ev.event === 'action') {
    const chip = document.createElement('span');
    chip.className = `chip${ev.ok ? '' : ' bad'}`;
    chip.textContent = `${ev.ok ? '✓' : '✕'} ${ev.result}`;
    chip.title = `${ev.name}(${JSON.stringify(ev.args)})`;
    run.el.querySelector('.acts').append(chip);
  } else if (ev.event === 'done' || ev.event === 'error') {
    const r = run.el.querySelector('.reply');
    r.classList.toggle('err', ev.event === 'error');
    r.textContent = ev.event === 'done' ? ev.reply : ev.message;
    if (ev.ms) run.el.querySelector('.ms').textContent = `${(ev.ms / 1000).toFixed(1)}s`;
    runs.delete(ev.id);
  }
}

// ---------------------------------------------------------------- autonomy
let recsKey = '';
let explaining = null; // id of the autonomy action whose evidence is shown on the map

function renderAutonomy(m) {
  const on = !!m.autonomy;
  $('#autoSw').classList.toggle('on', on);
  $('#autoSw').setAttribute('aria-pressed', String(on));
  $('#chatOpen').classList.toggle('active', on);
  $('#chatOpen').setAttribute('aria-label', `Open Mission Control, autonomy ${on ? 'active' : 'paused'}`);
  // live feed of what autonomy did (newest first, last minute), plus the one being explained
  const all = m.recs || [];
  let recs = all.filter((r) => r.ageS < 60).slice(0, 4);
  const sel = all.find((r) => r.id === explaining);
  if (explaining && !sel) explaining = null; // aged out of the hub's history
  if (sel && !recs.includes(sel)) recs = [sel, ...recs.slice(0, 3)];
  const key = JSON.stringify([explaining, recs.map((r) => r.id)]);
  if (key === recsKey) return; // unchanged: don't rebuild
  recsKey = key;
  $('#recs').innerHTML = recs.map((r) => `<div class="rec ${r.id === explaining ? 'sel' : ''}" data-rec="${r.id}">
      <span class="sev ${r.severity}"></span>
      <div><div class="t">${escapeHtml(r.title)}</div><div class="why">${escapeHtml(r.reason)}</div>
      <div class="acts">${r.results.map((t) => `<span class="chip">${escapeHtml(t)}</span>`).join('')}</div>
      ${r.id === explaining ? evidenceHtml(r.evidence) : ''}</div>
      <span class="state ${r.status === 'failed' ? '' : 'auto'}">${r.status === 'failed' ? '✕ failed' : '⚡ done'}</span></div>`).join('');
}

// ---------------------------------------------------------------- explain a decision
// Click an autonomy action: its card lists what it was based on (captured when it was decided),
// and the map highlights the same evidence. Click again or press Esc to clear.
function evidenceHtml(ev) {
  if (!ev) return '<div class="evidence">No evidence was recorded for this action.</div>';
  const pos = (x, y) => (x != null ? `(${x.toFixed(1)}, ${y.toFixed(1)})` : '');
  const rows = [];
  if (ev.phones?.length) {
    rows.push(['Ordered', ev.phones.map((p) => {
      const d = ev.point && p.x != null ? ` · ${Math.hypot(ev.point[0] - p.x, ev.point[1] - p.y).toFixed(1)} m away` : '';
      return `#${p.index} at ${pos(p.x, p.y)}${d}`;
    }).join('; ')]);
  }
  if (ev.point) rows.push(['Target', `${ev.sector ? `sector ${ev.sector} ` : ''}${pos(ev.point[0], ev.point[1])}`]);
  for (const s of ev.speech || []) rows.push(['Heard', `#${s.index} ${pos(s.x, s.y)}: “${s.text}”`]);
  if (ev.sighting) rows.push(['Sighting', `${Math.round(ev.sighting.confidence * 100)}% at ${pos(ev.sighting.x, ev.sighting.y)}`]);
  if (ev.likely?.length) rows.push(['Most likely then', ev.likely.map((l) => `${l.sector} ${Math.round(l.share * 100)}%`).join(' · ')]);
  return `<div class="evidence">${rows.map(([k, v]) => `<div><span class="k">${k}</span>${escapeHtml(v)}</div>`).join('')}
    <div class="explain-hint">Highlighted on the map · click again or Esc to clear</div></div>`;
}

$('#recs').addEventListener('click', (e) => {
  const card = e.target.closest('[data-rec]');
  if (!card) return;
  const id = Number(card.dataset.rec);
  explaining = explaining === id ? null : id;
  recsKey = ''; // rebuild the feed now
  if (st?.mission) renderAutonomy(st.mission);
});

function drawExplain() {
  const r = explaining && st.mission?.recs?.find((x) => x.id === explaining);
  const ev = r?.evidence;
  if (!ev) return;
  const W = canvas.clientWidth, H = canvas.clientHeight;
  ctx.save();
  ctx.fillStyle = 'rgba(0,0,0,0.45)'; // dim everything else so the evidence stands out
  ctx.fillRect(0, 0, W, H);
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.font = '500 11px "Geist Mono", ui-monospace, monospace';
  // what was most likely at the time
  const size = st.planner?.sectorSize || 2.5, x0 = -room.width / 2;
  for (const l of ev.likely || []) {
    const c = l.sector.charCodeAt(0) - 65, row = Number(l.sector.slice(1)) - 1;
    const [ax, ay] = view.toPx(x0 + c * size, row * size);
    const [bx, by] = view.toPx(x0 + (c + 1) * size, (row + 1) * size);
    ctx.setLineDash([3, 3]);
    ctx.strokeStyle = 'rgba(255,255,255,0.5)';
    ctx.lineWidth = 1;
    ctx.strokeRect(ax, ay, bx - ax, by - ay);
    ctx.setLineDash([]);
    ctx.fillStyle = 'rgba(255,255,255,0.7)';
    ctx.fillText(`${l.sector} ${Math.round(l.share * 100)}%`, (ax + bx) / 2, (ay + by) / 2);
  }
  // the sighting it was reacting to
  if (ev.sighting) {
    const [sx, sy] = view.toPx(ev.sighting.x, ev.sighting.y);
    ctx.strokeStyle = '#ff4d4d';
    ctx.lineWidth = 1.5;
    ctx.setLineDash([4, 4]);
    ctx.beginPath(); ctx.arc(sx, sy, 15, 0, Math.PI * 2); ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = '#ff4d4d';
    ctx.fillText(`sighting ${Math.round(ev.sighting.confidence * 100)}%`, sx, sy - 24);
  }
  // who was sent, from where they were at the time, to where
  let tx = null, ty = null;
  if (ev.point) {
    [tx, ty] = view.toPx(ev.point[0], ev.point[1]);
    if (ev.sector) {
      const c = ev.sector.charCodeAt(0) - 65, row = Number(ev.sector.slice(1)) - 1;
      const [ax, ay] = view.toPx(x0 + c * size, row * size);
      const [bx, by] = view.toPx(x0 + (c + 1) * size, (row + 1) * size);
      ctx.strokeStyle = '#ededed';
      ctx.lineWidth = 2;
      ctx.strokeRect(ax, ay, bx - ax, by - ay);
    }
  }
  for (const p of ev.phones || []) {
    if (p.x == null) continue;
    const [px, py] = view.toPx(p.x, p.y);
    if (tx != null) {
      ctx.strokeStyle = '#ededed';
      ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.moveTo(px, py); ctx.lineTo(tx, ty); ctx.stroke();
    }
    ctx.strokeStyle = '#ededed';
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(px, py, 10, 0, Math.PI * 2); ctx.stroke();
    ctx.fillStyle = '#ededed';
    ctx.fillText(`#${p.index}`, px, py - 18);
  }
  if (tx != null) {
    ctx.fillStyle = '#ededed';
    ctx.beginPath(); ctx.arc(tx, ty, 5, 0, Math.PI * 2); ctx.fill();
    ctx.beginPath(); ctx.arc(tx, ty, 11, 0, Math.PI * 2); ctx.lineWidth = 1.5; ctx.stroke();
  }
  // what someone said that prompted it
  for (const s of ev.speech || []) {
    if (s.x == null) continue;
    const [px, py] = view.toPx(s.x, s.y);
    const text = `“${s.text.length > 44 ? `${s.text.slice(0, 43)}…` : s.text}”`;
    ctx.font = '500 12px Geist, system-ui';
    const w = ctx.measureText(text).width + 16;
    const bx = Math.max(4, Math.min(W - w - 4, px - w / 2)), by = Math.max(4, py - 46);
    ctx.fillStyle = '#ededed';
    ctx.beginPath(); ctx.roundRect(bx, by, w, 24, 6); ctx.fill();
    ctx.beginPath(); ctx.moveTo(px - 5, by + 24); ctx.lineTo(px + 5, by + 24); ctx.lineTo(px, by + 30); ctx.fill();
    ctx.fillStyle = '#000';
    ctx.fillText(text, bx + w / 2, by + 12.5);
    ctx.strokeStyle = '#ededed';
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(px, py, 9, 0, Math.PI * 2); ctx.stroke();
  }
  ctx.restore();
}

$('#autoSw').addEventListener('click', () => send({ type: 'autonomy', enabled: !st?.mission?.autonomy }));

// ---------------------------------------------------------------- controls
let respondersPref = 3;
$('#plannerSw').addEventListener('click', () => send({ type: 'planner', enabled: !st?.planner?.enabled }));
$('#resetCov').addEventListener('click', () => send({ type: 'reset_coverage' }));
$('#resetSession').addEventListener('click', () => {
  if (st?.search?.mode === 'rehearsal') send({ type: 'target', remove: true });
  send({ type: 'reset_coverage' });
  send({ type: 'phase', phase: IDLE_PHASE, restart: true });
  $('#searchMessage').textContent = '';
});
$('#candBtn').addEventListener('click', toggleCandidate);
$('#respMinus').addEventListener('click', () => setResponders(-1));
$('#respPlus').addEventListener('click', () => setResponders(+1));


function toggleCandidate() {
  if (st?.target) send({ type: 'target', remove: true });
  else send({ type: 'target', x: 0, y: room.depth / 2, responders: respondersPref });
}

function setResponders(d) {
  respondersPref = Math.max(0, Math.min(10, (st?.target?.respondersWanted ?? respondersPref) + d));
  $('#respN').textContent = respondersPref;
  if (st?.target) send({ type: 'target', responders: respondersPref });
}

function toggleChat(open, restoreFocus = true) {
  $('#chatPanel').hidden = !open;
  document.body.classList.toggle('chat-docked', open);
  $('#chatOpen').setAttribute('aria-expanded', String(open));
  if (open) $('#mcInput').focus();
  else if (restoreFocus) $('#chatOpen').focus();
  resizeMap();
}

$('#chatClose').addEventListener('click', () => toggleChat(false));
$('#chatOpen').addEventListener('click', () => toggleChat($('#chatPanel').hidden));
document.addEventListener('click', (event) => {
  if (!$('#chatPanel').hidden && !event.target.closest('#chatPanel, #chatOpen')) {
    toggleChat(false, false);
  }
});
$('#chatPanel').addEventListener('keydown', (event) => {
  if (event.key === 'Escape') { event.stopPropagation(); toggleChat(false); }
});

$('#settingsOpen').addEventListener('click', () => $('#settings').showModal());
$('#settingsClose').addEventListener('click', () => $('#settings').close());
$('#settings').addEventListener('click', (event) => {
  if (event.target !== event.currentTarget) return;
  const rect = event.currentTarget.getBoundingClientRect();
  if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) {
    event.currentTarget.close();
  }
});

$('#joinBtn').addEventListener('click', (e) => { e.stopPropagation(); $('#joinPop').classList.toggle('on'); });
document.addEventListener('click', (e) => { if (!e.target.closest('.joinWrap')) $('#joinPop').classList.remove('on'); });

window.addEventListener('keydown', (e) => {
  if ($('#settings').open && e.key === 'Escape') return;
  if (e.key === 'Escape' && e.target === $('#mcInput')) { e.target.blur(); return; }
  if (viewing && !e.target.closest?.('input, textarea')) {
    if (e.key === 'Escape') { closeViewer(); return; }
    if (e.key === 'ArrowRight') { stepViewer(1); return; }
    if (e.key === 'ArrowLeft') { stepViewer(-1); return; }
    if (e.key === 'h' || e.key === 'H') { toggleHud(); return; }
  }
  if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest?.('input, textarea')) return;
  if (e.key === '/' && !$('#settings').open) { e.preventDefault(); toggleChat(true); return; }
  if (e.key === 'Escape' && explaining) { explaining = null; recsKey = ''; if (st?.mission) renderAutonomy(st.mission); return; }
  if (e.key === 'm' || e.key === 'M') { send({ type: 'autonomy', enabled: !st?.mission?.autonomy }); return; }
  if (e.key === 'p' || e.key === 'P') send({ type: 'planner', enabled: !st?.planner?.enabled });
});

// ---------------------------------------------------------------- map (monochrome)
let mapMode = 'heatmap';
let scene3d = null;
let scene3dLoading = null;

async function setMapMode(mode) {
  if (mode !== 'heatmap' && mode !== '3d') return;
  mapMode = mode;
  for (const button of document.querySelectorAll('#mapModes button')) {
    button.setAttribute('aria-pressed', String(button.dataset.mode === mode));
  }
  const is3d = mode === '3d';
  $('#map').hidden = is3d;
  $('#mapWrap').classList.toggle('mode-3d', is3d);
  $('#scene3d').hidden = !is3d;
  $('#mapStatus').textContent = '';
  if (!is3d) { scene3d?.hide(); resizeMap(); return; }
  if (!room) { $('#mapStatus').textContent = 'Waiting for room data…'; return; }
  if (!scene3d) {
    $('#mapStatus').textContent = 'Loading 3D map…';
    // Reuse initialization when the view is switched while the module is loading.
    scene3dLoading ??= import('/web/scene3d.js').then(({createScene3D}) => {
      scene3d = createScene3D($('#scene3d'), {
        room, getState: () => st, getThumb: (id) => thumbs.get(id), onPick: openViewer,
      });
      $('#scene3d').addEventListener('dblclick', () => scene3d.resetView());
      return scene3d;
    }).catch((error) => { scene3dLoading = null; throw error; });
    try { await scene3dLoading; }
    catch (error) {
      if (mapMode === '3d') $('#mapStatus').textContent = '3D map unavailable. Check WebGL and your internet connection, or switch to Heatmap.';
      return;
    }
  }
  if (mapMode === '3d') {
    scene3d.show();
    $('#mapStatus').textContent = st?.scan?.last || room.scene?.url
      ? 'Drag to orbit · Scroll to zoom · Click a camera to open its feed'
      : 'Room layout, not a live scan · Drag to orbit · Scroll to zoom';
  }
}
$('#mapModes').addEventListener('click', (event) => {
  const button = event.target.closest('[data-mode]');
  if (button) setMapMode(button.dataset.mode);
});
window.addEventListener('pagehide', () => scene3d?.hide());

const canvas = $('#map');
const ctx = canvas.getContext('2d');
let view = null;
const coverageLayer = document.createElement('canvas');
let coverageKey = '';
const mapLabelRects = [];
/// How much of the camera's real range the map's view wedge draws.
const CONE_DRAW_SCALE = 0.6;
const MAP_MARKER_RADIUS = 10;
const MAP_MARKER_STROKE = 2;
const MAP_LABEL_HEIGHT = 18;
const MAP_LABEL_GAP = 4;

function resizeMap() {
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w || !room) return;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = w * dpr;
  canvas.height = h * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  view = makeView(room, w, h, 28);
  $('.map-scale i').style.width = `${Math.round(5 * view.scale)}px`;
  coverageKey = '';
}
new ResizeObserver(resizeMap).observe($('#mapWrap'));

function drawCoverage(cov) {
  if (!cov?.heat) return;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  const key = `${w}x${h}:${cov.heat}`;
  if (key !== coverageKey) {
    coverageKey = key;
    coverageLayer.width = w;
    coverageLayer.height = h;
    const layer = coverageLayer.getContext('2d');
    layer.clearRect(0, 0, w, h);
    const values = [...cov.heat].map(value => parseInt(value, 36) / 35);
    const low = Math.min(...values), high = Math.max(...values);
    if (high - low > 0.04) {
      const radius = Math.max(10, cov.cell * view.scale * 1.8);
      layer.filter = `blur(${Math.max(5, radius * .45)}px)`;
      for (let row = 0; row < cov.rows; row++) {
        for (let col = 0; col < cov.cols; col++) {
          const level = (values[row * cov.cols + col] - low) / (high - low);
          if (level < 0.16) continue;
          const [x, y] = view.toPx(cov.x0 + (col + .5) * cov.cell, (row + .5) * cov.cell);
          layer.fillStyle = `rgba(24,131,75,${(.025 + .16 * level * level).toFixed(3)})`;
          layer.beginPath();
          layer.arc(x, y, radius, 0, Math.PI * 2);
          layer.fill();
        }
      }
      layer.filter = 'none';
    }
  }
  ctx.drawImage(coverageLayer, 0, 0);
}

function draw() {
  requestAnimationFrame(draw);
  if (!view || !st || mapMode === '3d') return;
  ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);

  // A soft probability field keeps attention on meaningful hotspots without exposing the cell grid.
  drawRoom(ctx, room, view, {
    grid: false,
    colors: { floor: 'rgba(255,255,255,.5)', wall: '#789b85', stage: '#deeee3', text: '#466653' },
  });
  drawCoverage(st.coverage);

  // planner assignments: thin dashed lines to the sector
  const x0 = -room.width / 2;
  for (const [pid, job] of Object.entries(st.planner?.assignments || {})) {
    const p = phones.get(pid);
    if (!p?.pose) continue;
    const size = st.planner.sectorSize;
    const c = job.sector.charCodeAt(0) - 65, r = Number(job.sector.slice(1)) - 1;
    const [ax, ay] = view.toPx(x0 + c * size, r * size);
    const [bx, by] = view.toPx(x0 + (c + 1) * size, (r + 1) * size);
    ctx.fillStyle = 'rgba(24,131,75,.07)';
    ctx.fillRect(ax, ay, bx - ax, by - ay);
    ctx.strokeStyle = 'rgba(24,131,75,.42)';
    ctx.lineWidth = 1.25;
    ctx.setLineDash([5, 4]);
    ctx.strokeRect(ax + 0.5, ay + 0.5, bx - ax - 1, by - ay - 1);
    ctx.setLineDash([]);
    ctx.fillStyle = '#126b3c';
    ctx.font = '600 10px "Geist Mono", ui-monospace, monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(job.sector, (ax + bx) / 2, (ay + by) / 2);
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    ctx.setLineDash([3, 4]);
    ctx.beginPath(); ctx.moveTo(px, py); ctx.lineTo((ax + bx) / 2, (ay + by) / 2); ctx.stroke();
    ctx.setLineDash([]);
  }

  const list = [...phones.values()].filter((p) => p.pose);
  for (const p of list) {
    if (p.pose.heading == null || st.phase === 'lobby') continue; // lobby: locations only
    // Angle is the camera's; reach is deliberately shorter than `coneLength`.
    // Drawn at the detector's full range the wedges from four phones covered
    // most of the floor and read as "everything is seen", which is the one
    // thing the map exists to disprove. The hub still plans at the real range.
    drawCone(ctx, view, p.pose.x, p.pose.y, p.pose.heading, room.cameraFovDeg, room.coneLength * CONE_DRAW_SCALE,
      p.connected ? 'rgba(24,131,75,0.12)' : 'rgba(24,131,75,0.025)');
  }
  mapLabelRects.length = 0;
  drawMarker();
  drawSightings();
  drawCandidate();
  drawPings();
  drawExplain();
  for (const p of list) {
    drawPhone(p);
  }
}

// The printed alignment marker, wherever the operator put it. Drawn as a tag
// rather than a dot so it reads as a thing on a wall, not another searcher.
function drawMarker() {
  const m = markerDrag || st.marker;
  if (!m) return;
  const [x, y] = view.toPx(m.x, m.y);
  ctx.save();
  ctx.translate(x, y);
  ctx.fillStyle = '#fff';
  ctx.strokeStyle = MARKER_COLOR;
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.roundRect(-8, -8, 16, 16, 3);
  ctx.fill();
  ctx.stroke();
  ctx.fillStyle = MARKER_COLOR;
  ctx.fillRect(-4, -4, 4, 4);
  ctx.fillRect(1, 1, 4, 4);
  ctx.restore();
  drawMapLabel('MARKER', x, y - 19, MARKER_COLOR);
}

function drawPhone(phone) {
  const [x, y] = view.toPx(phone.pose.x, phone.pose.y);
  const responding = st.target?.responders && phone.id in st.target.responders && !st.target.responders[phone.id];
  const color = responding ? '#d97706' : '#18834b';
  ctx.save();
  ctx.globalAlpha = phone.connected ? 1 : .38;
  ctx.translate(x, y);
  ctx.shadowColor = 'rgba(23,55,38,.16)';
  ctx.shadowBlur = 7;
  ctx.shadowOffsetY = 2;
  if (phone.pose.heading != null) {
    ctx.rotate(phone.pose.heading * Math.PI / 180);
    ctx.fillStyle = color;
    ctx.beginPath();
    ctx.moveTo(0, -16); ctx.lineTo(5, -8); ctx.lineTo(-5, -8); ctx.closePath();
    ctx.fill();
    ctx.rotate(-phone.pose.heading * Math.PI / 180);
  }
  ctx.fillStyle = color;
  ctx.strokeStyle = '#fff';
  ctx.lineWidth = MAP_MARKER_STROKE;
  ctx.beginPath(); ctx.arc(0, 0, MAP_MARKER_RADIUS, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
  ctx.shadowColor = 'transparent';
  ctx.fillStyle = '#fff';
  ctx.font = '600 10px "Geist Mono", ui-monospace, monospace';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(String(phone.index), 0, .5);
  ctx.restore();
}

function drawPersonGlyph(x, y, color, background = '#fff') {
  ctx.save();
  ctx.translate(x, y);
  ctx.fillStyle = background;
  ctx.strokeStyle = color;
  ctx.lineWidth = MAP_MARKER_STROKE;
  ctx.beginPath(); ctx.arc(0, 0, MAP_MARKER_RADIUS, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
  ctx.fillStyle = color;
  ctx.beginPath(); ctx.arc(0, -3.5, 2.7, 0, Math.PI * 2); ctx.fill();
  ctx.beginPath(); ctx.roundRect(-4.5, .5, 9, 5.5, 3); ctx.fill();
  ctx.restore();
}

function reserveMapLabel(x, preferredY, width, height = 18) {
  const gap = 3;
  const halfWidth = width / 2;
  const safeX = Math.max(halfWidth + 4, Math.min(canvas.clientWidth - halfWidth - 4, x));
  const offsets = [0, -22, -44, 22, 44, -66, 66];
  for (const offset of offsets) {
    const y = Math.max(height / 2 + 4, Math.min(canvas.clientHeight - height / 2 - 4, preferredY + offset));
    const rect = {left: safeX - halfWidth, right: safeX + halfWidth, top: y - height / 2, bottom: y + height / 2};
    const overlaps = mapLabelRects.some(other => rect.left < other.right + gap && rect.right > other.left - gap
      && rect.top < other.bottom + gap && rect.bottom > other.top - gap);
    if (!overlaps) {
      mapLabelRects.push(rect);
      return {x: safeX, y};
    }
  }
  const y = Math.max(height / 2 + 4, Math.min(canvas.clientHeight - height / 2 - 4, preferredY));
  return {x: safeX, y};
}

function drawMapLabel(text, x, y, background, foreground = '#fff') {
  ctx.save();
  ctx.font = '600 10px "Geist", ui-sans-serif, system-ui';
  const width = ctx.measureText(text).width + 12;
  ({x, y} = reserveMapLabel(x, y, width));
  ctx.fillStyle = background;
  ctx.beginPath(); ctx.roundRect(x - width / 2, y - 9, width, 18, 5); ctx.fill();
  ctx.fillStyle = foreground;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText(text, x, y + .5);
  ctx.restore();
}

function personLabelY(y) {
  return y - MAP_MARKER_RADIUS - MAP_MARKER_STROKE / 2 - MAP_LABEL_GAP - MAP_LABEL_HEIGHT / 2;
}

function drawPings() {
  const now = Date.now();
  for (const pg of st.pings || []) {
    const [x, y] = view.toPx(pg.x, pg.y);
    const age = (now - pg.t) / 12000;
    const k = (performance.now() / 1000) % 1;
    ctx.save();
    ctx.globalAlpha = Math.max(0.25, 1 - age);
    ctx.strokeStyle = `rgba(24,131,75,${0.8 * (1 - k)})`;
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.arc(x, y, 6 + k * 18, 0, Math.PI * 2); ctx.stroke();
    ctx.fillStyle = '#173726';
    ctx.beginPath(); ctx.moveTo(x, y - 7); ctx.lineTo(x + 7, y); ctx.lineTo(x, y + 7); ctx.lineTo(x - 7, y); ctx.closePath(); ctx.fill();
    ctx.font = '500 11px "Geist", ui-sans-serif, system-ui';
    ctx.textAlign = 'center';
    ctx.fillText(pg.label, x, y - 14);
    ctx.restore();
  }
}

function drawSightings() {
  if (st.target?.foundBy) return;
  for (const sg of st.sightings || []) {
    if (sg.confidence < 0.4) continue;
    const [x, y] = view.toPx(sg.x, sg.y);
    const k = (performance.now() / 1000) % 1;
    ctx.save();
    ctx.strokeStyle = `rgba(217,119,6,${.55 * (1 - k)})`;
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(x, y, MAP_MARKER_RADIUS + MAP_MARKER_STROKE + 1 + k * 15, 0, Math.PI * 2); ctx.stroke();
    ctx.restore();
    drawPersonGlyph(x, y, '#d97706');
    drawMapLabel(`POSSIBLE · ${Math.round(sg.confidence * 100)}%`, x, personLabelY(y), '#d97706');
  }
}

function drawCandidate() {
  const t = st.target;
  if (!t) return;
  // the mock candidate (rehearsals): where it really is, draggable
  if (t.x != null || dragPos) {
    const [mx, my] = view.toPx((dragPos || t).x, (dragPos || t).y);
    ctx.strokeStyle = t.foundBy ? 'rgba(23,55,38,0.24)' : '#597562';
    ctx.lineWidth = 1.5;
    ctx.setLineDash([3, 3]);
    ctx.beginPath(); ctx.arc(mx, my, 8, 0, Math.PI * 2); ctx.stroke();
    ctx.setLineDash([]);
    if (!t.foundBy) drawMapLabel('TEST TARGET', mx, my - 19, '#597562');
  }
  if (!t.foundBy || !t.fix) return;
  const [cx, cy] = view.toPx(t.fix[0], t.fix[1]); // where the confirmed sighting is
  for (const [pid, arrived] of Object.entries(t.responders || {})) {
    const p = phones.get(pid);
    if (!p?.pose) continue;
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    ctx.strokeStyle = arrived ? '#173726' : '#18834b';
    ctx.lineWidth = 1.5;
    ctx.setLineDash(arrived ? [] : [4, 4]);
    ctx.beginPath(); ctx.moveTo(px, py); ctx.lineTo(cx, cy); ctx.stroke();
    ctx.setLineDash([]);
  }
  const rescued = Object.keys(t.responders || {}).length > 0 && Object.values(t.responders).every(Boolean);
  const k = (performance.now() / 1100) % 1;
  ctx.strokeStyle = `rgba(183,47,54,${.7 * (1 - k)})`;
  ctx.lineWidth = 2;
  ctx.beginPath(); ctx.arc(cx, cy, MAP_MARKER_RADIUS + MAP_MARKER_STROKE + 1 + k * 24, 0, Math.PI * 2); ctx.stroke();
  drawPersonGlyph(cx, cy, '#b72f36');
  drawMapLabel(rescued ? 'RESCUED' : 'FOUND PERSON', cx, personLabelY(cy), '#b72f36');
}

// drag the candidate
function roomPoint(e) {
  const r = canvas.getBoundingClientRect();
  const [x, y] = view.toRoom(e.clientX - r.left, e.clientY - r.top);
  return { x: Math.max(-room.width / 2, Math.min(room.width / 2, x)), y: Math.max(0, Math.min(room.depth, y)) };
}
function nearCandidate(e) {
  if (!st?.target || st.target.x == null || !view) return false;
  const r = canvas.getBoundingClientRect();
  const [cx, cy] = view.toPx(st.target.x, st.target.y);
  return Math.hypot(cx - (e.clientX - r.left), cy - (e.clientY - r.top)) <= 14;
}
function nearMarker(e) {
  if (!st?.marker || !view) return false;
  const r = canvas.getBoundingClientRect();
  const [mx, my] = view.toPx(st.marker.x, st.marker.y);
  return Math.hypot(mx - (e.clientX - r.left), my - (e.clientY - r.top)) <= 14;
}

canvas.addEventListener('mousedown', (e) => {
  if (e.altKey && view) { send({ type: 'ping', ...roomPoint(e) }); return; } // alt-click pings too
  if (armingMarker && view) {
    send({ type: 'marker', ...roomPoint(e) });
    armingMarker = false;
    renderMarkerBtn();
    e.preventDefault();
    return;
  }
  if (nearMarker(e)) { markerDrag = roomPoint(e); e.preventDefault(); return; }
  if (nearCandidate(e)) { dragPos = roomPoint(e); e.preventDefault(); return; }
  const p = phoneAt(e);
  if (p) openViewer(p.id);
});

function phoneAt(e) {
  if (!view) return null;
  const r = canvas.getBoundingClientRect();
  let best = null, bestD = 10;
  for (const p of phones.values()) {
    if (!p.pose) continue;
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    const d = Math.hypot(px - (e.clientX - r.left), py - (e.clientY - r.top));
    if (d < bestD) { best = p; bestD = d; }
  }
  return best;
}
canvas.addEventListener('contextmenu', (e) => { // right-click: ping, like Valorant
  e.preventDefault();
  if (view) send({ type: 'ping', ...roomPoint(e) });
});
canvas.addEventListener('mousemove', (e) => {
  canvas.style.cursor = armingMarker ? 'crosshair'
    : dragPos || markerDrag ? 'grabbing'
    : nearMarker(e) || nearCandidate(e) ? 'grab'
    : phoneAt(e) ? 'pointer' : 'default';
});
window.addEventListener('mousemove', (e) => {
  if (markerDrag) {
    markerDrag = roomPoint(e);
    const now = performance.now();
    if (now - lastDragSend > 80) { lastDragSend = now; send({ type: 'marker', ...markerDrag }); }
    return;
  }
  if (!dragPos) return;
  dragPos = roomPoint(e);
  const now = performance.now();
  if (now - lastDragSend > 80) { lastDragSend = now; send({ type: 'target', ...dragPos }); }
});
window.addEventListener('mouseup', () => {
  if (markerDrag) { send({ type: 'marker', ...markerDrag }); markerDrag = null; return; }
  if (!dragPos) return;
  send({ type: 'target', ...dragPos });
  dragPos = null;
});

// phase timer ticks between hub updates
setInterval(() => { if (st) $('#timer').textContent = fmtClock(Date.now() - st.phaseStartedAt); }, 250);

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

connect();
requestAnimationFrame(draw);

async function searchApi(path, options = {}) {
  const response = await fetch(path, {credentials: 'same-origin', ...options});
  const body = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(typeof body.detail === 'string' ? body.detail : `Request failed (${response.status})`);
  }
  return body;
}

function renderSearch() {
  $('#searchTools').disabled = searchBusy;
  $('#saveThreshold').disabled = searchBusy;
  $('#threshold').disabled = searchBusy;
  const search = st?.search;
  $('#clearReference').hidden = !drawReference && !search?.referenceAvailable;
  if (search && document.activeElement !== $('#threshold')) $('#threshold').value = search.threshold.toFixed(2);
}

async function searchAction(action) {
  if (searchBusy) return;
  searchBusy = true;
  renderSearch();
  try { await action(); } catch (error) { $('#searchMessage').textContent = error.message; }
  finally { searchBusy = false; renderSearch(); }
}

function clearReferencePreview() {
  drawReference = null;
  $('#referencePreview').hidden = true;
  $('#personChoices').replaceChildren();
  $('#referenceFile').value = '';
}

$('#clearReference').addEventListener('click', () => searchAction(async () => {
  await searchApi('/api/search/reference', {method: 'DELETE'});
  clearReferencePreview();
  if (st?.search) { st.search.sightings = []; st.search.referenceAvailable = false; }
  clearSourceFrames();
  $('#searchMessage').textContent = '';
}));
$('#saveThreshold').addEventListener('click', () => {
  const input = $('#threshold');
  if (!input.reportValidity() || !input.value) return;
  const threshold = Number(input.value);
  searchAction(async () => {
    await searchApi('/api/search/threshold', {method: 'PUT', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({threshold})});
    if (st?.search) st.search.sightings = [];
    clearSourceFrames();
    $('#searchMessage').textContent = `Threshold set to ${threshold.toFixed(2)}`;
  });
});

function paintPeople(canvas, detections, selected = -1) {
  const ctx = canvas.getContext('2d');
  const scale = canvas.width / Math.max(1, canvas.getBoundingClientRect().width);
  const size = 24 * scale;
  ctx.lineWidth = 2 * scale;
  ctx.font = `600 ${14 * scale}px system-ui`;
  const markers = [];
  detections.forEach((d, i) => {
    const [x1, y1, x2, y2] = d.box;
    ctx.strokeStyle = selected === i ? '#57d879' : '#fff';
    ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);
    const origin = {x: Math.min(x1, canvas.width - size), y: Math.max(0, y1 - size)};
    let position = origin;
    const occupied = p => markers.some(m => Math.abs(m.x - p.x) < size && Math.abs(m.y - p.y) < size);
    if (occupied(position)) {
      let distance = Infinity;
      for (let y = 0; y + size <= canvas.height; y += size + 4 * scale) {
        for (let x = 0; x + size <= canvas.width; x += size + 4 * scale) {
          const candidate = {x, y}, d = (x - origin.x) ** 2 + (y - origin.y) ** 2;
          if (d < distance && !occupied(candidate)) { position = candidate; distance = d; }
        }
      }
    }
    markers.push({...position, x1, y1});
  });
  // Paint labels after all boxes so later box outlines cannot obscure earlier numbers.
  markers.forEach(({x, y, x1, y1}, i) => {
    ctx.strokeStyle = selected === i ? '#57d879' : '#fff';
    ctx.beginPath();
    ctx.moveTo(x + size / 2, y + size / 2);
    ctx.lineTo(x1, y1);
    ctx.stroke();
  });
  markers.forEach(({x, y}, i) => {
    ctx.fillStyle = '#000';
    ctx.fillRect(x, y, size, size);
    ctx.fillStyle = '#fff';
    ctx.fillText(String(i + 1), x + 6 * scale, y + 17 * scale);
  });
}
$('#uploadPhoto').addEventListener('click', () => $('#referenceFile').click());
$('#referenceFile').addEventListener('change', () => {
  uploadReferencePhoto($('#referenceFile').files[0]);
  $('#referenceFile').value = '';
});
const uploadZone = $('#uploadPhoto');
for (const eventName of ['dragenter', 'dragover']) {
  uploadZone.addEventListener(eventName, (event) => {
    event.preventDefault();
    if (searchBusy) return;
    event.dataTransfer.dropEffect = 'copy';
    uploadZone.classList.add('dragging');
  });
}
uploadZone.addEventListener('dragleave', (event) => {
  if (!uploadZone.contains(event.relatedTarget)) uploadZone.classList.remove('dragging');
});
uploadZone.addEventListener('drop', (event) => {
  event.preventDefault();
  uploadZone.classList.remove('dragging');
  if (searchBusy) return;
  const files = event.dataTransfer.files;
  if (files.length !== 1) {
    $('#searchMessage').textContent = 'Choose one photo at a time.';
    return;
  }
  uploadReferencePhoto(files[0]);
});

function uploadReferencePhoto(file) {
  if (!file || searchBusy) return;
  searchAction(async () => {
    drawReference = null;
    $('#personChoices').replaceChildren();
    $('#referencePreview').hidden = true;
    $('#searchMessage').textContent = 'Finding people in the reference…';
    if (file.type && !file.type.startsWith('image/')) throw new Error('Choose an image file.');
    if (file.size > 25_000_000) throw new Error('Choose a photo smaller than 25 MB.');
    const image = new Image();
    const url = URL.createObjectURL(file);
    try { image.src = url; await image.decode(); } finally { URL.revokeObjectURL(url); }
    const photo = document.createElement('canvas');
    const scale = Math.min(1, 1280 / Math.max(image.naturalWidth, image.naturalHeight));
    photo.width = Math.max(1, Math.round(image.naturalWidth * scale));
    photo.height = Math.max(1, Math.round(image.naturalHeight * scale));
    photo.getContext('2d').drawImage(image, 0, 0, photo.width, photo.height);
    const blob = await new Promise((resolve, reject) => photo.toBlob(b => b ? resolve(b) : reject(new Error('Could not read image')), 'image/jpeg', .85));
    const result = await searchApi('/api/search/reference/people', {method: 'POST', headers: {'Content-Type': 'image/jpeg'}, body: blob});
    const preview = $('#referencePreview');
    preview.width = photo.width; preview.height = photo.height; preview.hidden = false;
    let selected = -1;
    drawReference = () => {
      preview.getContext('2d').drawImage(photo, 0, 0);
      paintPeople(preview, result.detections, selected);
    };
    drawReference();
    $('#searchMessage').textContent = result.detections.length ? 'Choose the numbered person to search for.' : 'No people detected. Try another photo.';
    result.detections.forEach((person, index) => {
      const button = document.createElement('button');
      button.className = 'btn'; button.textContent = `Person ${index + 1}`;
      button.addEventListener('click', () => searchAction(async () => {
        await searchApi(`/api/search/reference?${new URLSearchParams({box: person.box.join(',')})}`, {method: 'PUT', headers: {'Content-Type': 'image/jpeg'}, body: blob});
        if (st?.search) st.search.sightings = [];
        clearSourceFrames();
        selected = index;
        drawReference();
        $('#searchMessage').textContent = `Person ${index + 1} selected.`;
      }));
      $('#personChoices').append(button);
    });
  });
}

let analysisKey = null;
function clearSourceFrames() {
  for (const frame of sourceFrames.values()) URL.revokeObjectURL(frame.url);
  sourceFrames.clear();
  analysisKey = null;
  $('#analyzedFrame').hidden = true;
}
function renderAnalysis() {
  const canvas = $('#analyzedFrame');
  const confirm = $('#confirmSighting');
  confirm.hidden = true;
  confirm.onclick = null;
  const result = st?.search?.sightings?.find(s => s.phoneId === viewing && freshSighting(s, st.search, st.t, snapshotAt, performance.now()));
  if (!result) {
    analysisKey = null; canvas.hidden = true;
    $('#analysisMeta').textContent = 'No current result';
    return;
  }
  if (result.matched) {
    const identity = {phoneId: result.phoneId, streamId: result.streamId, seq: result.seq, searchRevision: result.searchRevision};
    confirm.hidden = false;
    confirm.disabled = searchBusy;
    confirm.onclick = () => searchAction(async () => {
      const updated = await searchApi('/api/search/confirm', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(identity)});
      if (st) st.search = updated;
      $('#searchMessage').textContent = 'Visual sighting confirmed. Target location remains unknown.';
      renderAnalysis();
    });
  }
  const age = Math.max(0, Math.round(st.t - result.t + performance.now() - snapshotAt));
  const scores = result.boxes.map(scoreLabel).join(' / ') || 'No people detected';
  const frame = sourceFrames.get(frameKey(result));
  $('#analysisMeta').textContent = `${result.matched ? 'Likely sighting' : 'No likely match'} · Phone ${result.phoneId} · Frame ${result.seq} · ${age} ms old · ${scores}${frame ? '' : ' · Exact preview unavailable'}`;
  if (!frame) { analysisKey = null; canvas.hidden = true; return; }
  const key = frameKey(result);
  if (analysisKey === key) return;
  analysisKey = key;
  canvas.hidden = true;
  const image = new Image();
  image.onload = () => {
    if (analysisKey !== key || !sourceFrames.has(key)) return;
    canvas.width = result.width; canvas.height = result.height;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(image, 0, 0, canvas.width, canvas.height);
    ctx.lineWidth = 3;
    for (const box of result.boxes) {
      ctx.strokeStyle = box.similarity >= st.search.threshold ? '#57d879' : '#fff';
      ctx.strokeRect(box.x * canvas.width, box.y * canvas.height, box.w * canvas.width, box.h * canvas.height);
    }
    canvas.hidden = false;
  };
  image.src = frame.url;
}
setInterval(() => { if (viewing) renderAnalysis(); }, 100);
new ResizeObserver(() => drawReference?.()).observe($('#referencePreview'));
renderSearch();

$('#scanToggle').addEventListener('click', () => {
  send({ type: 'scan', enabled: !st?.scan?.enabled });
  if (!st?.scan?.enabled) setMapMode('3d');
});
$('#scanRebuild').addEventListener('click', () => send({ type: 'scan', action: 'rebuild' }));
$('#scanReset').addEventListener('click', () => send({ type: 'scan', action: 'reset' }));
