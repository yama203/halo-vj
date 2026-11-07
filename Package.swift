// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VJPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        // Objective-C の例外をつかまえるための小さな補助
        .target(name: "ObjCSupport", path: "Sources/ObjCSupport"),
        // Syphon（ほかのアプリと映像をやりとりする。BSD ライセンス。https://github.com/Syphon/Syphon-Framework から取り込み）
        .target(
            name: "Syphon",
            path: "Sources/Syphon",
            exclude: ["LICENSE-Syphon.txt"],
            cSettings: [
                .headerSearchPath("include/Syphon"),
                .define("SYPHON_CORE_SHARE"),
                .define("GL_SILENCE_DEPRECATION"),
                .unsafeFlags(["-fobjc-arc", "-Wno-deprecated-declarations"]),
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"), .linkedFramework("OpenGL"), .linkedFramework("IOSurface"),
                .linkedFramework("Metal"), .linkedFramework("QuartzCore"),
            ]
        ),
        // NDI（ネットワークで映像をやりとりする）。NDI ランタイムを実行時に読み込む
        .target(name: "NDIShim", path: "Sources/NDIShim"),
        .executableTarget(
            name: "VJPlayer",
            dependencies: ["ObjCSupport", "Syphon", "NDIShim"],
            path: "Sources/VJPlayer",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
