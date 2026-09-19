export const REHEARSAL_SCENARIOS = Object.freeze([
  {id: 'ahead', label: 'Directly ahead', offset: 0, distance: 5},
  {id: 'left', label: 'To the left', offset: -90, distance: 5},
  {id: 'right', label: 'To the right', offset: 90, distance: 5},
  {id: 'behind', label: 'Directly behind', offset: 180, distance: 5},
  {id: 'diagonal', label: 'Front-right diagonal', offset: 45, distance: 7},
  {id: 'nearby', label: 'Nearby', offset: 0, distance: 1.5},
]);

export function rehearsalAnchor(phones) {
  return [...phones]
    .filter(phone => phone.connected && phone.pose && Number.isFinite(phone.pose.heading))
    .sort((a, b) => a.index - b.index)[0] ?? null;
}

export function rehearsalPosition(room, phone, scenarioId) {
  const scenario = REHEARSAL_SCENARIOS.find(item => item.id === scenarioId);
  if (!scenario || !room || !phone?.pose || !Number.isFinite(phone.pose.heading)) return null;

  const angle = (phone.pose.heading + scenario.offset) * Math.PI / 180;
  const dx = Math.sin(angle);
  const dy = -Math.cos(angle);
  const margin = 0.35;
  const limits = [];
  const minX = -room.width / 2 + margin;
  const maxX = room.width / 2 - margin;
  const minY = margin;
  const maxY = room.depth - margin;

  if (dx > 0) limits.push((maxX - phone.pose.x) / dx);
  if (dx < 0) limits.push((minX - phone.pose.x) / dx);
  if (dy > 0) limits.push((maxY - phone.pose.y) / dy);
  if (dy < 0) limits.push((minY - phone.pose.y) / dy);

  const available = Math.max(0, ...limits.filter(value => Number.isFinite(value) && value >= 0));
  const distance = Math.min(scenario.distance, available);
  if (distance < 0.5) return null;

  return {
    x: Number((phone.pose.x + dx * distance).toFixed(2)),
    y: Number((phone.pose.y + dy * distance).toFixed(2)),
    distance: Number(distance.toFixed(1)),
    scenario,
  };
}
