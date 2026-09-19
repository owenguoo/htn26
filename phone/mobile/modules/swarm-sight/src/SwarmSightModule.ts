import { NativeModule, requireNativeModule } from 'expo';

import type {
  ConfigureOptions,
  Diagnostics,
  StoredConfig,
  SwarmSightModuleEvents,
} from './SwarmSight.types';

declare class SwarmSightModule extends NativeModule<SwarmSightModuleEvents> {
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
  getDiagnostics(): Promise<Diagnostics>;
}

export default requireNativeModule<SwarmSightModule>('SwarmSight');
