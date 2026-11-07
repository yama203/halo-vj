// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VJPlayer",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 自動アップデート（MIT ライセンス。https://sparkle-project.org）
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
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
            dependencies: ["ObjCSupport", "Syphon", "NDIShim", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/VJPlayer",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // .app の中の Contents/Frameworks（Sparkle）を探す
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
