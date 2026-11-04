// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VJPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        // Objective-C の例外をつかまえるための小さな補助
        .target(name: "ObjCSupport", path: "Sources/ObjCSupport"),
        .executableTarget(
            name: "VJPlayer",
            dependencies: ["ObjCSupport"],
            path: "Sources/VJPlayer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
