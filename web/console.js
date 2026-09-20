import { frameKey } from '/web/inference-ui.js';
import { makeView, drawRoom, drawCone, headingVector, heatLevels, heatCanvas, heatGradientCSS } from '/web/room.js';

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
const MARKER_COLOR = '#6b4fbb';
let lastDragSend = 0;

// ---------------------------------------------------------------- socket
function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  // Every tile on the wall runs at the same rate the expanded feed does. The
  // hub still relays latest-wins, so a slow socket skips frames rather than
  // queueing them.
  ws = new WebSocket(`${proto}://${location.host}/ws/dashboard?role=console&thumb_fps=15`);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => setConn(true);
  ws.onclose = () => { setConn(false); setTimeout(connect, 1000); };
  ws.onmessage = (ev) => (typeof ev.data === 'string' ? onJson(JSON.parse(ev.data)) : onFrame(ev.data));
}

function setConn(live) {
  if (!live) { st = null; clearSourceFrames(); renderSearch(); }
}

function send(msg) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(msg));
}

function onJson(msg) {
  if (msg.type === 'hello') {
    room = msg.room;
    $('#joinQr').src = `/api/qr.svg?data=${encodeURIComponent(msg.joinUrl)}`;
    $('#joinUrl').textContent = msg.joinUrl;
    resizeMap();
    if (mapMode === '3d') setMapMode('3d');
  } else if (msg.type === 'mission') {
    onMission(msg);
  } else if (msg.type === 'state') {
    st = msg;
    if (dragPos && !hiddenCandidates().some((c) => c.id === dragPos.id)) dragPos = null;
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
  btn.classList.toggle('danger', on);
  btn.disabled = !on && !ready;
  btn.title = on || ready || !live ? '' : `${scanned} of ${live} phones have scanned the marker`;
}

$('#startBtn').addEventListener('click', () => {
  send({ type: 'phase', phase: running() ? 'end' : 'search' });
});

function fmtClock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

// Metrics come and go as the console gets reshaped; a tile that is not on the
// page must not take the whole render loop down with it.
function setMetric(sel, value) {
  const el = $(sel);
  if (el) el.textContent = value;
}

function renderMetrics() {
  const all = [...phones.values()];
  const live = all.filter(isLive);
  const { scanned, ready } = readiness();
  setMetric('#mLive', live.length);
  setMetric('#mTotal', all.length);
  // Not "has a position" — every phone that scanned a seat has one of those.
  // How many are actually tracked, because that is what the map, the area
  // searched and every sighting's placement are resting on.
  setMetric('#mTracked', `${live.filter((p) => p.pose?.source === 'slam').length}/${live.length}`);
  setMetric('#mScanned', `${scanned}/${live.length}`);
  $('#mScannedBox')?.classList.toggle('alert', live.length > 0 && !ready && !running());
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
  const victims = t?.victims || [];
  const hidden = t?.candidates || [];
  // "Nothing yet" is not a status worth boxing: when there is no news the line
  // takes the same quiet, centred treatment as every other empty state on the
  // page, and only becomes a panel once it has something to say.
  let quiet = false;
  if (st.search?.mode === 'real') {
    const confirmed = st.search.confirmations || (st.search.confirmation ? [st.search.confirmation] : []);
    quiet = !confirmed.length;
    s.textContent = !confirmed.length ? 'No confirmed sighting'
      : confirmed.length === 1 ? `Visual sighting confirmed · Phone ${confirmed[0].phoneId} · target location unknown`
      : `${confirmed.length} visual sightings confirmed · target locations unknown`;
  } else if (!t) {
    quiet = true;
    s.textContent = 'No candidate placed';
  } else if (victims.length) {
    // Responder progress is per person and is already on each row below; a
    // second team count here only competes with it.
    const missing = t.stillMissing || 0;
    s.textContent = `${victims.length} found` + (missing ? ` · ${missing} to go` : '');
  } else {
    const top = (st.sightings || []).reduce((a, b) => (b.confidence > (a?.confidence ?? 0) ? b : a), null);
    // Say whose position this is. A bare "Hidden at (-5.1, 4.7)" reads as though the hub
    // knew where a real missing person was — and a raw signed coordinate says nothing to
    // anyone standing in the room. These are mock candidates the operator hid, and the
    // planner's sector name is how the rest of the console names a spot on the floor.
    const one = hidden.length === 1 ? hidden[0] : null;
    const sector = one && sectorAt(one.x, one.y);
    const where = !one ? `${plural(hidden.length, 'test candidate', 'test candidates')} hidden`
      : sector ? `Test candidate hidden in ${sector}`
      : `Test candidate hidden ${one.y.toFixed(1)} m from the stage`;
    s.textContent = `${where} · `
      + (top && top.confidence >= 0.4 ? `possible sighting · ${sightingEvidence(top)}`
         : one ? 'not found yet' : 'none found yet');
  }
  s.className = quiet ? 'empty' : victims.length ? 'status found' : 'status';
  renderFoundList(victims);
  renderTeam();
  renderRadio();
  renderThreats();
  renderLive(victims, t);
  renderPeople(st.search?.people);
  $('#respN').textContent = t ? t.respondersWanted : respondersPref;
  $('#lookingFor').textContent = st.lookingFor ? `Phones are told: ${st.lookingFor}` : '';
  // Before anyone has searched, every sector holds the same share and the "most
  // likely" one is whichever way the rounding fell. Say nothing until the map has
  // actually picked a favourite.
  const top = st.likely?.[0];
  const sectors = (st.planner?.cols || 0) * (st.planner?.rows || 0);
  const even = sectors ? 1 / sectors : 0;
  $('#likely').textContent = top && even && top.share >= even * 1.5
    ? `Most likely: ${top.sector} · ${Math.round(top.share * 100)}%` : '';
  const m = st.mission || {};
  renderAutonomy(m);
  $('#candBtn').disabled = st.search?.mode === 'real';
  $('#candMarkerBtn').disabled = st.search?.mode === 'real' || !st.marker;  // TEMPORARY
  $('#candBtn').textContent = hidden.length ? 'Add another' : 'Place candidate';
  $('#candClear').hidden = !t || st.search?.mode === 'real';
  // Mock people may not be scattered through a search for a real one — the hub
  // refuses it, so the control says so rather than letting it be pressed.
  $('#simBtn').disabled = st.search?.mode === 'real';
}

// A sighting's `confidence` is several phones' scores combined under an
// independence assumption they don't really satisfy — three phones pointed at the
// same person from the same side are one look, not three. The number is still
// what the thresholds use, but what an operator is shown is the evidence it came
// from: the best single match, and how many phones are currently looking.
// The planner's name for a spot on the floor — "D2" — the same grid the map labels,
// the recommendations and the phone guidance all speak. Null before the planner has
// published a grid, or for a point outside it.
function sectorAt(x, y) {
  const size = st?.planner?.sectorSize;
  if (!size || !room) return null;
  const col = Math.floor((x + room.width / 2) / size), row = Math.floor(y / size);
  if (col < 0 || row < 0 || col >= (st.planner.cols ?? Infinity) || row >= (st.planner.rows ?? Infinity)) return null;
  return `${String.fromCharCode(65 + col)}${row + 1}`;
}

// In a real search every score behind `confidence` is itself a rescale of the
// model's similarity, so a percentage built from them is two derivations away
// from anything measured. Show the model's own number against the threshold it
// is judged by; fall back to the score only in a rehearsal, where the mock
// detector emits one directly and there is no similarity to show.
function sightingEvidence(sg) {
  const threshold = st?.search?.threshold;
  const best = sg.similarity != null
    ? `similarity ${sg.similarity.toFixed(2)}${threshold != null ? ` vs ${threshold.toFixed(2)}` : ''}`
    : `best match ${Math.round((sg.bestScore ?? sg.confidence) * 100)}%`;
  return sg.agree > 1 ? `${best} · ${sg.agree} phones agree` : best;
}

function plural(n, one, many) {
  return `${n} ${n === 1 ? one : many}`;
}

// `attended` means "everyone we managed to dispatch has arrived", which is true
// the instant somebody is found — the finder counts as arrived and is often the
// only responder there is. Saying RESCUED on the strength of that claims a team
// showed up when nobody did, so the console asks the harder question: are as many
// people with them as the operator asked for?
function teamArrived(v) {
  return Object.values(v.responders || {}).filter(Boolean).length;
}
function teamFull(v) {
  const wanted = v.respondersWanted ?? 0;
  return wanted > 0 && teamArrived(v) >= wanted;
}

// The live strip under the top bar. The Search status card still holds the full
// picture; this is the one line an operator standing back from the screen has to
// read — and when somebody is found it goes red, because that is the moment the
// whole room needs to notice. Everything in it is a field the hub already sends:
// the finder's phone number, the planner's sector, responders dispatched and
// responders who have arrived. Nothing here is a derived score.
function whereVictim(v) {
  const sector = sectorAt(v.x, v.y);
  return sector ? `in ${sector}` : `${Math.max(0, v.y).toFixed(1)} m from the stage`;
}

// Who is left: by name when the reference photos named them, by count in a
// rehearsal where the hidden candidates have no names.
function stillLooking(victims, t) {
  const people = st.search?.people || [];
  if (people.length) {
    const found = new Set(victims.map((v) => v.label));
    const left = people.filter((p) => !found.has(p.label)).map((p) => p.label);
    if (!left.length) return victims.length ? 'Everyone found' : '';
    return `Still looking for ${left.slice(0, 2).join(' and ')}${left.length > 2 ? ` +${left.length - 2}` : ''}`;
  }
  const missing = t?.stillMissing || 0;
  if (missing) return `Still looking for ${plural(missing, 'person', 'people')}`;
  return victims.length ? 'Everyone found' : '';
}

function renderLive(victims, t) {
  const strip = $('#liveStrip');
  const lead = $('#liveLead');
  const aside = $('#liveAside');
  let state = '';
  let text = '';
  let side = '';
  if (victims.length) {
    // Newest find leads; `foundMs` counts up from the moment it happened.
    const v = victims.reduce((a, b) => (b.foundMs < a.foundMs ? b : a));
    const finder = phones.get(v.foundBy);
    const sent = Object.keys(v.responders || {}).length;
    state = 'found';
    text = `${v.label} found ${whereVictim(v)} by #${finder?.index ?? '?'}`
      + ` · ${plural(sent, 'responder', 'responders')} sent, ${teamArrived(v)} have reached`;
    side = victims.length > 1 ? `${victims.length} found · ${stillLooking(victims, t)}` : stillLooking(victims, t);
  } else {
    const top = (st.sightings || []).reduce((a, b) => (b.confidence > (a?.confidence ?? 0) ? b : a), null);
    if (top && top.confidence >= 0.4) {
      const sector = sectorAt(top.x, top.y);
      state = 'warn';
      text = `Possible sighting${sector ? ` in ${sector}` : ''} · ${sightingEvidence(top)}`;
      side = stillLooking(victims, t);
    } else if (running()) {
      const { live } = readiness();
      text = `Searching · ${plural(live, 'phone', 'phones')} · `
        + `${Math.round((st.coverage?.searched || 0) * 100)}% of the room covered`;
      // The most likely sector belongs over the map it points at, where it is
      // already printed with its share; saying it twice on one screen is worse
      // than saying it once.
      side = stillLooking(victims, t);
    }
  }
  strip.hidden = !text;
  strip.classList.toggle('found', state === 'found');
  strip.classList.toggle('warn', state === 'warn');
  if (lead.textContent !== text) lead.textContent = text;
  if (aside.textContent !== side) aside.textContent = side;
}

// Both lists are rebuilt from innerHTML, and state arrives ten times a second, so they only
// redraw when something in them actually changed.
const listMemo = {found: null, people: null};

// Everyone found so far, in the order they were found.
function renderFoundList(victims) {
  const key = JSON.stringify(victims);
  if (key === listMemo.found) return;
  listMemo.found = key;
  $('#foundList').innerHTML = victims.map((v) => {
    // One fact per row: how many responders are with them. Who found them is in
    // the strip at the top and in the Activity log, and "found by #?" — which
    // is what a finder who has since left the swarm renders as — says nothing.
    const detail = `${teamArrived(v)} of ${v.respondersWanted ?? 0} with them`;
    return `<div class="found-row"><span class="who">${teamFull(v) ? '✓' : '→'} ${escapeHtml(v.label || `Person ${v.id}`)}</span>`
      + `<span>${escapeHtml(detail)}</span></div>`;
  }).join('');
}

// The line every phone shows is not a second thing to type: it is the roster,
// written out. Each person contributes their name and, if the operator gave
// one, how to recognise them; the hub clamps the result to 80 characters.
let lookingForSent = null;

function lookingForLine(people = []) {
  return people.map((p) => p.note ? `${p.label} (${p.note})` : p.label).join(' · ').slice(0, 80);
}

function pushLookingFor(people) {
  const text = lookingForLine(people);
  const first = lookingForSent === null;
  if (first) lookingForSent = st?.lookingFor ?? '';
  // An empty roster at load means the console has nothing to say yet, not that
  // the line should be cleared — Mission Control can set it too.
  if (first && !people.length) return;
  if (text === lookingForSent) return;
  lookingForSent = text;
  send({ type: 'looking_for', text });
}

// Radio: everything a searcher has said out loud. The phones transcribe speech
// and the hub files it in the planner log as a quoted line; this pulls those
// out so a voice from the room is a channel of its own rather than something
// that scrolls past between two planner notes.
const SAID = '🎙';
let radioKey = '';

function renderRadio() {
  const said = (st.planner?.log || []).filter((e) => e.text.startsWith(SAID));
  $('#radioCount').textContent = said.length ? `${said.length} heard` : '';
  const key = JSON.stringify(said);
  if (key === radioKey) return;
  radioKey = key;
  $('#radio').innerHTML = said.length ? [...said].reverse().slice(0, 6).map((e) => {
    const p = e.phoneId && phones.get(e.phoneId);
    const when = new Date(e.t).toLocaleTimeString([], { hour12: false });
    return `<div class="say"><span class="who">${p ? `#${p.index}` : '·'}</span>`
      + `<div><div class="text">${escapeHtml(e.text.slice(SAID.length).trim())}</div><time>${when}</time></div></div>`;
  }).join('') : '<div class="empty">Nothing heard yet</div>';
}

// The rescue team: one row per phone, said as a person rather than a camera.
// Everything here is the same state the map and the feed wall draw — the
// planner's assignment, the responder lists on each find, the phone's own task
// line — so a row never claims something the rest of the console does not show.
let teamKey = '';

function whoIs(v) {
  return v.label || `Person ${v.id}`;
}

function teamDoing(p) {
  if (!p.connected) return ['Offline', false];
  for (const v of st.target?.victims || []) {
    if (v.foundBy === p.id) return [`found ${whoIs(v)}`, true];
    if (v.responders && p.id in v.responders) {
      return [v.responders[p.id] ? `with ${whoIs(v)}` : `going to ${whoIs(v)}`, true];
    }
  }
  if (p.stale) return ['No signal', false];
  if (p.task) return [p.task, false];
  const job = st.planner?.assignments?.[p.id];
  if (job) return [`searching ${job.sector}`, false];
  return [running() ? 'looking around' : 'waiting', false];
}

function renderTeam() {
  const list = [...phones.values()].sort((a, b) => a.index - b.index);
  const rows = list.map((p) => ({ id: p.id, index: p.index, name: p.name || 'Phone',
                                  live: isLive(p), doing: teamDoing(p) }));
  $('#teamCount').textContent = rows.length ? `${rows.filter((r) => r.live).length} on the floor` : '';
  const key = JSON.stringify(rows);
  if (key === teamKey) return;
  teamKey = key;
  $('#teamList').innerHTML = rows.length ? rows.map((r) =>
    `<button type="button" class="team-row${r.live ? '' : ' off'}${r.doing[1] ? ' hot' : ''}" data-phone="${escapeHtml(r.id)}">`
    + `<span class="idx mono">#${r.index}</span><span class="who">${escapeHtml(r.name)}</span>`
    + `<span class="what">${escapeHtml(r.doing[0])}</span></button>`).join('')
    : '<div class="empty">Nobody has joined yet</div>';
}

$('#teamList').addEventListener('click', (event) => {
  const id = event.target.closest('[data-phone]')?.dataset.phone;
  if (id) openViewer(id);
});

// What the swarm has flagged in the room: obstacles in the way, and people it
// has seen but not identified. Straight off `hazards` and `detectedPeople` in
// the hub's state — the same observations the map draws — named by the
// planner's sector and aged from the observation's own timestamp. The phones
// report these on their own while the search runs; there is nothing to start.
let threatKey = '';

function renderThreats() {
  const now = st.t || Date.now();
  const rows = [
    ...(st.hazards || []).map((h) => ({ ...h, what: 'Obstacle' })),
    ...(st.detectedPeople || []).map((h) => ({ ...h, what: 'Unidentified person' })),
  ].sort((a, b) => b.t - a.t);
  // The console's state sends the raw observations, so staleness is worked out
  // here on the same 15 s the map uses rather than read off a field only the
  // phones' world message carries.
  for (const r of rows) r.old = Date.now() - r.t > 15000;
  const key = JSON.stringify(rows.map((r) => [r.id, r.old]));
  $('#threatCount').textContent = rows.length ? `${rows.length} flagged` : '';
  if (key === threatKey) return;
  threatKey = key;
  if (!rows.length) {
    $('#threatList').innerHTML = running()
      ? '<div class="empty">Nothing flagged yet</div>'
      : '<div class="empty">Phones flag obstacles once the search starts</div>';
    return;
  }
  $('#threatList').innerHTML = rows.map((r) => {
    const sector = sectorAt(r.x, r.y);
    const where = sector ? `in ${sector}` : `${Math.max(0, r.y).toFixed(1)} m from the stage`;
    const age = Number.isFinite(r.t) ? `${Math.max(0, Math.round((now - r.t) / 1000))}s ago` : '';
    return `<div class="threat-row${r.old ? ' stale' : ''}"><span class="what">${r.what}</span>`
      + `<span class="where">${escapeHtml(where)}</span><span class="age">${age}</span></div>`;
  }).join('');
}

// Room coordinates are meters with the stage at the top of the map: x = 0 at
// stage center (+x right), y = 0 at the stage edge (+y toward the back), and
// heading 0 = facing the stage, clockwise from above. "-0.6, 0.9 · slam" makes
// an operator decode that; these spell it out instead.
const FACING = ['the stage', 'stage-right', 'the right wall', 'back-right',
                'the back wall', 'back-left', 'the left wall', 'stage-left'];
const POSE_SOURCE = { slam: 'tracked by the phone', seat: 'from the seat it scanned', sim: 'simulated' };

function fmtPosition(pose) {
  if (!pose) return 'Not placed yet';
  const across = Math.abs(pose.x) < 0.15 ? 'On the center line' : `${Math.abs(pose.x).toFixed(1)} m ${pose.x < 0 ? 'left' : 'right'} of center`;
  return `${across} · ${Math.max(0, pose.y).toFixed(1)} m from stage`;
}

function poseHint(pose) {
  return pose ? `x ${pose.x.toFixed(1)} m, y ${pose.y.toFixed(1)} m · ${POSE_SOURCE[pose.source] || pose.source}`
    : 'This phone has no known spot in the room yet, so it cannot be drawn on the map.';
}

function fmtHeading(pose) {
  if (pose?.heading == null) return 'Unknown';
  const deg = (Math.round(pose.heading) % 360 + 360) % 360;
  return `${deg}° · facing ${FACING[Math.round(deg / 45) % 8]}`;
}

function fmtTilt(pitch) {
  if (pitch == null) return 'Unknown';
  const deg = Math.round(pitch);
  return Math.abs(deg) < 8 ? `${Math.abs(deg)}° · level`
    : `${Math.abs(deg)}° ${deg > 0 ? 'up' : 'down'}${Math.abs(deg) > 65 ? deg > 0 ? ' · at the ceiling' : ' · at the floor' : ''}`;
}

// Whether this feed is real *right now*. `phoneStatus` deliberately does not
// carry it: the card and the expanded viewer both want it first in the row and
// everything else after, so it is prepended rather than mixed in.
function liveBadge(p) {
  return !p.connected ? ['Offline · last frame', ''] : p.stale ? ['No signal', 'r'] : ['Live', 'w'];
}

// The badge row. The expanded viewer used to print this *and* a second pill
// over the video saying the same word, so a phone that had dropped announced
// "No signal" twice, six millimetres apart. One fact, one badge.
function statusBadges(p) {
  return [liveBadge(p), ...phoneStatus(p).filter(([label]) => label !== 'Offline' && label !== 'No signal')]
    .map(([s, c]) => `<span class="badge ${c}">${s}</span>`).join('');
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
  if (p.sim) out.push(['Simulated', '']);
  if (p.hidden) out.push(['Hidden', '']);
  if (p.speaking) out.push(['🎙 Speaking', 'w']);
  if (p.oldPage && !p.sim && p.connected) out.push(['Old page · reload', 'r']);
  return out;
}

function renderPhones() {
  const list = [...phones.values()].sort((a, b) => a.index - b.index);
  // A bare count says nothing about whether the wall is working. Live is the
  // number sending video right now; the rest have joined and gone quiet.
  const liveCount = list.filter(isLive).length;
  const offline = list.length - liveCount;
  $('#phoneCount').textContent = !list.length ? ''
    : `${liveCount} live${offline ? ` · ${offline} offline` : ''}`;
  $('#phonesEmpty').hidden = list.length > 0;
  const body = $('#phones');
  body.hidden = !list.length;
  // Preserve cards so incoming state retains their video elements.
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
        <div class="camera-caption"></div></button>`;
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
    // Position, facing, fps, latency and Remove all live in the expanded feed,
    // one click away; a tile in the wall is the picture and who it belongs to.
    card.querySelector('.st').innerHTML = statusBadges(p);
  });
  for (const card of existing.values()) card.remove();
}
$('#phones').addEventListener('click', (e) => {
  const card = e.target.closest('.camera-card');
  const p = card && phones.get(card.dataset.id);
  if (p && e.target.closest('[data-act]')) openViewer(p.id);
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
  document.body.classList.add('viewer-docked');
  // Two panels cannot share the right edge; opening one puts the other away.
  if (!$('#chatPanel').hidden) toggleChat(false, false);
  resizeMap();
  send({ type: 'focus', phoneId: id }); // hub streams this phone faster while it's open
  renderViewer();
}

function closeViewer() {
  viewing = null;
  clearSourceFrames();
  clearHud();
  $('#viewer').classList.remove('on');
  document.body.classList.remove('viewer-docked');
  viewerLogKey = '';
  resizeMap();
  send({ type: 'focus', phoneId: null });
}

function stepViewer(d) {
  const list = [...phones.values()].sort((a, b) => a.index - b.index);
  const i = list.findIndex((p) => p.id === viewing);
  if (list.length) openViewer(list[(i + d + list.length) % list.length].id);
}

function renderViewer() {
  if (!viewing) return;
  const p = phones.get(viewing);
  if (!p) { closeViewer(); return; }
  $('#vNum').textContent = `#${p.index}`;
  const cap = $('#vCap');
  cap.textContent = p.caption ? p.caption.text : p.speaking ? '…' : '';
  cap.classList.toggle('on', !!(p.caption || p.speaking));
  $('#vName').textContent = p.name || 'Phone';
  $('#vBadges').innerHTML = statusBadges(p);
  const pose = p.pose;
  const job = st.planner?.assignments?.[p.id];
  // `gain` is the chance THIS look finds them, not the phone's odds overall —
  // "1.9% find chance" reads like the phone is useless.
  $('#vTask').textContent = p.task
    || (job ? `searching ${job.sector}${job.gain ? ` · ${(job.gain * 100).toFixed(1)}% chance this look finds them` : ''}` : 'idle');
  $('#vPos').textContent = fmtPosition(pose);
  $('#vPos').title = poseHint(pose);
  $('#vHd').textContent = fmtHeading(pose);
  $('#vPitch').textContent = fmtTilt(p.pitch);
  $('#vFps').textContent = `${p.fps.toFixed(1)} / s`;
  // A bare area means nothing on its own — say what share of the floor it is.
  const m2 = p.searchedM2 ?? 0, floor = room ? room.width * room.depth : 0;
  $('#vM2').textContent = floor ? `${m2} m² · ${Math.round(100 * m2 / floor)}% of the floor` : `${m2} m²`;
  renderViewerLog(p);
}

// What the planner has recorded about this camera, newest first. The console's
// own Activity card keeps the whole room's story; this is the slice belonging
// to the phone on screen, and it is rebuilt only when it changes.
let viewerLogKey = '';

function renderViewerLog(p) {
  const mine = (st.planner?.log || []).filter((e) => e.phoneId === p.id).slice(-8).reverse();
  const key = `${p.id}:${JSON.stringify(mine)}`;
  if (key === viewerLogKey) return;
  viewerLogKey = key;
  $('#vLog').innerHTML = mine.length ? mine.map((e) => {
    const t = new Date(e.t).toLocaleTimeString([], { hour12: false });
    const hot = /FOUND|dispatched/.test(e.text) ? ' hot' : '';
    return `<div class="ev${hot}"><time>${t}</time><div>${escapeHtml(e.text)}</div></div>`;
  }).join('') : '<div class="empty">Nothing from this camera yet</div>';
}

$('#vClose').addEventListener('click', closeViewer);
$('#vHud').addEventListener('click', toggleHud);
$('#vHud').classList.toggle('on', showHud);
function toggleHud() {
  showHud = !showHud;
  try { localStorage.setItem('swarm.hud', showHud ? '1' : '0'); } catch {}
  $('#vHud').classList.toggle('on', showHud);
}

// The phone's mini-map, mirrored into the corner of its feed.
//
// `MiniMapView` in `FloorPlanViews.swift`: a 132x164 plate resting bottom-left,
// the room drawn with `followsMe` — which scrolls the plan so the operator is
// in the middle, and does *not* rotate it — at `padding: 6` and `showsDetail:
// false`, with a "x% searched" strip under it.
//
// Drawn from the console's own world rather than from anything the phone sends,
// because both are drawing the same hub state. What the phone does not send is
// where the plate actually is: the operator can drag it to another corner and
// can hide it, so this is the resting position, not a promise about theirs.
const MINI_W = 132, MINI_H = 164, MINI_FOOT = 22;

function drawHudMiniMap(ctx, sx, sy, sw, sh, k) {
  const me = phones.get(viewing)?.pose;
  if (!room || !me || !view) return;
  const w = Math.min(MINI_W * k, sw * 0.42), h = w * (MINI_H / MINI_W);
  if (w < 60) return;                       // too small to read: better nothing
  const foot = MINI_FOOT * (w / MINI_W);
  const x = sx + 12 * k, y = sy + sh - h - 12 * k;
  const planH = h - foot;

  ctx.save();
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, 10 * (w / MINI_W));
  ctx.clip();
  ctx.fillStyle = '#f7fbf8';
  ctx.fillRect(x, y, w, h);

  // Same fit the phone uses, then shifted so the operator sits in the middle.
  const mv = makeView(room, w, planH, 6 * (w / MINI_W));
  const [fx, fy] = mv.toPx(me.x, me.y);
  ctx.save();
  ctx.beginPath();
  ctx.rect(x, y, w, planH);
  ctx.clip();
  ctx.translate(x + w / 2 - fx, y + planH / 2 - fy);
  drawRoom(ctx, room, mv, {
    grid: false, label: false,
    colors: { floor: '#ffffff', wall: '#789b85', stage: '#deeee3', text: '#466653' },
  });
  const dot = (px, py, r, fill) => {
    ctx.fillStyle = fill;
    ctx.beginPath(); ctx.arc(px, py, r, 0, Math.PI * 2); ctx.fill();
  };
  for (const h2 of st?.hazards || []) { const [px, py] = mv.toPx(h2.x, h2.y); dot(px, py, 2.5, '#d97706'); }
  for (const v of st?.target?.victims || []) { const [px, py] = mv.toPx(v.x, v.y); dot(px, py, 4, '#b72f36'); }
  for (const other of phones.values()) {
    if (other.id === viewing || !other.pose || !isLive(other)) continue;
    const [px, py] = mv.toPx(other.pose.x, other.pose.y);
    dot(px, py, 3, 'rgba(24,131,75,.55)');
  }
  const [px, py] = mv.toPx(me.x, me.y);
  if (me.heading != null) {
    const [hx, hy] = headingVector(me.heading);
    ctx.strokeStyle = '#18834b';
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(px, py); ctx.lineTo(px + hx * 11, py + hy * 11); ctx.stroke();
  }
  dot(px, py, 4.5, '#18834b');
  ctx.restore();

  // The strip under it: how much of the room has been swept, and by how many.
  ctx.fillStyle = '#edf6ef';
  ctx.fillRect(x, y + planH, w, foot);
  ctx.fillStyle = 'rgba(23,55,38,.12)';
  ctx.fillRect(x, y + planH, w, 1);
  ctx.fillStyle = '#466653';
  ctx.font = `500 ${Math.round(10 * (w / MINI_W))}px Geist, system-ui`;
  ctx.textAlign = 'left';
  ctx.textBaseline = 'middle';
  ctx.fillText(`${Math.round((st?.coverage?.searched || 0) * 100)}% searched`,
               x + 6 * (w / MINI_W), y + planH + foot / 2);
  ctx.textAlign = 'right';
  ctx.fillText(String([...phones.values()].filter(isLive).length), x + w - 6 * (w / MINI_W), y + planH + foot / 2);
  ctx.restore();

  ctx.strokeStyle = 'rgba(23,55,38,.25)';
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.roundRect(x + .5, y + .5, w - 1, h - 1, 10 * (w / MINI_W));
  ctx.stroke();
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
  // The standing wash first, under everything: what situation the person
  // holding this phone is in. Colour at the bezel, clear in the middle — they
  // are walking while it is up.
  if (hud.ambient) {
    const cx = sx + sw / 2, cy = sy + sh / 2, peak = (hud.ambient.intensity ?? 0.7) * 0.62;
    const wash = ctx.createRadialGradient(cx, cy, Math.min(sw, sh) * 0.2, cx, cy, Math.max(sw, sh) * 0.8);
    wash.addColorStop(0, hexAlpha(hud.ambient.color, 0));
    wash.addColorStop(0.55, hexAlpha(hud.ambient.color, peak * 0.4));
    wash.addColorStop(1, hexAlpha(hud.ambient.color, peak));
    ctx.fillStyle = wash;
    ctx.fillRect(sx, sy, sw, sh);
  }
  const k = sw / 390; // scale phone-sized HUD elements to the drawn screen (≈ iPhone width in CSS px)
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';

  // detection boxes and AR markers live in frame coordinates
  for (const d of hud.dets || []) {
    ctx.strokeStyle = d.label === 'Hazard' ? '#f59e0b' : d.possibleMatch ? '#22c55e' : '#ff5d73';
    ctx.lineWidth = 2;
    ctx.strokeRect(d.x * W, d.y * H, d.w * W, d.h * H);
    if (d.possibleMatch && Number.isFinite(d.similarity)) pill(ctx, (d.x + d.w / 2) * W, d.y * H - 12, `Possible match · ${Math.round(Math.max(0, Math.min(1, d.similarity)) * 100)}%`, '#15803d', '#fff', 11, true);
    if (d.label === 'Hazard') pill(ctx, (d.x + d.w / 2) * W, d.y * H - 12, 'Hazard', '#b45309', '#fff', 11, true);
  }
  for (const m of hud.ar || []) {
    const x = m.x * W, y = m.y * H, r = Math.max(6, m.r * sh);
    ctx.fillStyle = m.color;
    ctx.strokeStyle = 'rgba(0,0,0,0.6)';
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(x, y - r); ctx.lineTo(x + r, y); ctx.lineTo(x, y + r); ctx.lineTo(x - r, y); ctx.closePath();
    if (m.hollow) {
      // A teammate, not a find: outline only, so a searcher is never read as
      // the person being searched for. Dark pass first, for contrast over a
      // bright frame.
      ctx.strokeStyle = 'rgba(0,0,0,0.5)'; ctx.lineWidth = 4; ctx.stroke();
      ctx.strokeStyle = m.color; ctx.lineWidth = 2; ctx.stroke();
    } else {
      ctx.fill(); ctx.stroke();
    }
    pill(ctx, x, y - r - 13 * k, m.label, 'rgba(0,0,0,0.7)', '#fff', 12 * k);
  }

  // screen-space HUD, stacked from the top of the phone's screen
  let top = sy + 8 * k;
  if (hud.compass) { drawTape(ctx, sx + 8 * k, top, sw - 16 * k, 40 * k, hud.compass, k); top += 48 * k; }
  // Under the tape and above the banner: something in the way outranks the
  // search instruction, because one of them is about to be underfoot.
  if (hud.warning) { pill(ctx, sx + sw / 2, top + 12 * k, hud.warning.text, hud.warning.color, '#1a1200', 13 * k, true); top += 30 * k; }
  if (hud.banner) {
    const [bg, fg] = TONES[hud.banner.tone] || TONES.warn;
    pill(ctx, sx + sw / 2, top + 16 * k, hud.banner.text, bg, fg, 15 * k, true);
    top += 40 * k;
  }
  if (hud.lookingFor) { pill(ctx, sx + sw / 2, top + 12 * k, hud.lookingFor, 'rgba(12,17,32,0.85)', '#eef2ff', 12 * k); top += 30 * k; }
  if (hud.toast) { pill(ctx, sx + sw / 2, top + 14 * k, hud.toast, 'rgba(255,255,255,0.95)', '#05070f', 13 * k, true); top += 36 * k; }
  // The mini-map the searcher has in the corner of their own screen.
  drawHudMiniMap(ctx, sx, sy, sw, sh, k);

  // The full-screen card, drawn last so it covers the HUD it stands in for —
  // with a real hole in it, so the operator sees the same window onto the feed
  // that the searcher is looking through.
  if (hud.takeover) {
    const t = hud.takeover;
    // The window comes from the card's own row, so the console cuts the same
    // hole the phone does — including the hazard card's much wider one.
    const wx = sx + sw * t.insetX, wy = sy + sh * t.top;
    const ww = sw - sw * t.insetX * 2, wh = sh * (t.bottom - t.top);
    ctx.save();
    // Even-odd: the outer rect minus the window, so the plate is a frame.
    ctx.beginPath();
    ctx.rect(sx, sy, sw, sh);
    ctx.roundRect(wx, wy, ww, wh, 8 * k);
    ctx.fillStyle = t.color;
    ctx.fill('evenodd');
    ctx.strokeStyle = 'rgba(255,255,255,0.35)';
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.roundRect(wx, wy, ww, wh, 8 * k); ctx.stroke();
    ctx.fillStyle = '#fff';
    ctx.font = `800 ${(t.kind === 'hazard' ? 28 : 34) * k}px Geist, system-ui`;
    ctx.fillText(t.title, sx + sw / 2, wy * 0.62 + sy * 0.38);
    if (t.detail) {
      ctx.font = `600 ${17 * k}px Geist, system-ui`;
      ctx.fillText(t.detail, sx + sw / 2, wy - 22 * k);
    }
    if (t.badge) {
      // The other thing that is also true, in its own colour.
      pill(ctx, sx + sw / 2, wy - (t.detail ? 46 : 22) * k, t.badge.text, t.badge.color, '#fff', 13 * k, true);
    }
    if (t.footer) {
      ctx.font = `600 ${15 * k}px Geist, system-ui`;
      ctx.fillText(t.footer, sx + sw / 2, (wy + wh + sy + sh) / 2);
    }
    ctx.restore();
  }
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

/// `#rrggbb` plus an alpha, for a canvas gradient stop.
function hexAlpha(hex, alpha) {
  const value = /^#([0-9a-f]{6})$/i.exec(hex || '');
  if (!value) return `rgba(255,93,115,${alpha})`;
  const n = parseInt(value[1], 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`;
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
$('#vRemove').addEventListener('click', () => {
  const p = phones.get(viewing);
  if (p) removePhone(p);
});

// Removing a camera ends that person's session on their phone, so it asks first.
function removePhone(p) {
  if (!confirm(`Remove camera #${p.index}${p.name ? ` (${p.name})` : ''}?\n\n`
    + 'Their phone leaves the swarm and stops streaming. They can rejoin from the QR code.')) return;
  send({ type: 'remove', phoneId: p.id });
  if (viewing === p.id) closeViewer();
}

