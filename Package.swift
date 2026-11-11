// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Overbright",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Overbright", targets: ["Overbright"])
    ],
    targets: [
        .executableTarget(
            name: "Overbright",
            path: "Sources/Overbright"
        )
    ]
)
