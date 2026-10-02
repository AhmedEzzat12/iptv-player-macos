// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tuner",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Tuner", targets: ["Tuner"]),
        .library(name: "TunerCore", targets: ["TunerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Auto-updates (appcast + EdDSA-signed zips on GitHub Releases), as in Soonbar.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // libmpv client API, loaded at runtime via dlopen (no link-time dependency).
        .target(name: "CMPV"),

        // zlib (system library) for gzip-compressed playlists and guides, incl. multi-member files.
        .target(name: "CZlib", linkerSettings: [.linkedLibrary("z")]),

        // UI-free domain layer: models, playlist/EPG parsers, provider clients,
        // SQLite persistence and sync. Compiled in Swift 6 strict-concurrency mode.
        .target(
            name: "TunerCore",
            dependencies: ["CZlib", .product(name: "GRDB", package: "GRDB.swift")]
        ),

        // SwiftUI/AppKit application. Swift 5 mode keeps C-callback-heavy player
        // code (mpv render callbacks, CAOpenGLLayer) free of runtime isolation traps.
        .executableTarget(
            name: "Tuner",
            dependencies: ["TunerCore", "CMPV", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Sparkle.framework is embedded in Contents/Frameworks by scripts/build-app.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .linkedFramework("OpenGL"),
                .linkedFramework("AVKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("WebKit"),
            ]
        ),

        .testTarget(
            name: "TunerCoreTests",
            dependencies: ["TunerCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