// Entries at or before this hub timestamp were wiped by a reset and are not
// drawn again. The hub clears `planner.log` on reset too; this covers the
// second or so afterwards, when the phase change the reset itself causes would
// otherwise be the only line in a log the operator just emptied.
let logSince = 0;

function renderLog() {
  const log = [...(st.planner?.log || [])]
    .filter((e) => e.t > logSince && !e.text.startsWith(SAID)).reverse().slice(0, 5);
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
  if (ev.sighting) rows.push(['Sighting', `${sightingEvidence(ev.sighting)} at ${pos(ev.sighting.x, ev.sighting.y)}`]);
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
    ctx.fillText('sighting', sx, sy - 24);
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
// Reset is one click from the top bar and there is no undo, so it asks first.
$('#resetSession').addEventListener('click', () => $('#resetConfirm').showModal());
$('#resetCancel').addEventListener('click', () => $('#resetConfirm').close());
$('#resetGo').addEventListener('click', () => {
  $('#resetConfirm').close();
  logSince = (st?.t ?? Date.now()) + 1000;
  if (st?.planner) { st.planner.log = []; renderLog(); renderRadio(); }
  if (st?.search?.mode === 'rehearsal') send({ type: 'target', remove: true });
  send({ type: 'reset_coverage' });
  send({ type: 'phase', phase: IDLE_PHASE, restart: true });
  $('#searchMessage').textContent = '';
});
// One press stages a whole drill; the hub picks the counts and the positions, because
// it is the thing that knows the room and what is already on the floor. Starting the
// search stays a separate press, exactly as it is for a hand-placed candidate.
$('#simBtn').addEventListener('click', () => send({ type: 'simulate' }));
$('#candBtn').addEventListener('click', addCandidate);
// TEMPORARY (demo shortcut): hide a test candidate exactly on the printed
// marker, so a phone pointed at the marker has somebody to find there.
$('#candMarkerBtn').addEventListener('click', () => {
  const m = st?.marker;
  if (!m) return;
  send({ type: 'target', responders: respondersPref, x: m.x, y: m.y });
});
$('#candClear').addEventListener('click', () => send({ type: 'target', remove: true }));
$('#respMinus').addEventListener('click', () => setResponders(-1));
$('#respPlus').addEventListener('click', () => setResponders(+1));


function addCandidate() {
  // The first one goes in the middle of the floor; the rest spiral out around it on the golden
  // angle, so a second and third candidate never land underneath the first.
  const n = hiddenCandidates().length;
  const reach = 2.5 * Math.sqrt(n), angle = n * 2.399;
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  send({ type: 'target', responders: respondersPref,
         x: clamp(Math.cos(angle) * reach, -room.width / 2 + .5, room.width / 2 - .5),
         y: clamp(room.depth / 2 + Math.sin(angle) * reach, .5, room.depth - .5) });
}

function setResponders(d) {
  respondersPref = Math.max(0, Math.min(10, (st?.target?.respondersWanted ?? respondersPref) + d));
  $('#respN').textContent = respondersPref;
  if (st?.target) send({ type: 'target', responders: respondersPref });
}

function toggleChat(open, restoreFocus = true) {
  if (open && viewing) closeViewer();
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
  if (mode !== 'heatmap' && mode !== 'grid' && mode !== '3d') return;
  mapMode = mode;
  for (const button of document.querySelectorAll('#mapModes button')) {
    button.setAttribute('aria-pressed', String(button.dataset.mode === mode));
  }
  const is3d = mode === '3d';
  $('#map').hidden = is3d;
  $('#mapWrap').classList.toggle('mode-3d', is3d);
  $('#scene3d').hidden = !is3d;
  $('#mapStatus').textContent = '';
  if (!is3d) {
    scene3d?.hide();
    gridKey = '';
    resizeMap();
    return;
  }
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

// The legend's ramp is painted from the same constants the map is, so the
// swatch cannot drift away from the field it explains.
$('#heatLegend i').style.backgroundImage = heatGradientCSS();

const canvas = $('#map');
const ctx = canvas.getContext('2d');
let view = null;
const coverageLayer = document.createElement('canvas');
const gridLayer = document.createElement('canvas');
const heatTile = document.createElement('canvas');  // cols×rows, reused every rebuild
let coverageKey = '';
let gridKey = '';
const mapLabelRects = [];
/// How much of the camera's real range the map's view wedge draws.
const CONE_DRAW_SCALE = 0.6;
const MAP_MARKER_RADIUS = 10;
const MAP_MARKER_STROKE = 2;
const MAP_LABEL_HEIGHT = 18;
const MAP_LABEL_GAP = 4;

// The scale bar states a distance, so it has to be a distance: pick the roundest
// length that lands near 90 px at the current zoom and label the bar with that,
// rather than drawing a fixed 5 m that goes stubby on a small map and spans a
// quarter of the floor on a big one.
const SCALE_STEPS = [0.5, 1, 2, 5, 10, 20, 50];
function setScaleBar(pxPerM) {
  const target = 90;
  const metres = SCALE_STEPS.reduce((best, m) =>
    Math.abs(m * pxPerM - target) < Math.abs(best * pxPerM - target) ? m : best, SCALE_STEPS[0]);
  $('.map-scale i').style.width = `${Math.round(metres * pxPerM)}px`;
  $('.map-scale span').textContent = `${metres} m`;
}

function resizeMap() {
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w || !room) return;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = w * dpr;
  canvas.height = h * dpr;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  view = makeView(room, w, h, 28);
  setScaleBar(view.scale);
  coverageKey = '';
  gridKey = '';
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
    // One pixel per cell, scaled up by the canvas with smoothing on: the field
    // gets exactly one alpha per cell instead of the pile of overlapping discs
    // that used to turn the whole unsearched floor into a flat green sheet.
    const levels = heatLevels(cov);
    if (levels) {
      const [ax, ay] = view.toPx(cov.x0, 0);
      const [bx, by] = view.toPx(cov.x0 + cov.cols * cov.cell, cov.rows * cov.cell);
      layer.save();
      layer.beginPath();
      layer.rect(ax, ay, bx - ax, by - ay);   // heat stops at the walls
      layer.clip();
      layer.imageSmoothingEnabled = true;
      layer.imageSmoothingQuality = 'high';
      // A third of a cell, on top of the scaler's own interpolation: enough to
      // lose the cell edges, not so much that a hotspot a few cells wide is
      // smeared back down into the wash around it.
      layer.filter = `blur(${Math.max(2.5, cov.cell * view.scale * 0.34).toFixed(1)}px)`;
      layer.drawImage(heatCanvas(cov, levels, undefined, heatTile), ax, ay, bx - ax, by - ay);
      layer.filter = 'none';
      layer.restore();
    }
  }
  ctx.drawImage(coverageLayer, 0, 0);
}

