// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeStats",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeStats",
            path: "Sources/ClaudeStats",
            resources: [.copy("Resources/icon.png")]
        )
    ]
)
