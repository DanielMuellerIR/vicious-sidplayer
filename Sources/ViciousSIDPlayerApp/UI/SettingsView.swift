import SwiftUI
import ViciousSIDPlayerCore
#if canImport(AppKit)
import AppKit
#endif

// Einstellungen-Fenster (App-Menue -> "Einstellungen…", Cmd+,).
// Optionen: das Erscheinungsbild (Auto/Hell/Dunkel) und der Autoplay-Ordner,
// aus dem die App beim Start ihre Playlist baut (rekursiv, inkl. Unterordner).
// Beide Werte landen via @AppStorage in UserDefaults — MainView beobachtet
// dieselben Keys und reagiert auf Aenderungen sofort.
struct SettingsView: View {
    // "" = nicht gesetzt -> Standard-Ordner ~/Music/Vicious SID Player/
    @AppStorage("autoplayFolderPath") private var autoplayFolderPath = ""
    // Erscheinungsbild-Modus; "auto" (Default) folgt dem System-Dark/Light-Modus.
    @AppStorage(ThemeMode.userDefaultsKey) private var themeModeRaw = ThemeMode.auto.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Erscheinungsbild")
                .font(.headline)
            Picker("", selection: $themeModeRaw) {
                Text("Automatisch").tag(ThemeMode.auto.rawValue)
                Text("Hell").tag(ThemeMode.light.rawValue)
                Text("Dunkel").tag(ThemeMode.dark.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Automatisch folgt dem Hell/Dunkel-Modus von macOS. Cmd+T im Player schaltet fest auf Hell bzw. Dunkel um.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
                .padding(.vertical, 4)

            Text("Autoplay-Ordner")
                .font(.headline)
            Text("Aus diesem Ordner (inkl. Unterordner) baut die App beim Start ihre Playlist. Ohne eigene Auswahl wird ~/\(AutoplayFolder.defaultRelativePath)/ verwendet.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(displayPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(displayPath)
                Spacer()
                Button("Auswählen…", action: chooseFolder)
                    .help("Eigenen Autoplay-Ordner festlegen")
                if !autoplayFolderPath.isEmpty {
                    Button("Standard", action: { autoplayFolderPath = "" })
                        .help("Zurück zum Standard-Ordner ~/\(AutoplayFolder.defaultRelativePath)/")
                }
            }

            // Warnhinweis, falls der konfigurierte Ordner (noch/nicht mehr) fehlt.
            if !autoplayFolderPath.isEmpty && !configuredFolderExists {
                Label("Ordner existiert nicht — es wird der Standard-Ordner verwendet.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // Anzeige-Pfad: konfigurierter Ordner oder der Standard (mit ~-Kurzform).
    private var displayPath: String {
        if autoplayFolderPath.isEmpty {
            return "~/\(AutoplayFolder.defaultRelativePath)/"
        }
        return (autoplayFolderPath as NSString).abbreviatingWithTildeInPath
    }

    private var configuredFolderExists: Bool {
        var isDir: ObjCBool = false
        let expanded = (autoplayFolderPath as NSString).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }

    // Ordner-Auswahl ueber das System-Panel; nur Verzeichnisse waehlbar.
    private func chooseFolder() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = "Ordner mit .sid-Dateien für die Start-Playlist wählen"
        if !autoplayFolderPath.isEmpty {
            let expanded = (autoplayFolderPath as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            autoplayFolderPath = url.path
        }
        #endif
    }
}
