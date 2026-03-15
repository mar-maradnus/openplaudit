// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NetworkKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NetworkKit", targets: ["NetworkKit"]),
    ],
    dependencies: [
        .package(path: "../SharedKit"),
    ],
    targets: [
        .target(name: "NetworkKit", dependencies: ["SharedKit"], path: "."),
    ]
)
