import { frameKey, freshSighting, scoreLabel } from '/web/inference-ui.js';
import { makeView, drawRoom, drawCone } from '/web/room.js';

const $ = (s) => document.querySelector(s);
const PHASES = [
  ['lobby', 'Lobby'], ['calibrate', 'Calibrate'], ['search', 'Search'], ['found', 'Found'], ['end', 'End'],
];

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
let lastDragSend = 0;

// ---------------------------------------------------------------- socket
function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws/console?thumb_fps=2`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => setConn(true);
  ws.onclose = () => { setConn(false); setTimeout(connect, 1000); };
  ws.onmessage = (ev) => (typeof ev.data === 'string' ? onJson(JSON.parse(ev.data)) : onFrame(ev.data));
}

function setConn(live) {
  if (!live) { st = null; clearSourceFrames(); renderSearch(); renderAnalysis(); }
  $('#connDot').classList.toggle('live', live);
  $('#connText').textContent = live ? 'Live' : 'Reconnecting';
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
    let saved = '2d';
    try { saved = localStorage.getItem('swarm.mapMode') || '2d'; } catch {}
    if (saved === '3d' && mapMode !== '3d') setMapMode('3d');
  } else if (msg.type === 'mission') {
    onMission(msg);
  } else if (msg.type === 'spotlight') {
    spotlight(msg);
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
  if (img) img.src = url;
  if (phoneId === viewing) { $('#vImg').src = url; $('#vNone').style.display = 'none'; }
}

// ---------------------------------------------------------------- render
function render() {
  renderViewer();
  renderSearch();
  renderPhases();
  renderMetrics();
  renderControls();
  renderPhones();
  renderLog();
}

function renderPhases() {
  const cur = PHASES.findIndex(([k]) => k === st.phase);
  $('#steps').innerHTML = PHASES.map(([key, label], i) => {
    const cls = i === cur ? `on ${key}` : i < cur ? 'done' : '';
    return `<button class="step ${cls}" data-phase="${key}"><span class="n">${i < cur ? '✓' : i + 1}</span>${label}</button>`;
  }).join('');
}

$('#steps').addEventListener('click', (e) => {
  const b = e.target.closest('[data-phase]');
  if (b) send({ type: 'phase', phase: b.dataset.phase });
});

function fmtClock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

function renderMetrics() {
  const live = [...phones.values()].filter((p) => p.connected);
  $('#mLive').textContent = live.length;
  $('#mPlaced').textContent = live.filter((p) => p.pose).length;
  $('#mFps').textContent = live.reduce((s, p) => s + p.fps, 0).toFixed(1);
  const mbps = live.reduce((s, p) => s + (p.kbps || 0), 0) / 1000;
  $('#mFpsK').textContent = `Frames / s · ${mbps.toFixed(1)} Mbps in`;
  const lats = live.map((p) => p.latencyMs).filter((x) => x != null).sort((a, b) => a - b);
  $('#mLat').textContent = lats.length ? `${lats[Math.floor(lats.length / 2)]}ms` : '–';
  $('#mSearched').textContent = `${Math.round((st.coverage?.searched || 0) * 100)}%`;
  const t = st.target;
  $('#mCand').textContent = !t ? '–' : t.foundBy ? `${(t.searchMs / 1000).toFixed(1)}s` : fmtClock(t.searchMs);
  $('#mCandBox').classList.toggle('alert', !!t?.foundBy);
}

function renderControls() {
  $('#plannerSw').classList.toggle('on', !!st.planner?.enabled);
  const sc = st.scan;
  if (sc) {
    $('#scanSw').classList.toggle('on', sc.enabled);
    const l = sc.last;
    $('#scanHint').textContent = !sc.configured ? 'Set MAP_WORKER_SSH in .env'
      : sc.running ? `Rebuilding from ${sc.batchSize} views…`
      : sc.error ? `Error: ${sc.error}`
      : !sc.enabled ? 'VGGT on the GPU, from phone frames'
      : sc.paused ? `Paused in the lobby · ${sc.keyframes} views kept`
      : `${sc.keyframes}/${sc.maxKeyframes} archived · batch ≤${sc.maxBatch} · ${sc.newSince} pending`
        + (l ? ` · v${l.version} in ${l.seconds}s` : '');
    $('#scanSelection').textContent = sc.enabled ? Object.values(sc.selectionHints || {})
      .map(h => `${h.name}: ${h.message}`).join(' · ') : '';
    if (sc.enabled && sc.selection) {
      const counts = sc.selection.counts || {};
      const rejected = Object.entries(counts).filter(([k]) => !['Evaluated', 'Accepted'].includes(k))
        .map(([k, v]) => `${v} ${k.toLowerCase()}`).join(', ');
      $('#scanSelection').textContent += ` · Since restart: ${counts.Accepted || 0}/${counts.Evaluated || 0} accepted`
        + ` · ${sc.selection.waitingForOverlap} waiting for overlap` + (rejected ? ` · ${rejected}` : '');
    }
  }
  const t = st.target;
  const s = $('#candStatus');
  s.classList.toggle('found', !!t?.foundBy);
  if (st.search?.mode === 'real') {
    s.textContent = st.search.confirmation ? `Visual sighting confirmed · Phone ${st.search.confirmation.phoneId} · target location unknown` : 'Real visual search · target location unknown';
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
  $('#mcModel').textContent = m.ready ? m.model : (m.why || '');
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
  else if (p.stale) out.push(['Stale', '']);
  if (p.pitch != null && Math.abs(p.pitch) > 65) out.push([p.pitch < 0 ? 'Floor' : 'Ceiling', '']);
  if (p.speaking) out.push(['🎙 Speaking', 'w']);
  if (p.oldPage && !p.sim && p.connected) out.push(['Old page · reload', 'r']);
  return out;
}

function renderPhones() {
  const list = [...phones.values()].sort((a, b) => a.index - b.index);
  $('#phoneCount').textContent = list.length;
  $('#phonesEmpty').style.display = list.length ? 'none' : '';
  const body = $('#phones');
  // rebuild rows, but keep <img> elements so thumbnails don't flicker
  const existing = new Map([...body.children].map((tr) => [tr.dataset.id, tr]));
  list.forEach((p, i) => {
    let tr = existing.get(p.id);
    if (!tr) {
      tr = document.createElement('tr');
      tr.dataset.id = p.id;
      tr.innerHTML = `<td><img class="thumb" alt="" data-thumb="${escapeHtml(p.id)}"></td><td class="idx"></td><td class="name"></td>
        <td class="pos mono muted"></td><td class="hd mono muted"></td><td class="fps mono muted"></td><td class="lat mono muted"></td>
        <td class="st"></td>`;
      if (thumbs.has(p.id)) tr.querySelector('img').src = thumbs.get(p.id);
    }
    existing.delete(p.id);
    if (body.children[i] !== tr) body.insertBefore(tr, body.children[i] || null);
    tr.classList.toggle('off', !p.connected);
    tr.querySelector('.idx').textContent = p.index;
    tr.querySelector('.name').innerHTML = `${escapeHtml(p.name || 'Phone')} <span class="faint">${escapeHtml(p.device || '')}</span>`
      + (p.caption ? `<div class="cap">“${escapeHtml(p.caption.text)}”</div>` : '');
    const pose = p.pose;
    tr.querySelector('.pos').textContent = pose ? `${pose.x.toFixed(1)}, ${pose.y.toFixed(1)} · ${pose.source}` : '–';
    tr.querySelector('.hd').textContent = pose?.heading != null ? `${Math.round(pose.heading)}°` : '–';
    tr.querySelector('.fps').textContent = p.fps.toFixed(1);
    tr.querySelector('.lat').textContent = p.latencyMs != null ? `${p.latencyMs}ms` : '–';
    tr.querySelector('.st').innerHTML = phoneStatus(p).map(([s, c]) => `<span class="badge ${c}">${s}</span>`).join('');
  });
  for (const tr of existing.values()) tr.remove();
}

$('#phones').addEventListener('click', (e) => {
  const tr = e.target.closest('tr');
  const p = tr && phones.get(tr.dataset.id);
  if (!p) return;
  openViewer(p.id); // click a row: expand the feed
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
  clearAlert();
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
  const v = p.vision, sees = $('#vSees');
  sees.textContent = v ? `👁 ${v.target ? `target ${Math.round(v.confidence * 100)}% · ` : ''}${v.sees}` : '';
  sees.classList.toggle('on', !!v?.sees);
  sees.classList.toggle('hit', !!(v?.target || v?.urgent));
  const cap = $('#vCap');
  cap.textContent = p.caption ? p.caption.text : p.speaking ? '…' : '';
  cap.classList.toggle('on', !!(p.caption || p.speaking));
  $('#vName').textContent = p.name || 'Phone';
  $('#vDevice').textContent = p.device || '';
  $('#vBadges').innerHTML = phoneStatus(p).map(([s, c]) => `<span class="badge ${c}">${s}</span>`).join('');
  const pose = p.pose;
  $('#vTask').textContent = p.task || (st.planner?.assignments?.[p.id] ? `searching ${st.planner.assignments[p.id].sector}` : 'idle');
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

// ---------------------------------------------------------------- spotlight
// Vision (or Mission Control) found something a human should see: pull that phone's feed up.
let alertTimer = null;
function spotlight(ev) {
  if (!phones.has(ev.phoneId)) return;
  if (viewing !== ev.phoneId) openViewer(ev.phoneId);
  const el = $('#vAlert');
  el.innerHTML = `⚠ ${escapeHtml(ev.reason || 'Look at this')} <small>· ${ev.source === 'vision' ? 'Vision' : 'Mission Control'} pulled up #${ev.index}</small>`;
  el.classList.add('on');
  $('#viewer').classList.add('alerting');
  clearTimeout(alertTimer);
  alertTimer = setTimeout(clearAlert, 12000);
}
function clearAlert() {
  $('#vAlert').classList.remove('on');
  $('#viewer').classList.remove('alerting');
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
$('#joinBtn').addEventListener('click', (e) => { e.stopPropagation(); $('#joinPop').classList.toggle('on'); });
document.addEventListener('click', (e) => { if (!e.target.closest('.joinWrap')) $('#joinPop').classList.remove('on'); });
$('#viewer').addEventListener('click', (e) => { if (e.target === $('#viewer')) closeViewer(); });

function renderLog() {
  const log = [...(st.planner?.log || [])].reverse();
  if (!log.length) return;
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
  $('#aiStatus').classList.add('on');
  $('#aiPulse').classList.toggle('live', on && !!m.thinking);
  const searching = st.phase === 'search' || st.phase === 'found';
  $('#aiText').textContent = !on ? 'Autonomy paused'
    : st.missionComplete ? 'Mission complete · all responders on target'
    : !searching ? 'Autonomous · waiting for the search phase'
    : m.thinking ? 'Analyzing the room…'
    : `Autonomous${m.lastThinkMs ? ` · reviews take ${(m.lastThinkMs / 1000).toFixed(1)}s` : ''}`;
  const vs = st.vision;
  $('#visSw').classList.toggle('on', !!vs?.enabled);
  $('#visText').textContent = !vs?.enabled ? '' : vs.error ? `· vision error: ${vs.error}`
    : `· 👁 ${vs.perSec} looks/s${vs.lastMs ? ` · ${(vs.lastMs / 1000).toFixed(1)}s each` : ''} · ${vs.model}`;
  const calls = (m.calls || 0) + (vs?.calls || 0), tokens = (m.tokens || 0) + (vs?.tokens || 0);
  $('#aiUsage').textContent = `${calls} calls · ${(tokens / 1000).toFixed(1)}k tokens`;

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
  for (const v of ev.vision || []) {
    rows.push(['Saw', `#${v.index}: ${v.urgent ? `⚠ ${v.urgent} · ` : ''}${v.target != null ? `target ${Math.round(v.target * 100)}% · ` : ''}${v.sees}`]);
  }
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
$('#scanSw').addEventListener('click', () => send({ type: 'scan', enabled: !st?.scan?.enabled }));
$('#scanRebuild').addEventListener('click', () => send({ type: 'scan', action: 'rebuild' }));
$('#scanReset').addEventListener('click', () => send({ type: 'scan', action: 'reset' }));
$('#visSw').addEventListener('click', () => send({ type: 'vision', enabled: !st?.vision?.enabled }));

// ---------------------------------------------------------------- controls
let respondersPref = 3;
$('#plannerSw').addEventListener('click', () => send({ type: 'planner', enabled: !st?.planner?.enabled }));
$('#resetCov').addEventListener('click', () => send({ type: 'reset_coverage' }));
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

$('#joinBtn').addEventListener('click', (e) => { e.stopPropagation(); $('#joinPop').classList.toggle('on'); });
document.addEventListener('click', (e) => { if (!e.target.closest('.joinWrap')) $('#joinPop').classList.remove('on'); });

window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && e.target === $('#mcInput')) { e.target.blur(); return; }
  if (viewing && !e.target.closest?.('input, textarea')) {
    if (e.key === 'Escape') { closeViewer(); return; }
    if (e.key === 'ArrowRight') { stepViewer(1); return; }
    if (e.key === 'ArrowLeft') { stepViewer(-1); return; }
    if (e.key === 'h' || e.key === 'H') { toggleHud(); return; }
  }
  if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest?.('input, textarea')) return;
  if (e.key === '/') { e.preventDefault(); $('#mcInput').focus(); return; }
  if (e.key === 'Escape' && explaining) { explaining = null; recsKey = ''; if (st?.mission) renderAutonomy(st.mission); return; }
  if (e.key === 'm' || e.key === 'M') { send({ type: 'autonomy', enabled: !st?.mission?.autonomy }); return; }
  if (e.key === 'v' || e.key === 'V') { send({ type: 'vision', enabled: !st?.vision?.enabled }); return; }
  const n = Number(e.key);
  if (n >= 1 && n <= PHASES.length) send({ type: 'phase', phase: PHASES[n - 1][0] });
  else if (e.key === 'p' || e.key === 'P') send({ type: 'planner', enabled: !st?.planner?.enabled });
});

