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
        // Headless-Crash-Checker (siehe Tools/sidcheck/main.swift) — findet harte
        // Traps in der Emulation, ohne die GUI zu starten.
        .executableTarget(
            name: "sidcheck",
            dependencies: ["ViciousSIDPlayerCore"],
            path: "Tools/sidcheck"
        ),
        // Quick-Look-Preview-Extension: spielt .sid-Dateien direkt im Finder-
        // Quick-Look (Leertaste) ab. App-Extensions starten nicht ueber main(),
        // sondern ueber NSExtensionMain aus Foundation — deshalb das Linker-Flag
        // "-e _NSExtensionMain". build_app.sh verpackt das Binary als
        // "Contents/PlugIns/ViciousSIDQuickLook.appex" ins App-Bundle.
        .executableTarget(
            name: "ViciousSIDQuickLook",
            dependencies: ["ViciousSIDPlayerCore"],
            path: "Sources/ViciousSIDQuickLook",
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
            ]
        ),
        .testTarget(
            name: "ViciousSIDPlayerTests",
            dependencies: ["ViciousSIDPlayerCore"],
            path: "Tests/ViciousSIDPlayerTests"
        )
    ]
)
