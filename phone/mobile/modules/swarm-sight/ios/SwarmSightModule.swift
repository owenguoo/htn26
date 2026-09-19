import ExpoModulesCore
import SwarmCore

public class SwarmSightModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SwarmSight")

    // QR / typed text / deep link → the hub's phone socket. All in SwarmCore.
    Function("resolveHubURL") { (scanned: String) -> String? in
      HubURL.derive(scanned)?.absoluteString
    }
  }
}
