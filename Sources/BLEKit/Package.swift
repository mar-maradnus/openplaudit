// swift-tools-version: 6.0


import PackageDescription

let package = Package(
    name: "BLEKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BLEKit", targets: ["BLEKit"]),
    ],
    dependencies: [
        .package(path: "../PlaudCore"),
    ],
    targets: [
        .target(
            name: "BLEKit",
            dependencies: [.product(name: "PlaudCore", package: "PlaudCore")],
            path: ".",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