// ---------------------------------------------------------------- 3D view
// The scan (VGGT GLB; a mock until the real one exists) with everyone in it. three.js loads only
// the first time 3D is opened, so the 2D console works without internet.
let mapMode = '2d', scene3d = null, s3dStatus = null;

async function setMapMode(mode) {
  mapMode = mode;
  try { localStorage.setItem('swarm.mapMode', mode); } catch {}
  for (const b of document.querySelectorAll('#viewSeg button')) b.classList.toggle('on', b.dataset.view === mode);
  const is3d = mode === '3d';
  $('#mapWrap').classList.toggle('is3d', is3d);
  $('#map').hidden = is3d;
  $('#scene3d').hidden = !is3d;
  $('#mapHint').textContent = is3d ? '· drag to orbit · scroll to zoom · click a person for their feed · double-click to reset'
    : '· brighter = more likely · drag the candidate · right-click to ping';
  if (!is3d) { scene3d?.hide(); return; }
  if (!scene3d) {
    if (!room) return;
    s3dStatus = document.createElement('div');
    s3dStatus.className = 's3d-status';
    s3dStatus.textContent = 'Loading 3D…';
    $('#scene3d').appendChild(s3dStatus);
    try {
      const { createScene3D } = await import('/web/scene3d.js');
      scene3d = createScene3D($('#scene3d'), {
        room, getState: () => st, getThumb: (id) => thumbs.get(id), onPick: (id) => openViewer(id),
      });
      $('#scene3d').addEventListener('dblclick', () => scene3d.resetView());
      setInterval(() => {
        const s = scene3d.status();
        s3dStatus.textContent = s === 'ready' ? scene3d.label()
          : s === 'waiting' ? 'waiting for the first live scan…' : s === 'loading' ? 'loading scan…' : s === 'failed' ? 'scan failed to load' : 'no scan configured';
      }, 1000);
    } catch (e) {
      s3dStatus.textContent = `3D unavailable (needs internet for three.js): ${e.message}`;
      return;
    }
  }
  if (mapMode === '3d') scene3d.show();
}
$('#fitBar').addEventListener('click', (e) => {
  const b = e.target.closest('[data-fit]');
  if (!b) return;
  const kind = b.dataset.fit;
  send({ type: 'scan', action: 'fit', ...(kind === 'reset' ? { reset: true } : { [kind]: Number(b.dataset.v) }) });
});
function renderFit() {
  const l = st?.scan?.last;
  $('#fitBar').hidden = mapMode !== '3d' || !l;
  if (!l) return;
  const a = l.alignment || {}, f = l.fit || { scale: 1, turnDeg: 0 };
  $('#fitInfo').textContent = `${l.viewDistanceM != null ? `~${(l.viewDistanceM * f.scale).toFixed(1)} m views · ` : ''}`
    + `${f.scale !== 1 ? `×${f.scale.toFixed(2)} ` : ''}${f.turnDeg ? `${f.turnDeg > 0 ? '+' : ''}${Math.round(f.turnDeg)}° ` : ''}`
    + `${a.leveledBy === 'gravity' ? 'level ✓' : ''}`;
}
setInterval(renderFit, 500);

