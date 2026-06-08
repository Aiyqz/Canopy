// swift-tools-version: 5.10
import PackageDescription

// Canopy builds in the Swift 5 language mode (matching the Xcode project's
// SWIFT_VERSION = 5.0). Tools 5.10 is the floor — newer toolchains (Swift 6+)
// read this manifest fine, so it builds on stock CI runners and locally alike.
let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Canopy",
            path: "Sources/Canopy"
        )
    ]
)
