import type { StyleProp, ViewStyle } from 'react-native';

export type PoseSource = 'arkit' | 'replay';

export type ConfigureOptions = {
  poseSource?: PoseSource;
  /** Bundled replay fixture, without extension. */
  fixture?: string;
  replayRate?: number;
  /** Replay only: false strips marker sightings, to exercise the seat fallback. */
  replayMarkers?: boolean;
};

/**
 * The appearance the operator chose. `'system'` follows the device.
 *
 * Stored natively in `UserDefaults` under `SwarmSightTheme`, **defaulting to
 * `'dark'`** — so the app is dark out of the box even though `app.json` is
 * `"userInterfaceStyle": "automatic"`. It has to be native: only setting
 * `overrideUserInterfaceStyle` on the windows moves `UITraitCollection`, which
 * is what SwiftUI, `PlatformColor` and `OperatorView` all read. RN's
 * `Appearance.setColorScheme` sets a JS-side string and nothing else.
 */
export type ThemePreference = 'system' | 'light' | 'dark';

export type StoredConfig = {
  phoneId: string;
  name: string;
  lastHubURL: string;
  /** From venue.json: the day-of authority for where the hub is. */
  venueHubURL: string;
  poseSource: PoseSource;
  /** Test hook: a join link passed as a launch argument. Empty in normal use. */
  launchJoin: string;
  theme: ThemePreference;
};

export type Alignment = 'none' | 'seat' | 'marker';

export type Diagnostics =
  | { joined: false }
  | {
      joined: true;
      connection: 'offline' | 'connecting' | 'online' | 'reconnecting';
      sessionState: string;
      trackingState: string;
      confidence: number;
      alignment: Alignment;
      phoneId: string;
      name: string;
      index?: number;
      color?: string;
      phase?: string;
      roomPose?: { x: number; y: number; heading?: number; pitch: number };
      seat?: { x: number; y: number };
      frameFPS: number;
      framesSent: number;
      dropped: number;
      reconnects: number;
      latencyP50Ms?: number;
      thermal: 'nominal' | 'fair' | 'serious' | 'critical';
      lastCommand?: string;
      lastError?: string;
    };

export type WelcomePayload = { phoneId: string; index: number; color: string; phase: string };

export type SwarmSightModuleEvents = {
  /** At most 2 Hz. For a settings screen, not a render loop. */
  onState: (state: Diagnostics) => void;
  onWelcome: (welcome: WelcomePayload) => void;
  onPhase: (event: { phase: string }) => void;
  onError: (event: { message: string }) => void;
};

export type OperatorViewProps = {
  showDebug?: boolean;
  showMiniMap?: boolean;
  onRequestLeave?: () => void;
  /** The gear beside the leave button in the native chrome. */
  onRequestSettings?: () => void;
  style?: StyleProp<ViewStyle>;
};
