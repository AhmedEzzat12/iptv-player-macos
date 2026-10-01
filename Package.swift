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
            dependencies: ["TunerCore", "CMPV"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("OpenGL"),
                .linkedFramework("AVKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("MediaPlayer"),
            ]
        ),

        .testTarget(
            name: "TunerCoreTests",
            dependencies: ["TunerCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
