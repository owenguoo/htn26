/* Rehearsal scenarios: where to hide the mock candidate so a drill looks like a real search.
 *
 * Two kinds of placement. A `relative` scenario sits at a bearing off the anchor phone's own
 * heading, which is how you rehearse the camera work — in frame, at the edge of frame, or behind
 * the operator so the swarm has to pick the candidate up instead. A `venue` scenario ignores the
 * anchor and drops the candidate on a landmark derived from room.json — the barrier, the sound
 * desk, a side exit, the back bar — because that is where people actually go missing, and those
 * spots stress coverage, range, and hand-off between phones. */

const VENUE_SPOTS = {
  barrier: room => ({x: -Math.min(room.stage?.width ?? 8, room.width) / 2 * 0.55, y: 1.1}),
  soundDesk: room => ({x: 0, y: room.depth * 0.7}),
  sideExit: room => ({x: room.width / 2 - 1.2, y: room.depth * 0.55}),
  backBar: room => ({x: -(room.width / 2 - 1.5), y: room.depth - 1.4}),
};

export const REHEARSAL_SCENARIOS = Object.freeze([
  {id: 'in-frame', group: 'One phone can see it', label: 'Centre of your shot, mid-crowd',
   detail: 'Six rows out, dead centre. The baseline drill: one clean look, one confident match.',
   kind: 'relative', offset: 0, distance: 6},
  {id: 'frame-edge', group: 'One phone can see it', label: 'Edge of your shot, off to one side',
   detail: 'Just inside the 55° cone and partly cropped — rehearses a match on a half-framed face.',
   kind: 'relative', offset: -24, distance: 4.5},
  {id: 'long-shot', group: 'One phone can see it', label: 'Far end of your row',
   detail: 'Past the drawn view cone, small in frame. Rehearses a low-confidence sighting at range.',
   kind: 'relative', offset: 8, distance: 11},

  {id: 'behind-you', group: 'Needs the swarm', label: 'Behind you, working toward the back',
   detail: 'Squarely out of your frame. Nothing happens until a phone facing the other way picks them up.',
   kind: 'relative', offset: 168, distance: 7},
  {id: 'across-floor', group: 'Needs the swarm', label: 'Across the floor, other side of the room',
   detail: 'Wide off your shoulder and far away — tests whether coverage actually spans the hall.',
   kind: 'relative', offset: -72, distance: 12},
  {id: 'right-beside', group: 'Needs the swarm', label: "Standing beside you, in nobody's shot",
   detail: 'Two metres away and still invisible: the blind spot right under the swarm’s nose.',
   kind: 'relative', offset: 96, distance: 2},

  {id: 'barrier', group: 'Venue landmarks', label: 'Crushed against the front barrier',
   detail: 'House left at the rail, where a lost kid or a fainter ends up. Bright, dense, backlit.',
   kind: 'venue', spot: 'barrier'},
  {id: 'sound-desk', group: 'Venue landmarks', label: 'Stalled by the sound desk',
   detail: 'Mid-floor at front of house — the spot most phones point past rather than at.',
   kind: 'venue', spot: 'soundDesk'},
  {id: 'side-exit', group: 'Venue landmarks', label: 'Making for the side exit',
   detail: 'Against the wall on the way out. The find that has to land before they leave the room.',
   kind: 'venue', spot: 'sideExit'},
  {id: 'back-bar', group: 'Venue landmarks', label: 'Back bar, far corner',
   detail: 'The darkest, furthest corner from the stage — worst light and worst angles in the hall.',
   kind: 'venue', spot: 'backBar'},
]);

export function rehearsalAnchor(phones) {
  return [...phones]
    .filter(phone => phone.connected && phone.pose && Number.isFinite(phone.pose.heading))
    .sort((a, b) => a.index - b.index)[0] ?? null;
}

const MARGIN = 0.35;

function clampToRoom(room, x, y) {
  return {
    x: Math.min(Math.max(x, -room.width / 2 + MARGIN), room.width / 2 - MARGIN),
    y: Math.min(Math.max(y, MARGIN), room.depth - MARGIN),
  };
}

export function rehearsalPosition(room, phone, scenarioId) {
  const scenario = REHEARSAL_SCENARIOS.find(item => item.id === scenarioId);
  if (!scenario || !room || !phone?.pose || !Number.isFinite(phone.pose.heading)) return null;

  const spot = scenario.kind === 'venue'
    ? venueSpot(room, scenario)
    : bearingSpot(room, phone, scenario);
  if (!spot) return null;

  const distance = Math.hypot(spot.x - phone.pose.x, spot.y - phone.pose.y);
  if (distance < 0.5) return null;

  return {
    x: Number(spot.x.toFixed(2)),
    y: Number(spot.y.toFixed(2)),
    distance: Number(distance.toFixed(1)),
    scenario,
  };
}

function venueSpot(room, scenario) {
  const place = VENUE_SPOTS[scenario.spot];
  if (!place) return null;
  const {x, y} = place(room);
  return clampToRoom(room, x, y);
}

/* Walk out along the bearing and stop at the first wall, so a long scenario in a small room
 * shortens instead of landing outside it. */
function bearingSpot(room, phone, scenario) {
  const angle = (phone.pose.heading + scenario.offset) * Math.PI / 180;
  const dx = Math.sin(angle);
  const dy = -Math.cos(angle);
  const minX = -room.width / 2 + MARGIN;
  const maxX = room.width / 2 - MARGIN;
  const minY = MARGIN;
  const maxY = room.depth - MARGIN;
  const limits = [];

  if (dx > 0) limits.push((maxX - phone.pose.x) / dx);
  if (dx < 0) limits.push((minX - phone.pose.x) / dx);
  if (dy > 0) limits.push((maxY - phone.pose.y) / dy);
  if (dy < 0) limits.push((minY - phone.pose.y) / dy);

  const reachable = limits.filter(value => Number.isFinite(value) && value >= 0);
  const available = reachable.length ? Math.min(...reachable) : 0;
  const distance = Math.min(scenario.distance, available);
  return {x: phone.pose.x + dx * distance, y: phone.pose.y + dy * distance};
}
