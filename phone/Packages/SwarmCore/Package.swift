// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwarmCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SwarmCore", targets: ["SwarmCore"])
    ],
    targets: [
        .target(
            name: "SwarmCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SwarmCoreTests",
            dependencies: ["SwarmCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
