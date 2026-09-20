import Foundation
import Testing
@testable import SwarmCore

/// CLAUDE.md's architectural rules, enforced rather than described.
///
/// Every one of these is a rule somebody will break at 3am while tired and
/// convinced it is fine just this once. A comment does not stop that; a failing
/// test does.
@Suite("Architecture")
struct ArchitectureTests {

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SwarmCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SwarmCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
    }

    /// The native shell: the Expo module (where the code lives) and what is
    /// left of the plain-Swift app target (its entry point, until it is retired).
    private static let shellRoots = ["mobile/modules/beacon/ios", "Beacon"]

    private func shellFiles() -> [(url: URL, source: String)] {
        Self.shellRoots.flatMap { swiftFiles(under: $0) }
    }

    private func swiftFiles(under relativePath: String) -> [(url: URL, source: String)] {
        let root = repositoryRoot.appendingPathComponent(relativePath)
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var results: [(URL, String)] = []
        for case let name as String in enumerator where name.hasSuffix(".swift") {
            let url = root.appendingPathComponent(name)
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                results.append((url, source))
            }
        }
        return results
    }

    /// Lines that are actual code, not comments. Every rule below is about what
    /// the compiler sees, and a rule that fires on prose is a rule people learn
    /// to work around.
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        var inBlockComment = false
        var result: [(Int, String)] = []
        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            var line = String(raw)
            if inBlockComment {
                guard let end = line.range(of: "*/") else { continue }
                inBlockComment = false
                line = String(line[end.upperBound...])
            }
            if let start = line.range(of: "/*") {
                inBlockComment = line.range(of: "*/", range: start.upperBound..<line.endIndex) == nil
                line = String(line[..<start.lowerBound])
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            if let comment = line.range(of: "//") {
                line = String(line[..<comment.lowerBound])
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.append((index + 1, line))
        }
        return result
    }

    /// SwarmCore must build and test with `swift test` on macOS with no
    /// simulator and no device. One of these imports and it cannot.
    @Test(arguments: ["ARKit", "UIKit", "SwiftUI", "CoreMotion", "CoreHaptics",
                      "RealityKit", "AVFoundation", "CoreImage"])
    func swarmCoreDoesNotImport(framework: String) {
        for (url, source) in swiftFiles(under: "Packages/SwarmCore/Sources") {
            for line in codeLines(source) where line.text.contains("import \(framework)") {
                Issue.record(Comment(rawValue:
                    "\(url.lastPathComponent):\(line.number) imports \(framework). If SwarmCore "
                    + "needs this, the abstraction is wrong — widen the protocol instead."))
            }
        }
    }

    /// "ARKit appears in exactly one file: ARKitPoseProvider.swift in the app
    /// target."
    @Test func arkitAppearsInExactlyOneFile() {
        // Shipping code only. This very file mentions "import ARKit" in a string
        // literal, which is code as far as the scanner is concerned — and the
        // first run of this test caught itself, which is at least a working
        // demonstration that the scan is not vacuous.
        let importers = (shellFiles() + swiftFiles(under: "Packages/SwarmCore/Sources"))
            .filter { _, source in
                codeLines(source).contains { $0.text.contains("import ARKit") }
            }
            .map { $0.url.lastPathComponent }
            .sorted()
        #expect(importers == ["ARKitPoseProvider.swift"],
                "ARKit is imported by \(importers.isEmpty ? ["nothing"] : importers)")
    }

    /// "No force unwraps outside tests."
    @Test func noForceUnwrapsOutsideTests() {
        // `!` as a prefix (negation), `!=`, and `try!`/`as!` inside tests are all
        // fine; a postfix `!` on an expression in shipping code is not.
        let pattern = try! NSRegularExpression(
            pattern: #"[A-Za-z0-9_\)\]]\!(?![=\w])"#)
        var offences: [String] = []
        for path in ["Packages/SwarmCore/Sources"] + Self.shellRoots {
            for (url, source) in swiftFiles(under: path) {
                for line in codeLines(source) {
                    let range = NSRange(line.text.startIndex..., in: line.text)
                    guard pattern.firstMatch(in: line.text, range: range) != nil else { continue }
                    let text = line.text.trimmingCharacters(in: .whitespaces)
                    offences.append("\(url.lastPathComponent):\(line.number): \(text)")
                }
            }
        }
        #expect(offences.isEmpty, "force unwraps in shipping code:\n\(offences.joined(separator: "\n"))")
    }

    /// `worldAlignment = .gravityAndHeading` pulls in the magnetometer, which is
    /// off by tens of degrees indoors. Gravity fixes pitch and roll; the marker
    /// fixes yaw.
    @Test func neverUsesGravityAndHeading() {
        for (url, source) in shellFiles() {
            for line in codeLines(source) where line.text.contains("gravityAndHeading") {
                Issue.record("\(url.lastPathComponent):\(line.number) uses .gravityAndHeading")
            }
        }
    }

    /// "Anything ARKit-dependent goes in a file with a `// DEVICE-VERIFY:`
    /// comment stating exactly what a human must check on hardware."
    @Test func everyDeviceDependentFileSaysWhatAHumanMustCheck() {
        let deviceDependent = ["ARKitPoseProvider.swift", "FrameEncoder.swift",
                               "LiDARDepthSource.swift", "Haptics.swift"]
        for (url, source) in shellFiles()
        where deviceDependent.contains(url.lastPathComponent) {
            let name = url.lastPathComponent
            #expect(source.contains("DEVICE-VERIFY:"),
                    "\(name) cannot be tested here and does not say what to check on hardware")
            #expect(source.contains("DEVICE_CHECKLIST.md"), "\(name) does not point at the checklist")
        }
    }

    @Test func theDeviceChecklistExists() throws {
        let url = repositoryRoot.appendingPathComponent("DEVICE_CHECKLIST.md")
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.count > 2_000, "the checklist is too short to be a real one")
        for topic in ["local-network", "Marker detection range", "Re-lock", "Drift",
                      "Thermal", "Backgrounding", "latency", "synthetic"] {
            #expect(contents.localizedCaseInsensitiveContains(topic),
                    "DEVICE_CHECKLIST.md does not cover \(topic)")
        }
    }

    /// Every marker the venue names must have artwork, or the app throws on a
    /// real device the first time it tries to build its reference images — and
    /// never calibrates, which looks like tracking being broken rather than a
    /// missing file.
    @Test func everyVenueMarkerHasArtwork() throws {
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        let directory = repositoryRoot.appendingPathComponent("mobile/modules/beacon/ios/Resources/Markers")
        for marker in venue.markers {
            let url = directory.appendingPathComponent("\(marker.id).png")
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "no artwork for \(marker.id): expected mobile/modules/beacon/ios/Resources/Markers/\(marker.id).png")
        }
    }

    /// A marker wider than A4 cannot be printed at true size on an office
    /// printer, and a marker printed "to fit" has a declared width that is a
    /// lie — which scales every distance in the venue by that ratio.
    @Test func everyMarkerPrintsOnA4AtTrueSize() throws {
        let venue = try Venue.load(from: Fixtures.url("venue.json"))
        // A4 is 210 mm wide; 20 mm of margin covers any printer's unprintable
        // edge.
        let printable: Float = 0.190
        for marker in venue.markers {
            #expect(marker.physicalWidth <= printable,
                    "\(marker.id) is \(marker.physicalWidth * 1000) mm, too wide to print on A4")
        }
    }

    /// The 4.6 GB checkpoint must never be committable. GitHub rejects files over
    /// 100 MB, a multi-gigabyte blob makes every clone painful even via LFS, and
    /// the FAIR Noncommercial Research License makes redistribution a licensing
    /// question as well as a git one.
    @Test func weightsAreGitignored() throws {
        let url = repositoryRoot.appendingPathComponent(".gitignore")
        let contents = try String(contentsOf: url, encoding: .utf8)
        for pattern in ["*.pt", "*.safetensors", "checkpoints/"] {
            #expect(contents.contains(pattern), ".gitignore does not exclude \(pattern)")
        }
    }

    // MARK: - The Expo shell

    /// JS never touches frames, poses at rate, or the socket. The moment a
    /// `WebSocket` appears in the React layer there are two clients, and only
    /// one of them is tested.
    @Test func javascriptNeverOpensASocket() throws {
        let mobile = repositoryRoot.appendingPathComponent("mobile")
        guard FileManager.default.fileExists(atPath: mobile.path) else { return }
        var offenders: [String] = []
        for directory in ["app", "src", "modules/beacon/src", "modules/beacon/index.ts", "App.tsx"] {
            let root = mobile.appendingPathComponent(directory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            let files: [URL] = isDirectory.boolValue
                ? (FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? [])
                    .filter { $0.hasSuffix(".ts") || $0.hasSuffix(".tsx") || $0.hasSuffix(".js") }
                    .map { root.appendingPathComponent($0) }
                : [root]
            for file in files {
                let source = try String(contentsOf: file, encoding: .utf8)
                for needle in ["WebSocket", "/ws/phone"] where source.contains(needle) {
                    offenders.append("\(file.lastPathComponent): \(needle)")
                }
            }
        }
        #expect(offenders.isEmpty, "the socket belongs to SwarmCore: \(offenders)")
    }

    /// pnpm only, and CNG: `ios/` is regenerated by prebuild, never committed.
    @Test func theExpoAppIsPnpmOnlyAndItsNativeProjectsAreIgnored() throws {
        let mobile = repositoryRoot.appendingPathComponent("mobile")
        guard FileManager.default.fileExists(atPath: mobile.path) else { return }
        for lockfile in ["package-lock.json", "yarn.lock", "bun.lockb"] {
            #expect(!FileManager.default.fileExists(atPath: mobile.appendingPathComponent(lockfile).path),
                    "\(lockfile) found: this repo is pnpm only")
        }
        let ignore = try String(contentsOf: mobile.appendingPathComponent(".gitignore"), encoding: .utf8)
        let lines = Set(ignore.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        #expect(lines.contains("node_modules/"))
        #expect(lines.contains("/ios"))
        #expect(lines.contains("/android"))
    }

    /// UIKit resolves the scene delegate through the Objective-C runtime name.
    /// `@objc(SceneDelegate)` deliberately removes the Swift module prefix, so
    /// the generated plist must ask for `SceneDelegate`, not
    /// `$(PRODUCT_MODULE_NAME).SceneDelegate` (which traps during launch).
    @Test func expoSceneManifestNamesTheActualObjectiveCClass() throws {
        let plugin = repositoryRoot.appendingPathComponent("mobile/plugins/withBeacon.js")
        let source = try String(contentsOf: plugin, encoding: .utf8)
        #expect(source.contains("@objc(SceneDelegate)"))
        #expect(source.contains("UISceneDelegateClassName: 'SceneDelegate'"))
    }
}
