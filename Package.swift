// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Puppy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Puppy",
            path: "Sources/Puppy",
            // v5 语言模式:FSEvents 的 C 回调、NSAppleScript 都不是 Sendable-friendly,
            // 严格并发检查在这里只会制造噪音。UI 代码仍然全部标注 @MainActor。
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
