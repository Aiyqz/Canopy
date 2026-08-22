// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v14)],
    targets: [
        // 可复用内核库：模型 / 视图 / 歌词解析 / 繁简转换等，全部 UI 无关或 SwiftUI 视图。
        // 抽成 library 是为了让测试 target 能依赖它（SwiftPM 不允许 test target 依赖 executable target）。
        .target(
            name: "CanopyKit",
            path: "Sources/CanopyKit",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // 极薄可执行壳：仅负责启动 NSApplication + 菜单栏/灵动岛，依赖 CanopyKit。
        .executableTarget(
            name: "Canopy",
            dependencies: ["CanopyKit"],
            path: "Sources/Canopy",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // 回归测试：锁定歌词索引在「循环重播 / 进度条回拖」下的卡死 bug，以及纯函数解析。
        .testTarget(
            name: "CanopyTests",
            dependencies: ["CanopyKit"],
            path: "Tests/CanopyTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
