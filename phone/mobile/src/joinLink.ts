import SwarmSight from '../modules/swarm-sight';

export type JoinLink = { hub: string; replay: boolean; markers: boolean };

/**
 * `swarmsight://join?hub=…` from the dashboard QR, or the bare page URL the QR
 * encodes. `&replay=1` is the test hook (a recorded walk instead of ARKit, and
 * join without a tap); `&markers=0` strips sightings to exercise the seat fallback.
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
    markers: params.get('markers') !== '0',
  };
}
