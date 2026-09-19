// CNG wipes ios/ on every prebuild, so anything that would otherwise be a click
// in Xcode has to live here. Today that is just the signing team:
//
//   BEACON_TEAM_ID=ABCDE12345 pnpm expo prebuild -p ios --clean
const { withXcodeProject } = require('expo/config-plugins');

module.exports = function withBeacon(config) {
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
};
