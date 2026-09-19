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
let authenticated = false;
let sessionGeneration = 0;
let drawReference = null;
let searchBusy = false;
let dragPos = null;          // candidate position while dragging
let lastDragSend = 0;

// ---------------------------------------------------------------- socket
function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws/dashboard?role=console&thumb_fps=1`);
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
    resizeMap();
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
  const lats = live.map((p) => p.latencyMs).filter((x) => x != null).sort((a, b) => a - b);
  $('#mLat').textContent = lats.length ? `${lats[Math.floor(lats.length / 2)]}ms` : '–';
  $('#mSearched').textContent = `${Math.round((st.coverage?.searched || 0) * 100)}%`;
  const t = st.target;
  $('#mCand').textContent = !t ? '–' : t.foundBy ? `${(t.searchMs / 1000).toFixed(1)}s` : fmtClock(t.searchMs);
  $('#mCandBox').classList.toggle('alert', !!t?.foundBy);
}

function renderControls() {
  $('#plannerSw').classList.toggle('on', !!st.planner?.enabled);
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
    s.textContent = `Found by #${f?.index ?? '?'} in ${(t.searchMs / 1000).toFixed(1)}s · ${arrived}/${total} responders arrived`;
  } else {
    s.textContent = `Hidden at (${t.x.toFixed(1)}, ${t.y.toFixed(1)}) · searching`;
  }
  $('#respN').textContent = t ? t.respondersWanted : respondersPref;
  $('#lookingFor').textContent = st.lookingFor ? `Looking for: ${st.lookingFor}` : '';
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
  if (p.hidden) out.push(['Hidden', '']);
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
        <td class="st"></td><td class="actions"><button class="btn sm" data-act="hide"></button></td>`;
      if (thumbs.has(p.id)) tr.querySelector('img').src = thumbs.get(p.id);
    }
    existing.delete(p.id);
    if (body.children[i] !== tr) body.insertBefore(tr, body.children[i] || null);
    tr.classList.toggle('off', !p.connected);
    tr.querySelector('.thumb').classList.toggle('hidden', p.hidden);
    tr.querySelector('.idx').textContent = p.index;
    tr.querySelector('.name').innerHTML = `${escapeHtml(p.name || 'Phone')} <span class="faint">${escapeHtml(p.device || '')}</span>`;
    const pose = p.pose;
    tr.querySelector('.pos').textContent = pose ? `${pose.x.toFixed(1)}, ${pose.y.toFixed(1)} · ${pose.source}` : '–';
    tr.querySelector('.hd').textContent = pose?.heading != null ? `${Math.round(pose.heading)}°` : '–';
    tr.querySelector('.fps').textContent = p.fps.toFixed(1);
    tr.querySelector('.lat').textContent = p.latencyMs != null ? `${p.latencyMs}ms` : '–';
    tr.querySelector('.st').innerHTML = phoneStatus(p).map(([s, c]) => `<span class="badge ${c}">${s}</span>`).join('');
    tr.querySelector('[data-act="hide"]').textContent = p.hidden ? 'Show' : 'Hide';
  });
  for (const tr of existing.values()) tr.remove();
}

$('#phones').addEventListener('click', (e) => {
  const tr = e.target.closest('tr');
  const p = tr && phones.get(tr.dataset.id);
  if (!p) return;
  if (e.target.closest('[data-act]')) send({ type: 'hide', phoneId: p.id, hidden: !p.hidden });
  else openViewer(p.id); // click anywhere else on the row: expand the feed
});

// ---------------------------------------------------------------- expanded feed
let viewing = null; // phone id shown large

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
  $('#vName').textContent = p.name || 'Phone';
  $('#vDevice').textContent = p.device || '';
  $('#vBadges').innerHTML = phoneStatus(p).map(([s, c]) => `<span class="badge ${c}">${s}</span>`).join('');
  $('#vHide').textContent = p.hidden ? 'Show on projector' : 'Hide from projector';
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
$('#vHide').addEventListener('click', () => {
  const p = phones.get(viewing);
  if (p) send({ type: 'hide', phoneId: p.id, hidden: !p.hidden });
});
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
  $('#aiUsage').textContent = `${m.calls || 0} calls · ${((m.tokens || 0) / 1000).toFixed(1)}k tokens`;

  // live feed of what autonomy did (newest first, last minute)
  const recs = (m.recs || []).filter((r) => r.ageS < 60).slice(0, 4);
  const key = JSON.stringify(recs.map((r) => r.id));
  if (key === recsKey) return; // unchanged: don't rebuild
  recsKey = key;
  $('#recs').innerHTML = recs.map((r) => `<div class="rec"><span class="sev ${r.severity}"></span>
      <div><div class="t">${escapeHtml(r.title)}</div><div class="why">${escapeHtml(r.reason)}</div>
      <div class="acts">${r.results.map((t) => `<span class="chip">${escapeHtml(t)}</span>`).join('')}</div></div>
      <span class="state ${r.status === 'failed' ? '' : 'auto'}">${r.status === 'failed' ? '✕ failed' : '⚡ done'}</span></div>`).join('');
}

$('#autoSw').addEventListener('click', () => send({ type: 'autonomy', enabled: !st?.mission?.autonomy }));

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

window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && e.target === $('#mcInput')) { e.target.blur(); return; }
  if (viewing && !e.target.closest?.('input, textarea')) {
    if (e.key === 'Escape') { closeViewer(); return; }
    if (e.key === 'ArrowRight') { stepViewer(1); return; }
    if (e.key === 'ArrowLeft') { stepViewer(-1); return; }
  }
  if (e.metaKey || e.ctrlKey || e.altKey || e.target.closest?.('input, textarea')) return;
  if (e.key === '/') { e.preventDefault(); $('#mcInput').focus(); return; }
  if (e.key === 'm' || e.key === 'M') { send({ type: 'autonomy', enabled: !st?.mission?.autonomy }); return; }
  const n = Number(e.key);
  if (n >= 1 && n <= PHASES.length) send({ type: 'phase', phase: PHASES[n - 1][0] });
  else if (e.key === 'p' || e.key === 'P') send({ type: 'planner', enabled: !st?.planner?.enabled });
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
  if (!view || !st) return;
  ctx.clearRect(0, 0, canvas.clientWidth, canvas.clientHeight);

  // searched floor: faint white
  const cov = st.coverage;
  if (cov) {
    const s = cov.cell * view.scale;
    ctx.fillStyle = 'rgba(255,255,255,0.13)';
    for (let r = 0; r < cov.rows; r++) {
      for (let c = 0; c < cov.cols; c++) {
        if (cov.cells.charCodeAt(r * cov.cols + c) !== 49) continue;
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
  drawCandidate();
  drawPings();
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

function drawCandidate() {
  const t = st.target;
  if (!t) return;
  const pos = dragPos || t;
  const [cx, cy] = view.toPx(pos.x, pos.y);
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
  if (t.foundBy) {
    const k = (performance.now() / 1100) % 1;
    ctx.strokeStyle = `rgba(255,77,77,${1 - k})`;
    ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.arc(cx, cy, 7 + k * 26, 0, Math.PI * 2); ctx.stroke();
    ctx.fillStyle = '#ff4d4d';
    ctx.beginPath(); ctx.arc(cx, cy, 7, 0, Math.PI * 2); ctx.fill();
  } else {
    ctx.strokeStyle = '#ededed';
    ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.arc(cx, cy, 7, 0, Math.PI * 2); ctx.stroke();
    ctx.beginPath(); ctx.moveTo(cx - 3, cy); ctx.lineTo(cx + 3, cy); ctx.moveTo(cx, cy - 3); ctx.lineTo(cx, cy + 3); ctx.stroke();
  }
}

// drag the candidate
function roomPoint(e) {
  const r = canvas.getBoundingClientRect();
  const [x, y] = view.toRoom(e.clientX - r.left, e.clientY - r.top);
  return { x: Math.max(-room.width / 2, Math.min(room.width / 2, x)), y: Math.max(0, Math.min(room.depth, y)) };
}
function nearCandidate(e) {
  if (!st?.target || !view) return false;
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
    if (response.status === 401) { authenticated = false; renderSearch(); }
    throw new Error(typeof body.detail === 'string' ? body.detail : `Request failed (${response.status})`);
  }
  return body;
}

function renderSearch() {
  $('#loginForm').hidden = authenticated;
  $('#logout').hidden = !authenticated;
  $('#searchTools').hidden = !authenticated;
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

$('#loginForm').addEventListener('submit', (event) => {
  event.preventDefault();
  searchAction(async () => {
    sessionGeneration++;
    await searchApi('/api/session', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({code: $('#operatorCode').value})});
    $('#operatorCode').value = '';
    authenticated = true;
    $('#searchMessage').textContent = 'Signed in';
    ws?.close();
  });
});
$('#logout').addEventListener('click', () => searchAction(async () => {
  sessionGeneration++;
  await searchApi('/api/session', {method: 'DELETE'});
  authenticated = false;
  $('#searchMessage').textContent = 'Signed out';
  clearReferencePreview();
  ws?.close();
}));
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
  if (authenticated && result.matched) {
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
async function loadSession() {
  const generation = sessionGeneration;
  try {
    const session = await searchApi('/api/session');
    if (generation !== sessionGeneration) return;
    authenticated = session.authenticated;
    renderSearch();
  } catch (error) {
    if (generation === sessionGeneration) $('#searchMessage').textContent = error.message;
  }
}
loadSession();
