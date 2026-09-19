import { NativeModule, requireNativeModule } from 'expo';

declare class SwarmSightModule extends NativeModule {
  resolveHubURL(scanned: string): string | null;
}

export default requireNativeModule<SwarmSightModule>('SwarmSight');
