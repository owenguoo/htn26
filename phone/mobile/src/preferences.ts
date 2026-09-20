import { useSyncExternalStore } from 'react';

/**
 * View toggles only. They matter while the operator screen is up, and a demo
 * does not need them to survive a relaunch. Appearance is not a preference —
 * the app is light always (`app.json` `userInterfaceStyle: "light"`).
 */
export type Preferences = { showDebug: boolean; showMiniMap: boolean };

let current: Preferences | null = null;

function snapshot(): Preferences {
  current ??= { showDebug: false, showMiniMap: true };
  return current;
}

const listeners = new Set<() => void>();

export function setPreference<K extends keyof Preferences>(key: K, value: Preferences[K]) {
  current = { ...snapshot(), [key]: value };
  listeners.forEach((listener) => listener());
}

export function usePreferences(): Preferences {
  return useSyncExternalStore((listener) => {
    listeners.add(listener);
    return () => listeners.delete(listener);
  }, snapshot);
}
