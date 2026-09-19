import { useSyncExternalStore } from 'react';

/** Two toggles, in memory. Not worth a storage dependency for a demo. */
type Preferences = { showDebug: boolean; showMiniMap: boolean };

let current: Preferences = { showDebug: false, showMiniMap: true };
const listeners = new Set<() => void>();

export function setPreference<K extends keyof Preferences>(key: K, value: Preferences[K]) {
  current = { ...current, [key]: value };
  listeners.forEach((listener) => listener());
}

export function usePreferences(): Preferences {
  return useSyncExternalStore(
    (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    () => current
  );
}
