/**
 * Pin the SF Symbol set to the deployment target.
 *
 * `app.json` → `expo-build-properties.ios.deploymentTarget` is `"17.0"`, which
 * ships SF Symbols 5.0. Without this, `SFSymbol` accepts names from SF Symbols
 * 7 and a phone on iOS 17 draws a blank square at runtime. With it,
 * `pnpm typecheck` rejects the name instead.
 */
declare module 'sf-symbols-typescript' {
  interface Overrides {
    SFSymbolsVersion: '5.0';
  }
}

export {};
