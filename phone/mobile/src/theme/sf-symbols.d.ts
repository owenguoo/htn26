/**
 * Pin the SF Symbol set to the deployment target.
 *
 * `app.json` → `ios.deploymentTarget` is `"26.0"`, which ships SF Symbols 7.
 * Keeping the type package on the same release means `pnpm typecheck` rejects
 * names that are newer than the app's actual minimum OS.
 */
declare module 'sf-symbols-typescript' {
  interface Overrides {
    SFSymbolsVersion: '7.0';
  }
}

export {};