// Grid view: exactly what the heatmap is drawn from, with nothing smoothed
// away — every half-metre cell as its own square, shaded by the same ramp, and
// green wherever a camera has actually had a good look. The heatmap blurs all
// of that into a wash on purpose; this is the view for reading the search cell
// by cell, and for seeing which sectors the swarm has genuinely swept.
function drawGrid(cov) {
  if (!cov?.cols || !cov.rows) return;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  const key = `${w}x${h}:${cov.heat}:${cov.cells}:${st.planner?.sectorSize}`;
  if (key !== gridKey) {
    gridKey = key;
    gridLayer.width = w;
    gridLayer.height = h;
    const layer = gridLayer.getContext('2d');
    layer.clearRect(0, 0, w, h);
    const [ax, ay] = view.toPx(cov.x0, 0);
    const [bx, by] = view.toPx(cov.x0 + cov.cols * cov.cell, cov.rows * cov.cell);
    const cw = (bx - ax) / cov.cols, ch = (by - ay) / cov.rows;
    // Same one-pixel-per-cell image the heatmap uses, scaled up with smoothing
    // off and no blur: one flat alpha per cell, edge to edge.
    const levels = heatLevels(cov);
    if (levels) {
      layer.imageSmoothingEnabled = false;
      layer.drawImage(heatCanvas(cov, levels, undefined, heatTile), ax, ay, bx - ax, by - ay);
      layer.imageSmoothingEnabled = true;
    }
    // No second "looked here" wash over the top. A cell a camera has looked at
    // *is* a cleared cell — `coverage.py` drops the probability of exactly the
    // cells it marks looked — so the green was the heat field's pale end said
    // twice, in a different colour, on the same pixels. It was also the worse
    // of the two: `cells` is a one-way latch that saturates within about half a
    // minute of a real search and then covers the floor saying nothing, while
    // the heat keeps moving for the whole search.
    layer.strokeStyle = 'rgba(23,55,38,.09)';
    layer.lineWidth = 1;
    layer.beginPath();
    for (let c = 0; c <= cov.cols; c++) { const x = Math.round(ax + c * cw) + .5; layer.moveTo(x, ay); layer.lineTo(x, by); }
    for (let r = 0; r <= cov.rows; r++) { const y = Math.round(ay + r * ch) + .5; layer.moveTo(ax, y); layer.lineTo(bx, y); }
    layer.stroke();
    drawSectorLines(layer, ax, ay, bx, by);
  }
  ctx.drawImage(gridLayer, 0, 0);
}

