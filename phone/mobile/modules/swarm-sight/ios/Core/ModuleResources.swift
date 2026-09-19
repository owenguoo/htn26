import Foundation
import SwarmCore

/// Where the marker PNGs and `venue.json` are, whichever shell this code is
/// running in: the pod's resource bundle inside the Expo app, `Bundle.main` in a
/// plain Xcode target.
public enum ModuleResources {
    private final class Token {}

    public static let bundle: Bundle = {
        let host = Bundle(for: Token.self)
        for candidate in [host, .main] {
            if let url = candidate.url(forResource: "SwarmSightResources", withExtension: "bundle"),
               let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return host.url(forResource: "venue", withExtension: "json") != nil ? host : .main
    }()

    /// Loads `venue.json`, preferring a copy dropped into the app's Documents
    /// directory over the bundled one.
    ///
    /// This is what "changing venue must require zero code changes and no
    /// rebuild" means in practice: on the day, someone tape-measures the
    /// markers, edits the numbers, and AirDrops the file onto the phones.
    /// `UIFileSharingEnabled` in Info.plist is what makes that possible.
    public static func loadVenue() throws -> Venue {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let override = documents?.appendingPathComponent("venue.json"),
           FileManager.default.fileExists(atPath: override.path) {
            return try Venue.load(from: override)
        }
        guard let url = bundle.url(forResource: "venue", withExtension: "json") else {
            throw ResourceError.missingVenueFile
        }
        return try Venue.load(from: url)
    }

    public static func fixtureURL(named name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension
        return bundle.url(forResource: base, withExtension: "json")
    }

    public enum ResourceError: Error, LocalizedError {
        case missingVenueFile
        case missingFixture(String)

        public var errorDescription: String? {
            switch self {
            case .missingVenueFile:
                "venue.json is not in the bundle. It is loaded at runtime, never compiled in."
            case .missingFixture(let name):
                "Replay fixture \(name) is not in the bundle."
            }
        }
    }
}

/// Identity that must survive a reinstall-free lifetime: the hub keys a phone's
/// index and colour on `phoneId`, and `identifierForVendor` changes when the app
/// is reinstalled — mid-rehearsal, that is a phone that comes back as a stranger.
public enum PhoneIdentity {
    private static let idKey = "swarmsight.phoneId"
    private static let nameKey = "swarmsight.name"
    private static let hubKey = "swarmsight.lastHubURL"

    public static var phoneId: String {
        if let existing = UserDefaults.standard.string(forKey: idKey) { return existing }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: idKey)
        return fresh
    }

    public static var name: String {
        get { UserDefaults.standard.string(forKey: nameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: nameKey) }
    }

    public static var lastHubURL: String {
        get { UserDefaults.standard.string(forKey: hubKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hubKey) }
    }
}
