// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SharedKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SharedKit", targets: ["SharedKit"]),
    ],
    targets: [
        .target(name: "SharedKit", path: "."),
    ]
)
