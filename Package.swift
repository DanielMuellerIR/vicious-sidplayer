// swift-tools-version: 6.0
import PackageDescription

// Plattform-Weiche fuer den Linux-Port.
//
// SwiftUI-App und Quick-Look-Extension brauchen AppKit/QuickLookUI — die gibt es
// auf Linux nicht. Wuerden sie im Paket stehen bleiben, scheiterten dort `swift
// build` UND `swift test`, weil SwiftPM immer das ganze Paket uebersetzt (auch
// wenn man nur die Tests will). Deshalb kommen sie unten per `#if os(macOS)`
// nur auf Apple-Rechnern ueberhaupt ins Paket.
//
// Das `#if` wird beim Auswerten dieser Datei ausgefuehrt, gilt also fuer den
// Rechner, der gerade baut. Ergebnis: auf beiden Plattformen genuegen die
// normalen Kommandos ohne Sonderflags:
//
//   swift build
//   swift test
//
// Die `platforms:`-Angabe setzt nur das macOS-Minimum und hat auf Linux keine
// Wirkung.

var products: [Product] = [
    // Plattformuebergreifendes CLI (macOS + Linux). Der Produktname ist zugleich
    // der Name des fertigen Binaries.
    .executable(name: "vicious-sid", targets: ["ViciousSIDPlayerCLI"]),
    .library(name: "ViciousSIDPlayerCore", targets: ["ViciousSIDPlayerCore"])
]

var targets: [Target] = [
        // ALSA-Systembibliothek (nur Linux; siehe Sources/CALSA/module.modulemap).
        // Braucht auf dem Build-Rechner das Paket libasound2-dev.
        .systemLibrary(
            name: "CALSA",
            path: "Sources/CALSA",
            pkgConfig: "alsa",
            providers: [
                .apt(["libasound2-dev"])
            ]
        ),
        // D-Bus-Systembibliothek (nur Linux; siehe Sources/CDBus/module.modulemap).
        // Fuer MPRIS2: Medientasten und Sound-Applet des Desktops. Braucht auf dem
        // Build-Rechner das Paket libdbus-1-dev.
        .systemLibrary(
            name: "CDBus",
            path: "Sources/CDBus",
            pkgConfig: "dbus-1",
            providers: [
                .apt(["libdbus-1-dev"])
            ]
        ),
        .target(
            name: "ViciousSIDPlayerCore",
            dependencies: [
                // Nur der Linux-Build zieht ALSA herein — auf macOS laeuft die
                // Ausgabe ueber AVAudioEngine und CALSA wird nie angefasst.
                .target(name: "CALSA", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/ViciousSIDPlayerCore"
        ),
        // Headless-CLI-Player: laeuft auf macOS UND Linux. Dadurch ist der
        // Linux-Ausgabepfad schon auf dem Mac entwickel- und testbar.
        .executableTarget(
            name: "ViciousSIDPlayerCLI",
            dependencies: [
                "ViciousSIDPlayerCore",
                // MPRIS2 gibt es nur auf Linux — auf macOS wird CDBus nie angefasst.
                .target(name: "CDBus", condition: .when(platforms: [.linux]))
            ],
            path: "Sources/ViciousSIDPlayerCLI"
        ),
        // Headless-Crash-Checker (siehe Tools/sidcheck/main.swift) — findet harte
        // Traps in der Emulation, ohne die GUI zu starten.
        .executableTarget(
            name: "sidcheck",
            dependencies: ["ViciousSIDPlayerCore"],
            path: "Tools/sidcheck"
        ),
        .testTarget(
            name: "ViciousSIDPlayerTests",
            dependencies: ["ViciousSIDPlayerCore"],
            path: "Tests/ViciousSIDPlayerTests"
        )
]

// Nur auf Apple-Rechnern: die SwiftUI-App und die Quick-Look-Extension.
// Auf Linux existieren diese Targets gar nicht erst — siehe Erklaerung oben.
#if os(macOS)
products.append(.executable(name: "ViciousSIDPlayerApp", targets: ["ViciousSIDPlayerApp"]))

targets.append(
    .executableTarget(
        name: "ViciousSIDPlayerApp",
        dependencies: ["ViciousSIDPlayerCore"],
        path: "Sources/ViciousSIDPlayerApp"
    )
)

// Quick-Look-Preview-Extension: spielt .sid-Dateien direkt im Finder-
// Quick-Look (Leertaste) ab. App-Extensions starten nicht ueber main(),
// sondern ueber NSExtensionMain aus Foundation — deshalb das Linker-Flag
// "-e _NSExtensionMain". build_app.sh verpackt das Binary als
// "Contents/PlugIns/ViciousSIDQuickLook.appex" ins App-Bundle.
targets.append(
    .executableTarget(
        name: "ViciousSIDQuickLook",
        dependencies: ["ViciousSIDPlayerCore"],
        path: "Sources/ViciousSIDQuickLook",
        linkerSettings: [
            .linkedFramework("QuickLookUI"),
            .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])
        ]
    )
)
#endif

let package = Package(
    name: "ViciousSIDPlayer",
    platforms: [
        .macOS(.v13)
    ],
    products: products,
    targets: targets
)
