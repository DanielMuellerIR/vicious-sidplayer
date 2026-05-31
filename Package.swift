// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViciousSIDPlayer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ViciousSIDPlayerApp", targets: ["ViciousSIDPlayerApp"]),
        .library(name: "ViciousSIDPlayerCore", targets: ["ViciousSIDPlayerCore"])
    ],
    targets: [
        .target(
            name: "ViciousSIDPlayerCore",
            dependencies: [],
            path: "Sources/ViciousSIDPlayerCore"
        ),
        .executableTarget(
            name: "ViciousSIDPlayerApp",
            dependencies: ["ViciousSIDPlayerCore"],
            path: "Sources/ViciousSIDPlayerApp"
        ),
        .testTarget(
            name: "ViciousSIDPlayerTests",
            dependencies: ["ViciousSIDPlayerCore"],
            path: "Tests/ViciousSIDPlayerTests"
        )
    ]
)