$('#viewSeg').addEventListener('click', (e) => {
  const b = e.target.closest('[data-view]');
  if (b) setMapMode(b.dataset.view);
});

// ---------------------------------------------------------------- map (monochrome)
const canvas = $('#map');
const ctx = canvas.getContext('2d');
let view = null;

function resizeMap() {
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w || !room) return;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = w * dpr;
  canvas.height = h * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  view = makeView(room, w, h, 28);
}
new ResizeObserver(resizeMap).observe($('#mapWrap'));

function draw() {
  requestAnimationFrame(draw);
  if (!view || !st || mapMode === '3d') return;
  ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);

  // probability heatmap: brighter = the candidate is more likely here (relative to the hottest cell)
  const cov = st.coverage;
  if (cov?.heat) {
    const s = cov.cell * view.scale;
    for (let r = 0; r < cov.rows; r++) {
      for (let c = 0; c < cov.cols; c++) {
        const level = parseInt(cov.heat[r * cov.cols + c], 36) / 35;
        if (level < 0.02) continue;
        ctx.fillStyle = `rgba(255,255,255,${(0.04 + 0.4 * level * level).toFixed(3)})`;
        const [px, py] = view.toPx(cov.x0 + c * cov.cell, r * cov.cell);
        ctx.fillRect(px, py, s + 0.5, s + 0.5);
      }
    }
  }
  drawRoom(ctx, room, view, {
    colors: { floor: 'rgba(0,0,0,0)', wall: '#3e3e3e', grid: 'rgba(255,255,255,0.04)', stage: '#1a1a1a', text: '#707070' },
  });

  // planner assignments: thin dashed lines to the sector
  const x0 = -room.width / 2;
  for (const [pid, job] of Object.entries(st.planner?.assignments || {})) {
    const p = phones.get(pid);
    if (!p?.pose) continue;
    const size = st.planner.sectorSize;
    const c = job.sector.charCodeAt(0) - 65, r = Number(job.sector.slice(1)) - 1;
    const [ax, ay] = view.toPx(x0 + c * size, r * size);
    const [bx, by] = view.toPx(x0 + (c + 1) * size, (r + 1) * size);
    ctx.strokeStyle = 'rgba(255,255,255,0.35)';
    ctx.lineWidth = 1;
    ctx.strokeRect(ax + 0.5, ay + 0.5, bx - ax - 1, by - ay - 1);
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    ctx.setLineDash([3, 4]);
    ctx.beginPath(); ctx.moveTo(px, py); ctx.lineTo((ax + bx) / 2, (ay + by) / 2); ctx.stroke();
    ctx.setLineDash([]);
  }

  const list = [...phones.values()].filter((p) => p.pose);
  for (const p of list) {
    if (p.pose.heading == null || st.phase === 'lobby') continue; // lobby: locations only
    drawCone(ctx, view, p.pose.x, p.pose.y, p.pose.heading, room.cameraFovDeg, room.coneLength,
      p.connected ? 'rgba(255,255,255,0.16)' : 'rgba(255,255,255,0.04)');
  }
  drawSightings();
  drawCandidate();
  drawPings();
  drawExplain();
  for (const p of list) {
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    ctx.globalAlpha = p.connected ? 1 : 0.35;
    ctx.fillStyle = '#ededed';
    ctx.beginPath(); ctx.arc(px, py, 4, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#a1a1a1';
    ctx.font = '500 11px "Geist Mono", ui-monospace, monospace';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';
    ctx.fillText(String(p.index), px + 8, py);
    ctx.globalAlpha = 1;
  }
}