// The planner's sectors over the cells, named the way every other part of the
// console names a spot on the floor: "D2", the same grid the recommendations
// and the phone guidance speak.
function drawSectorLines(layer, ax, ay, bx, by) {
  const size = st.planner?.sectorSize;
  if (!size || !room) return;
  const x0 = -room.width / 2;
  const cols = st.planner.cols ?? 0, rows = st.planner.rows ?? 0;
  // The sector grid can run a little past the last cell when the room does not
  // divide evenly; it is drawn inside the floor, not over the walls.
  layer.save();
  layer.beginPath();
  layer.rect(ax, ay, bx - ax, by - ay);
  layer.clip();
  layer.strokeStyle = 'rgba(23,55,38,.26)';
  layer.lineWidth = 1;
  layer.beginPath();
  for (let c = 0; c <= cols; c++) { const x = Math.round(view.toPx(x0 + c * size, 0)[0]) + .5; layer.moveTo(x, ay); layer.lineTo(x, by); }
  for (let r = 0; r <= rows; r++) { const y = Math.round(view.toPx(0, r * size)[1]) + .5; layer.moveTo(ax, y); layer.lineTo(bx, y); }
  layer.stroke();
  layer.fillStyle = 'rgba(70,102,83,.75)';
  layer.font = '600 10px "Geist Mono", ui-monospace, monospace';
  layer.textAlign = 'left';
  layer.textBaseline = 'top';
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const [x, y] = view.toPx(x0 + c * size, r * size);
      layer.fillText(`${String.fromCharCode(65 + c)}${r + 1}`, x + 4, y + 3);
    }
  }
  layer.restore();
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
  if (mapMode === 'grid') drawGrid(st.coverage); else drawCoverage(st.coverage);

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
  drawHazards();
  drawDetectedPeople();
  drawCandidate();
  drawPings();
  drawExplain();
  for (const p of list) {
    drawPhone(p);
  }
}

