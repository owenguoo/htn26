// CNG wipes ios/ on every prebuild, so anything that would otherwise be a click
// in Xcode has to live here:
//
//   - DEVELOPMENT_TEAM from BEACON_TEAM_ID
//   - UIScene life cycle (iOS 27 SDK asserts without it; Expo's shipped
//     prebuild-config still emits the old AppDelegate-owned window)
//
//   BEACON_TEAM_ID=ABCDE12345 pnpm expo prebuild -p ios --clean
const {
  withAppDelegate,
  withInfoPlist,
  withXcodeProject,
  IOSConfig,
} = require('expo/config-plugins');

const SCENE_DELEGATE = `internal import Expo

@objc(SceneDelegate)
class SceneDelegate: ExpoAppSceneDelegate {
  // Extension point for config plugins.
}
`;

const WINDOW_START_BLOCK =
  /#if os\(iOS\) \|\| os\(tvOS\)[\s\S]*?factory\.startReactNative\([\s\S]*?\)\s*#endif\n?/;

function withSceneManifest(config) {
  return withInfoPlist(config, (cfg) => {
    cfg.modResults.UIApplicationSceneManifest = {
      UIApplicationSupportsMultipleScenes: false,
      UISceneConfigurations: {
        UIWindowSceneSessionRoleApplication: [
          {
            UISceneConfigurationName: 'Default Configuration',
            // `@objc(SceneDelegate)` below exports this exact Objective-C
            // runtime name. A module-qualified value cannot be resolved by
            // UIKit and triggers its no-scene-lifecycle launch trap.
            UISceneDelegateClassName: 'SceneDelegate',
          },
        ],
      },
    };
    return cfg;
  });
}

function withSceneAppDelegate(config) {
  return withAppDelegate(config, (cfg) => {
    if (cfg.modResults.language !== 'swift') {
      throw new Error(
        'withBeacon: expected a Swift AppDelegate (Expo SDK 57+). UIScene adoption is Swift-only here.',
      );
    }

    let contents = cfg.modResults.contents;

    if (!contents.includes('ExpoReactNativeFactoryProvider')) {
      contents = contents.replace(
        'class AppDelegate: ExpoAppDelegate {',
        'class AppDelegate: ExpoAppDelegate, ExpoReactNativeFactoryProvider {',
      );
    }

    if (WINDOW_START_BLOCK.test(contents)) {
      contents = contents.replace(
        WINDOW_START_BLOCK,
        // SceneDelegate owns the window + startReactNative (iOS 27 UIScene).
        '',
      );
    }

    // Idempotent: if a later Expo template already moved startup to SceneDelegate,
    // leave a short comment only when we just stripped the block and none exists.
    if (
      !contents.includes('SceneDelegate') &&
      !contents.includes('scene-based life cycle')
    ) {
      contents = contents.replace(
        'reactNativeFactory = factory\n\n',
        'reactNativeFactory = factory\n\n    // Window + startReactNative live in SceneDelegate (UIScene life cycle).\n\n',
      );
    }

    cfg.modResults.contents = contents;
    return cfg;
  });
}

function withSceneDelegateFile(config) {
  return withXcodeProject(config, (cfg) => {
    const projectName = IOSConfig.XcodeUtils.getProjectName(
      cfg.modRequest.projectRoot,
    );
    cfg.modResults = IOSConfig.XcodeProjectFile.createBuildSourceFile({
      project: cfg.modResults,
      nativeProjectRoot: cfg.modRequest.platformProjectRoot,
      filePath: `${projectName}/SceneDelegate.swift`,
      fileContents: SCENE_DELEGATE,
      overwrite: true,
    });
    return cfg;
  });
}

function withSigningTeam(config) {
  return withXcodeProject(config, (cfg) => {
    const team = process.env.BEACON_TEAM_ID;
    if (!team) return cfg;
    const configurations = cfg.modResults.pbxXCBuildConfigurationSection();
    for (const key of Object.keys(configurations)) {
      const settings = configurations[key].buildSettings;
      if (settings && settings.PRODUCT_NAME) {
        settings.DEVELOPMENT_TEAM = team;
        settings.CODE_SIGN_STYLE = 'Automatic';
      }
    }
    return cfg;
  });
}

module.exports = function withBeacon(config) {
  config = withSceneManifest(config);
  config = withSceneAppDelegate(config);
  config = withSceneDelegateFile(config);
  config = withSigningTeam(config);
  return config;
};
