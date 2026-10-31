// swift-tools-version: 6.0


import PackageDescription

let package = Package(
    name: "PlaudCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "PlaudCore", targets: ["PlaudCore"]),
    ],
    targets: [
        .target(
            name: "PlaudCore",
            path: ".",
            linkerSettings: [.linkedFramework("Security")]
        ),
    ]
)