// The printed alignment marker, wherever the operator put it. Drawn as a tag
// rather than a dot so it reads as a thing on a wall, not another searcher.
// No text label: the legend strip under the map already names the purple tag,
// and a word floating on the floor only crowds the searchers around it.
function drawMarker() {
  const m = st.marker;
  if (!m) return;
  const [x, y] = view.toPx(m.x, m.y);
  ctx.save();
  ctx.translate(x, y);
  ctx.shadowColor = 'rgba(23,55,38,.16)';
  ctx.shadowBlur = 7;
  ctx.shadowOffsetY = 2;
  ctx.fillStyle = MARKER_COLOR;
  ctx.strokeStyle = '#fff';
  ctx.lineWidth = MAP_MARKER_STROKE;
  ctx.beginPath();
  ctx.roundRect(-8, -8, 16, 16, 4);
  ctx.fill();
  ctx.stroke();
  ctx.restore();
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

// Somebody already found, with responders on them: their detections aren't news any more.
function alreadyFound(x, y, radius = 2) {
  return (st.target?.victims || []).some(v => Math.hypot(v.x - x, v.y - y) <= radius);
}

function drawHazards() {
  for (const hazard of st.hazards || []) {
    const stale = Date.now() - hazard.t > 15000;
    const [x, y] = view.toPx(hazard.x, hazard.y);
    ctx.save();
    ctx.globalAlpha = stale ? .5 : 1;
    ctx.fillStyle = '#fef3c7'; ctx.strokeStyle = '#b45309'; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(x, y - 11); ctx.lineTo(x + 11, y + 9);
    ctx.lineTo(x - 11, y + 9); ctx.closePath(); ctx.fill(); ctx.stroke();
    // Fixed geometry keeps the symbol inside the triangle regardless of canvas text state.
    ctx.fillStyle = '#92400e';
    ctx.fillRect(x - 1, y - 3, 2, 6);
    ctx.fillRect(x - 1, y + 5, 2, 2);
    ctx.restore();
  }
}

function drawDetectedPeople() {
  for (const person of st.detectedPeople || []) {
    const [x, y] = view.toPx(person.x, person.y);
    const stale = Date.now() - person.t > 15000;
    const color = stale ? '#78716c' : '#2563eb';
    drawPersonGlyph(x, y, color);
  }
}

function drawSightings() {
  for (const sg of st.sightings || []) {
    if (sg.confidence < 0.4 || alreadyFound(sg.x, sg.y)) continue;
    const [x, y] = view.toPx(sg.x, sg.y);
    const k = (performance.now() / 1000) % 1;
    ctx.save();
    ctx.strokeStyle = `rgba(217,119,6,${.55 * (1 - k)})`;
    ctx.lineWidth = 2;
    ctx.beginPath(); ctx.arc(x, y, MAP_MARKER_RADIUS + MAP_MARKER_STROKE + 1 + k * 15, 0, Math.PI * 2); ctx.stroke();
    ctx.restore();
    drawPersonGlyph(x, y, '#d97706');
    drawMapLabel(sg.agree > 1 ? `POSSIBLE · ${sg.agree} PHONES` : 'POSSIBLE', x, personLabelY(y), '#d97706');
  }
}

// Every hidden mock candidate, and everyone the swarm has actually found.
function hiddenCandidates() {
  const t = st?.target;
  if (!t) return [];
  if (t.candidates) return t.candidates;
  return t.x == null ? [] : [{ id: null, x: t.x, y: t.y, found: !!t.foundBy }];  // older hub
}

function drawCandidate() {
  const sighting = st.targetSighting;
  if (sighting) {
    const [x, y] = view.toPx(sighting.x, sighting.y);
    const color = sighting.confirmed ? '#b72f36' : '#d97706';
    drawPersonGlyph(x, y, color);
    if (Number.isFinite(sighting.similarity)) drawMapLabel(`${Math.round(Math.max(0, sighting.similarity) * 100)}%`, x, personLabelY(y), color);
  }
  const t = st.target;
  if (!t) return;
  const hidden = hiddenCandidates();
  // Past a handful, a column of "TEST TARGET n" pills is one grey smear over the
  // floor: the dashed ring already says test target, so the number alone will do.
  const terse = hidden.filter((c) => !c.found).length > 3;
  for (const c of hidden) {
    const at = dragPos && dragPos.id === c.id ? dragPos : c;
    const [mx, my] = view.toPx(at.x, at.y);
    ctx.strokeStyle = c.found ? 'rgba(23,55,38,0.24)' : '#597562';
    ctx.lineWidth = 1.5;
    ctx.setLineDash([3, 3]);
    ctx.beginPath(); ctx.arc(mx, my, 8, 0, Math.PI * 2); ctx.stroke();
    ctx.setLineDash([]);
    if (!c.found) drawMapLabel(c.id == null ? 'TEST TARGET' : terse ? `#${c.id}` : `TEST TARGET ${c.id}`,
                               mx, my - 19, '#597562');
  }
  const victims = t.victims || (t.foundBy && t.fix
    ? [{ id: 1, x: t.fix[0], y: t.fix[1], responders: t.responders,
         respondersWanted: t.respondersWanted }] : []);
  for (const v of victims) drawFoundPerson(v, victims.length > 1);
}

function drawFoundPerson(v, numbered) {
  const [cx, cy] = view.toPx(v.x, v.y);
  for (const [pid, arrived] of Object.entries(v.responders || {})) {
    const p = phones.get(pid);
    if (!p?.pose) continue;
    const [px, py] = view.toPx(p.pose.x, p.pose.y);
    ctx.strokeStyle = arrived ? '#173726' : '#18834b';
    ctx.lineWidth = 1.5;
    ctx.setLineDash(arrived ? [] : [4, 4]);
    ctx.beginPath(); ctx.moveTo(px, py); ctx.lineTo(cx, cy); ctx.stroke();
    ctx.setLineDash([]);
  }
  const k = (performance.now() / 1100) % 1;
  ctx.strokeStyle = `rgba(183,47,54,${.7 * (1 - k)})`;
  ctx.lineWidth = 2;
  ctx.beginPath(); ctx.arc(cx, cy, MAP_MARKER_RADIUS + MAP_MARKER_STROKE + 1 + k * 24, 0, Math.PI * 2); ctx.stroke();
  drawPersonGlyph(cx, cy, '#b72f36');
  const label = teamFull(v) ? 'RESCUED' : 'FOUND PERSON';
  drawMapLabel(numbered ? `${label} ${v.id}` : label, cx, personLabelY(cy), '#b72f36');
}

// drag a candidate
function roomPoint(e) {
  const r = canvas.getBoundingClientRect();
  const [x, y] = view.toRoom(e.clientX - r.left, e.clientY - r.top);
  return { x: Math.max(-room.width / 2, Math.min(room.width / 2, x)), y: Math.max(0, Math.min(room.depth, y)) };
}
function nearCandidate(e) {
  if (!view) return null;
  const r = canvas.getBoundingClientRect();
  let best = null, bestD = 14;
  for (const c of hiddenCandidates()) {
    const [cx, cy] = view.toPx(c.x, c.y);
    const d = Math.hypot(cx - (e.clientX - r.left), cy - (e.clientY - r.top));
    if (d <= bestD) { best = c; bestD = d; }
  }
  return best;
}

function sendCandidate(pos) {
  if (pos.id != null) { send({ type: 'target', id: pos.id, x: pos.x, y: pos.y }); return; }
  // An id-less `target` message *places* a candidate (swarm/target.py, `Target.place`),
  // so against a hub that numbers its candidates a drag without one strews a fresh
  // candidate across the floor every 80 ms. Only an older hub — no `candidates` in its
  // snapshot, one target, no ids — reads this as moving the one it has.
  if (st?.target && !st.target.candidates) send({ type: 'target', x: pos.x, y: pos.y });
}
canvas.addEventListener('mousedown', (e) => {
  if (e.altKey && view) { send({ type: 'ping', ...roomPoint(e) }); return; } // alt-click pings too
  const grabbed = nearCandidate(e);
  if (grabbed) { dragPos = { id: grabbed.id, ...roomPoint(e) }; e.preventDefault(); return; }
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
  canvas.style.cursor = dragPos ? 'grabbing'
    : nearCandidate(e) ? 'grab'
    : phoneAt(e) ? 'pointer' : 'default';
});
window.addEventListener('mousemove', (e) => {
  if (!dragPos) return;
  dragPos = { id: dragPos.id, ...roomPoint(e) };
  const now = performance.now();
  if (now - lastDragSend > 80) { lastDragSend = now; sendCandidate(dragPos); }
});
window.addEventListener('mouseup', () => {
  if (!dragPos) return;
  sendCandidate(dragPos);
  dragPos = null;
});

// The clock in the top bar is the *search* clock, not the phase clock: it sits
// at 00:00 through lobby and calibrate, starts when the search does, keeps
// running across search → found, and freezes on how long the search took.
// The hub only timestamps the phase it is in, so the console holds the start.
let searchClock = { start: null, stop: null };

setInterval(() => {
  if (!st) return;
  const on = running();
  if (on && searchClock.start == null) searchClock = { start: st.phaseStartedAt, stop: null };
  else if (!on && searchClock.start != null) {
    // Back in the lobby or recalibrating is a fresh session; 'end' keeps the
    // finishing time on screen.
    if (st.phase === 'lobby' || st.phase === IDLE_PHASE) searchClock = { start: null, stop: null };
    else searchClock.stop ??= Date.now();
  }
  const ms = searchClock.start == null ? 0 : (searchClock.stop ?? Date.now()) - searchClock.start;
  $('#timer').textContent = fmtClock(ms);
}, 250);

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

// The hub's own words for these are true but terse, and they arrive at the
// moment an operator has just typed a name and picked a photo.
function explainSearchError(message) {
  if (/inference disabled/i.test(message)) return 'Inference is off, so no photo can be matched. Start the inference worker, then add them again.';
  if (/inference unavailable|inference request failed/i.test(message)) return 'The inference worker did not answer. Check that it is still running, then add them again.';
  return message;
}

function renderSearch() {
  $('#searchTools').disabled = searchBusy;
  $('#saveThreshold').disabled = searchBusy;
  $('#threshold').disabled = searchBusy;
  const search = st?.search;
  $('#clearReference').hidden = !drawReference && !search?.referenceAvailable;
  // Adding somebody needs the matcher: without it the photo step 503s after the
  // operator has already typed a name, so the button says so before they start.
  const matcher = !st || search?.enabled !== false;
  $('#addPerson').disabled = searchBusy || !matcher;
  $('#inferenceNote').hidden = matcher;
  if (search && document.activeElement !== $('#threshold')) $('#threshold').value = search.threshold.toFixed(2);
}

async function searchAction(action) {
  if (searchBusy) return;
  searchBusy = true;
  renderSearch();
  // A failure leaves the add-person sheet open on purpose: nobody was added,
  // and closing it would look exactly like success.
  try { await action(); } catch (error) { searchNote(explainSearchError(error.message), true); }
  finally { searchBusy = false; renderSearch(); }
}

// The add-person sheet has its own status line; when it is open that is where
// the operator is looking, so both carry the same sentence.
function searchNote(text, bad = false) {
  $('#searchMessage').textContent = text;
  $('#searchMessage').classList.toggle('err', bad);
  $('#personMessage').textContent = $('#personDialog').open ? text : '';
  $('#personMessage').classList.toggle('err', bad);
}

function clearReferencePreview() {
  drawReference = null;
  $('#referencePreview').hidden = true;
  $('#personChoices').replaceChildren();
  $('#personName').value = '';
  $('#personNote').value = '';
  $('#referenceFile').value = '';
}

// Everybody the search is looking for, one row per uploaded photo.
function renderPeople(people = []) {
  const key = JSON.stringify(people);
  if (key === listMemo.people) return;
  listMemo.people = key;
  $('#peopleRoster').innerHTML = people.map((person) =>
    `<div class="person-row"><span class="who">${escapeHtml(person.label)}</span>`
    + (person.note ? `<span class="note">${escapeHtml(person.note)}</span>` : '')
    + `<span class="spacer"></span>`
    + `<button type="button" data-person="${escapeHtml(person.id)}">Remove</button></div>`).join('');
  pushLookingFor(people);
  $('#peopleCount').textContent = people.length ? `${people.length} being searched for` : '';
}

$('#peopleRoster').addEventListener('click', (event) => {
  const id = event.target.closest('[data-person]')?.dataset.person;
  if (!id) return;
  searchAction(async () => {
    await searchApi(`/api/search/reference/${encodeURIComponent(id)}`, {method: 'DELETE'});
    if (st?.search) st.search.sightings = [];
    clearSourceFrames();
    searchNote('Removed from the people to find.');
  });
});

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
    searchNote(`Threshold set to ${threshold.toFixed(2)}`);
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
// One person at a time: the sheet asks for the name, takes one photo, and then
// asks which person in it to search for. A queue of photos was faster to drop
// and impossible to name.
$('#addPerson').addEventListener('click', () => {
  clearReferencePreview();
  searchNote('');
  $('#personDialog').showModal();
  $('#personName').focus();
});
$('#personCancel').addEventListener('click', () => $('#personDialog').close());
$('#personDialog').addEventListener('close', () => clearReferencePreview());

$('#uploadPhoto').addEventListener('click', () => $('#referenceFile').click());
$('#referenceFile').addEventListener('change', () => {
  takePhoto($('#referenceFile').files);
  $('#referenceFile').value = '';
});

function takePhoto(files) {
  const photo = [...files].find((f) => !f.type || f.type.startsWith('image/'));
  if (!photo) { searchNote('Choose an image file.'); return; }
  uploadReferencePhoto(photo);
}
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
  takePhoto(event.dataTransfer.files);
});

