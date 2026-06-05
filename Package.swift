// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Canopy",
            path: "Sources/Canopy",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
