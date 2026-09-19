import { useSyncExternalStore } from 'react';

import SwarmSight, { type ThemePreference } from '../modules/swarm-sight';

/**
 * The two view toggles are in memory: they only matter while the operator
 * screen is up, and a demo does not need them to survive a relaunch.
 *
 * `theme` is different. An appearance that resets on every launch is worse than
 * no choice at all, so it is stored where the native side already stores
 * everything else — `UserDefaults`, via `SwarmSight.getConfig()` /
 * `SwarmSight.setTheme()`. That also puts the write in the only place that can
 * actually move the appearance: `overrideUserInterfaceStyle` on the windows.
 * No storage package, per `phone/CLAUDE.md`'s no-third-party-dependencies rule.
 */
export type Preferences = { showDebug: boolean; showMiniMap: boolean; theme: ThemePreference };

let current: Preferences | null = null;

// Read lazily rather than at import time: the first read happens from a screen,
// by which point the native module is certainly up.
function snapshot(): Preferences {
  current ??= { showDebug: false, showMiniMap: true, theme: SwarmSight.getConfig().theme };
  return current;
}

const listeners = new Set<() => void>();

export function setPreference<K extends keyof Preferences>(key: K, value: Preferences[K]) {
  const next = { ...snapshot(), [key]: value };
  if (next.theme !== snapshot().theme) SwarmSight.setTheme(next.theme);
  current = next;
  listeners.forEach((listener) => listener());
}

export function usePreferences(): Preferences {
  return useSyncExternalStore((listener) => {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }, snapshot);
}