function uploadReferencePhoto(file) {
  if (!file || searchBusy) return;
  searchAction(async () => {
    drawReference = null;
    $('#personChoices').replaceChildren();
    $('#referencePreview').hidden = true;
    searchNote('Finding people in the photo…');
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
    searchNote(result.detections.length
      ? 'Which one are we looking for?'
      : 'No people detected. Try another photo.');
    result.detections.forEach((person, index) => {
      const button = document.createElement('button');
      button.className = 'btn'; button.textContent = `Person ${index + 1}`;
      button.addEventListener('click', () => searchAction(async () => {
        // The first photo starts the roster (and a fresh search); the rest add to it, so every
        // frame gets matched against all of them.
        const roster = st?.search?.people || [];
        // Whatever the operator typed, or a number. The label rides through to
        // the searchers' phones, which is why it is worth asking for.
        const named = $('#personName').value.trim();
        const params = new URLSearchParams({box: person.box.join(','),
                                            label: named || `Person ${roster.length + 1}`,
                                            note: $('#personNote').value.trim()});
        if (roster.length) params.set('add', '1');
        await searchApi(`/api/search/reference?${params}`, {method: 'PUT', headers: {'Content-Type': 'image/jpeg'}, body: blob});
        if (st?.search) st.search.sightings = [];
        clearSourceFrames();
        selected = index;
        drawReference();
        $('#personDialog').close();
        searchNote(`${named || `Person ${roster.length + 1}`} added to the people to find.`);
      }));
      $('#personChoices').append(button);
    });
  });
}

function clearSourceFrames() {
  for (const frame of sourceFrames.values()) URL.revokeObjectURL(frame.url);
  sourceFrames.clear();
}
new ResizeObserver(() => drawReference?.()).observe($('#referencePreview'));
renderSearch();

$('#scanToggle').addEventListener('click', () => {
  send({ type: 'scan', enabled: !st?.scan?.enabled });
  if (!st?.scan?.enabled) setMapMode('3d');
});
$('#scanRebuild').addEventListener('click', () => send({ type: 'scan', action: 'rebuild' }));
$('#scanReset').addEventListener('click', () => send({ type: 'scan', action: 'reset' }));