function drawPings() {
  const now = Date.now();
  for (const pg of st.pings || []) {
    const [x, y] = view.toPx(pg.x, pg.y);
    const age = (now - pg.t) / 12000;
    const k = (performance.now() / 1000) % 1;
    ctx.save();
    ctx.globalAlpha = Math.max(0.25, 1 - age);
    ctx.strokeStyle = `rgba(255,255,255,${0.8 * (1 - k)})`;
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.arc(x, y, 6 + k * 18, 0, Math.PI * 2); ctx.stroke();
    ctx.fillStyle = '#ededed';
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
    const k = (performance.now() / 700) % 1;
    ctx.save();
    ctx.strokeStyle = '#ff4d4d';
    ctx.lineWidth = 1.5;
    ctx.setLineDash([4, 4]);
    ctx.lineDashOffset = -k * 8;
    ctx.beginPath(); ctx.arc(x, y, 13, 0, Math.PI * 2); ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = '#ff4d4d';
    ctx.font = '500 11px "Geist Mono", ui-monospace, monospace';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(`${Math.round(sg.confidence * 100)}% ?`, x, y - 22);
    ctx.restore();
  }
}

function drawCandidate() {
  const t = st.target;
  if (!t) return;
  // the mock candidate (rehearsals): where it really is, draggable
  if (t.x != null || dragPos) {
    const [mx, my] = view.toPx((dragPos || t).x, (dragPos || t).y);
    ctx.strokeStyle = t.foundBy ? 'rgba(237,237,237,0.4)' : '#ededed';
    ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.arc(mx, my, 7, 0, Math.PI * 2); ctx.stroke();
    ctx.beginPath(); ctx.moveTo(mx - 3, my); ctx.lineTo(mx + 3, my); ctx.moveTo(mx, my - 3); ctx.lineTo(mx, my + 3); ctx.stroke();
  }
  if (!t.foundBy || !t.fix) return;
  const [cx, cy] = view.toPx(t.fix[0], t.fix[1]); // where the confirmed sighting is
  for (const [pid, arrived] of Object.entries(t.responders || {})) {
    const p = phones.get(pid);
    if (!p?.pose) continue;
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    ctx.strokeStyle = arrived ? '#ededed' : '#ff4d4d';
    ctx.lineWidth = 1.5;
    ctx.setLineDash(arrived ? [] : [4, 4]);
    ctx.beginPath(); ctx.moveTo(px, py); ctx.lineTo(cx, cy); ctx.stroke();
    ctx.setLineDash([]);
  }
  const k = (performance.now() / 1100) % 1;
  ctx.strokeStyle = `rgba(255,77,77,${1 - k})`;
  ctx.lineWidth = 1.5;
  ctx.beginPath(); ctx.arc(cx, cy, 7 + k * 26, 0, Math.PI * 2); ctx.stroke();
  ctx.fillStyle = '#ff4d4d';
  ctx.beginPath(); ctx.arc(cx, cy, 7, 0, Math.PI * 2); ctx.fill();
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
canvas.addEventListener('mousedown', (e) => {
  if (e.altKey && view) { send({ type: 'ping', ...roomPoint(e) }); return; } // alt-click pings too
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
  canvas.style.cursor = dragPos ? 'grabbing' : nearCandidate(e) ? 'grab' : phoneAt(e) ? 'pointer' : 'default';
});
window.addEventListener('mousemove', (e) => {
  if (!dragPos) return;
  dragPos = roomPoint(e);
  const now = performance.now();
  if (now - lastDragSend > 80) { lastDragSend = now; send({ type: 'target', ...dragPos }); }
});
window.addEventListener('mouseup', () => {
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
  const search = st?.search;
  $('#searchStatus').textContent = search ? `${search.mode === 'real' ? 'Real search' : 'Rehearsal'} · Worker: ${search.status.replaceAll('_', ' ')} · ${search.referenceAvailable ? 'Reference registered' : 'No reference'} · ${search.active ? 'Searching' : 'Paused'}` : 'Waiting for hub connection';
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
$('#rehearsalMode').addEventListener('click', () => searchAction(async () => {
  const result = await searchApi('/api/search/rehearsal', {method: 'POST'});
  if (st) st.search = result;
  clearReferencePreview();
  $('#searchMessage').textContent = 'Rehearsal mode active. Place a mock candidate to rehearse.';
}));

$('#clearReference').addEventListener('click', () => searchAction(async () => {
  await searchApi('/api/search/reference', {method: 'DELETE'});
  clearReferencePreview();
  if (st?.search) st.search.sightings = [];
  clearSourceFrames();
  $('#searchMessage').textContent = 'Reference cleared';
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
    ctx.strokeStyle = selected === i ? '#ff4d4d' : '#fff';
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
    ctx.strokeStyle = selected === i ? '#ff4d4d' : '#fff';
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
$('#referenceFile').addEventListener('change', () => {
  const file = $('#referenceFile').files[0];
  if (!file) return;
  searchAction(async () => {
    drawReference = null;
    $('#personChoices').replaceChildren();
    $('#referencePreview').hidden = true;
    $('#searchMessage').textContent = 'Finding people in the reference…';
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
        $('#searchMessage').textContent = `Person ${index + 1} selected. Appearance similarity suggests likely sightings, not confirmed identity.`;
      }));
      $('#personChoices').append(button);
    });
  });
});

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
      ctx.strokeStyle = box.similarity >= st.search.threshold ? '#ff4d4d' : '#fff';
      ctx.strokeRect(box.x * canvas.width, box.y * canvas.height, box.w * canvas.width, box.h * canvas.height);
    }
    canvas.hidden = false;
  };
  image.src = frame.url;
}
setInterval(() => { if (viewing) renderAnalysis(); }, 100);
new ResizeObserver(() => drawReference?.()).observe($('#referencePreview'));
renderSearch();
