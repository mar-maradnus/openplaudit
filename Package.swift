// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenPlaudit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenPlaudit", targets: ["OpenPlaudit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        // --- System library: libopus via Homebrew ---
        .systemLibrary(
            name: "COpus",
            path: "Sources/COpus",
            pkgConfig: "opus",
            providers: [.brew(["opus"])]
        ),

        // --- Libraries ---
        .target(
            name: "BLEKit",
            path: "Sources/BLEKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AudioKit",
            dependencies: ["COpus"],
            path: "Sources/AudioKit"
        ),
        .target(
            name: "SyncEngine",
            dependencies: ["BLEKit", "AudioKit", "TOMLKit"],
            path: "Sources/SyncEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TranscriptionKit",
            path: "Sources/TranscriptionKit"
        ),

        // --- App ---
        .executableTarget(
            name: "OpenPlaudit",
            dependencies: ["BLEKit", "AudioKit", "SyncEngine", "TranscriptionKit"],
            path: "Sources/OpenPlaudit",
            exclude: ["Resources/Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // --- Tests ---
        .testTarget(
            name: "BLEKitTests",
            dependencies: ["BLEKit", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/BLEKitTests"
        ),
        .testTarget(
            name: "AudioKitTests",
            dependencies: ["AudioKit", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/AudioKitTests"
        ),
        .testTarget(
            name: "SyncEngineTests",
            dependencies: ["SyncEngine", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/SyncEngineTests"
        ),
    ]
)
