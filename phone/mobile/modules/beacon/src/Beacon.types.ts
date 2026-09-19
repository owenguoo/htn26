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

export type StoredConfig = {
  phoneId: string;
  name: string;
  lastHubURL: string;
  /** From venue.json: the day-of authority for where the hub is. */
  venueHubURL: string;
  poseSource: PoseSource;
  /** Test hook: a join link passed as a launch argument. Empty in normal use. */
  launchJoin: string;
};

export type Alignment = 'none' | 'seat' | 'marker';

/**
 * What the microphone control shows, mirroring `.mic` / `.mic.off` / `.mic.live`
 * in `web/phone.html`.
 *
 * - `unavailable` — voice is off for this session (replay), or the operator
 *   declined the microphone prompt. The control is struck through and inert.
 * - `muted` — the operator turned it off. Nothing is captured at all.
 * - `idle` — listening, gate closed. Nothing is leaving the phone.
 * - `speaking` — the loudness gate is open and PCM is on the wire.
 *
 * JS never sees an audio sample. This string and a mute boolean are the entire
 * voice surface on this side of the bridge; the capture, the gate and the
 * framing are native, in `MicrophoneCapture.swift` and SwarmCore's `VoiceGate`.
 */
export type MicState = 'unavailable' | 'muted' | 'idle' | 'speaking';

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
      micState: MicState;
    };

export type WelcomePayload = { phoneId: string; index: number; color: string; phase: string };

export type BeaconModuleEvents = {
  /** At most 2 Hz. For a settings screen, not a render loop. */
  onState: (state: Diagnostics) => void;
  onWelcome: (welcome: WelcomePayload) => void;
  onPhase: (event: { phase: string }) => void;
  onError: (event: { message: string }) => void;
};

export type OperatorViewProps = {
  showDebug?: boolean;
  showMiniMap?: boolean;
  /** The gear in the native chrome. Leave lives in Settings. */
  onRequestSettings?: () => void;
  style?: StyleProp<ViewStyle>;
};
