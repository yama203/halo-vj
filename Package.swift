// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VJPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VJPlayer",
            path: "Sources/VJPlayer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
