import SwarmSight from '../modules/swarm-sight';
import type { PoseSource } from '../modules/swarm-sight/src/SwarmSight.types';

export type JoinLink = {
  hub: string;
  replay: boolean;
  drive: boolean;
  markers: boolean;
  seat: { x: number; y: number } | null;
};

/**
 * The pose sources this screen can ask for.
 *
 * `'drive'` is missing from `PoseSource` in
 * `modules/swarm-sight/src/SwarmSight.types.ts`, which is not this agent's file —
 * the request is in `HANDOFF-D2.md`. Until the union grows, the widening is
 * declared once, here, rather than cast at each call site: one place to delete.
 */
export type RequestedPoseSource = PoseSource | 'drive';

/**
 * A stored source, widened to what the runtime can actually report.
 *
 * A plain annotated `const` would not do: TypeScript narrows a `const` to its
 * initialiser, so comparing the result to `'drive'` is rejected as an overlap
 * that cannot happen. A function's declared return type is not narrowed.
 */
export function requestedPoseSource(source: PoseSource): RequestedPoseSource {
  return source;
}

/**
 * Which source an auto-joining link asks for.
 *
 * `drive` wins when both flags are set: it is the one a person types by hand,
 * and `replay=1` is what the scripts pass. The single `as` is the whole of the
 * widening described above — delete it, not a scatter of casts, when
 * `PoseSource` gains `'drive'`.
 */
export function poseSourceFor(link: JoinLink): PoseSource {
  return (link.drive ? 'drive' : 'replay') as PoseSource;
}

/**
 * `swarmsight://join?hub=…` from the dashboard QR, or the bare page URL the QR
 * encodes.
 *
 * Two test hooks join without a tap. `&drive=1` is the interactive one: no
 * ARKit, a room you drag to look around and a stick to walk with, which is what
 * makes the Simulator worth judging the UI on. `&replay=1` is the recorded walk
 * and **means exactly what it always did** — every `-SwarmSightJoin` recipe and
 * every e2e script that passes it keeps working unchanged.
 *
 * `&markers=0` strips sightings to exercise the seat fallback (both sources
 * honour it), and `&seat=x,y` then taps that spot and calibrates facing the
 * stage.
 *
 * Whether the text is a hub at all is SwarmCore's call, not ours.
 */
export function parseJoinLink(text: string): JoinLink | null {
  if (!text || SwarmSight.resolveHubURL(text) === null) return null;
  const query = text.includes('?') ? text.slice(text.indexOf('?') + 1) : '';
  const params = new Map(
    query.split('&').map((pair) => {
      const [key, value = ''] = pair.split('=');
      return [key, decodeURIComponent(value)] as const;
    })
  );
  const isDeepLink = text.trim().toLowerCase().startsWith('swarmsight:');
  return {
    hub: isDeepLink ? (params.get('hub') ?? text) : text,
    replay: params.get('replay') === '1',
    drive: params.get('drive') === '1',
    markers: params.get('markers') !== '0',
    seat: parseSeat(params.get('seat')),
  };
}

function parseSeat(text: string | undefined) {
  const [x, y] = (text ?? '').split(',').map(Number);
  return Number.isFinite(x) && Number.isFinite(y) && text ? { x, y } : null;
}
