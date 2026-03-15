// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenPlaudit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "OpenPlaudit", targets: ["OpenPlaudit"]),
        .library(name: "SharedKit", targets: ["SharedKit"]),
        .library(name: "NetworkKit", targets: ["NetworkKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
        .package(url: "https://github.com/exPHAT/SwiftWhisper.git", revision: "c340197966ebd264f3135d3955874b40f8ed58bc"),
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

        // --- Cross-platform libraries (macOS + iOS) ---
        .target(
            name: "SharedKit",
            path: "Sources/SharedKit"
        ),
        .target(
            name: "NetworkKit",
            dependencies: ["SharedKit"],
            path: "Sources/NetworkKit"
        ),

        // --- macOS libraries ---
        .target(
            name: "BLEKit",
            path: "Sources/BLEKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AudioKit",
            dependencies: ["COpus"],
            path: "Sources/AudioKit",
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"]),
            ]
        ),
        .target(
            name: "SyncEngine",
            dependencies: ["BLEKit", "AudioKit", "TOMLKit", "SharedKit", "NetworkKit", "TranscriptionKit", "DiarizationKit", "SummarisationKit", "MindMapKit"],
            path: "Sources/SyncEngine",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "TranscriptionKit",
            dependencies: ["SharedKit", "SwiftWhisper"],
            path: "Sources/TranscriptionKit"
        ),
        .target(
            name: "MeetingKit",
            dependencies: ["SyncEngine", "TranscriptionKit", "DiarizationKit", "SummarisationKit", "MindMapKit"],
            path: "Sources/MeetingKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ImportKit",
            dependencies: ["AudioKit", "SyncEngine", "TranscriptionKit", "DiarizationKit", "SummarisationKit", "MindMapKit"],
            path: "Sources/ImportKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DiarizationKit",
            dependencies: ["SharedKit"],
            path: "Sources/DiarizationKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "SummarisationKit",
            dependencies: ["SharedKit"],
            path: "Sources/SummarisationKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MindMapKit",
            dependencies: ["SummarisationKit"],
            path: "Sources/MindMapKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // --- App ---
        .executableTarget(
            name: "OpenPlaudit",
            dependencies: ["BLEKit", "AudioKit", "SyncEngine", "SharedKit", "NetworkKit", "TranscriptionKit", "MeetingKit", "ImportKit", "DiarizationKit", "SummarisationKit", "MindMapKit"],
            path: "Sources/OpenPlaudit",
            exclude: ["Resources/Info.plist", "Resources/OpenPlaudit.entitlements"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // --- Tests ---
        .testTarget(
            name: "SharedKitTests",
            dependencies: ["SharedKit", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/SharedKitTests"
        ),
        .testTarget(
            name: "NetworkKitTests",
            dependencies: ["NetworkKit", "SharedKit", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/NetworkKitTests"
        ),
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
            dependencies: ["SyncEngine", "BLEKit", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/SyncEngineTests"
        ),
        .testTarget(
            name: "MeetingKitTests",
            dependencies: ["MeetingKit", "SyncEngine", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/MeetingKitTests"
        ),
        .testTarget(
            name: "ImportKitTests",
            dependencies: ["ImportKit", "SyncEngine", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/ImportKitTests"
        ),
        .testTarget(
            name: "DiarizationKitTests",
            dependencies: ["DiarizationKit", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/DiarizationKitTests"
        ),
        .testTarget(
            name: "SummarisationKitTests",
            dependencies: ["SummarisationKit", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/SummarisationKitTests"
        ),
        .testTarget(
            name: "MindMapKitTests",
            dependencies: ["MindMapKit", .product(name: "Testing", package: "swift-testing")],
            path: "Tests/MindMapKitTests"
        ),
    ]
)
