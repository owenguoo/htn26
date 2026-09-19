export function frameKey(frame) {
  return JSON.stringify([frame.phoneId, frame.streamId, frame.seq, frame.searchRevision]);
}

export function freshSighting(result, search, serverNow, receivedAt, now) {
  return !!search?.active && result.searchRevision === search.searchRevision &&
    serverNow - result.t + Math.max(0, now - receivedAt) < 1500;
}

export function acceptDetection(state, msg, now) {
  if (msg.clear) {
    state.revision = msg.searchRevision;
    state.seq = -1;
    return null;
  }
  if (msg.streamId !== state.streamId || msg.seq <= state.seq ||
      (state.revision !== null && msg.searchRevision !== state.revision)) return null;
  const captured = state.captures.get(msg.seq);
  if (captured === undefined || now - captured >= 1500) return null;
  state.revision = msg.searchRevision;
  state.seq = msg.seq;
  return {...msg, until: Math.min(captured + 1500, now + (msg.ttlMs ?? 1500))};
}

export function scoreLabel(box) {
  return `Similarity ${box.similarity.toFixed(2)} · confidence ${(box.detectionScore * 100).toFixed(0)}%`;
}
