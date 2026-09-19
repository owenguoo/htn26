import { NativeModule, requireNativeModule } from 'expo';

import type {
  ConfigureOptions,
  Diagnostics,
  MicState,
  StoredConfig,
  BeaconModuleEvents,
} from './Beacon.types';

declare class BeaconModule extends NativeModule<BeaconModuleEvents> {
  configure(options: ConfigureOptions): void;
  getConfig(): StoredConfig;
  /** QR / typed text / deep link → the hub's phone socket URL, or null if it is not one. */
  resolveHubURL(scanned: string): string | null;
  join(hubURL: string, name: string): Promise<void>;
  leave(): Promise<void>;
  setName(name: string): Promise<void>;
  setSeat(x: number, y: number): Promise<void>;
  calibrateFacingStage(): Promise<boolean>;
  resetOrigin(): Promise<void>;
  /**
   * The mic control. Returns the state the control should now show, so a toggle
   * settles immediately rather than waiting for the next `onState`.
   *
   * Muting tells the gate first — it owes the hub an `audio_end` if the
   * operator cut themselves off mid-sentence — and then stops the input node
   * running, so muted means muted rather than captured-and-discarded.
   *
   * No audio ever crosses this bridge. This bool and {@link MicState} are the
   * whole of it.
   */
  setMicrophoneMuted(muted: boolean): Promise<MicState>;
  getDiagnostics(): Promise<Diagnostics>;
}

export default requireNativeModule<BeaconModule>('Beacon');
