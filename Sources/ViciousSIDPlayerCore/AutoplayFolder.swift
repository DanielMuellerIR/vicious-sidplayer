import Foundation

// Aufloesung des Autoplay-Ordners (Start-Playlist der App).
//
// Der Nutzer kann in den App-Einstellungen (Cmd+,) einen eigenen Ordner
// konfigurieren (UserDefaults-Key "autoplayFolderPath"). Ist keiner gesetzt
// oder existiert der konfigurierte Ordner nicht (mehr), faellt die App auf
// den Standard-Ordner ~/Music/Vicious SID Player/ zurueck.
//
// Liegt hier (Core) statt in der App, damit die Logik ohne GUI unit-testbar
// ist — gleiches Muster wie DropURLDecoder.
public enum AutoplayFolder {
    // Der klassische Standard-Ordner relativ zum Home-Verzeichnis.
    public static let defaultRelativePath = "Music/Vicious SID Player"

    // Liefert den zu ladenden Ordner oder nil, wenn keiner existiert.
    // - configuredPath: Wert aus den Einstellungen ("" = nicht gesetzt),
    //   "~" wird expandiert.
    // - home: Home-Verzeichnis (injizierbar fuer Tests).
    // - isDirectory: Existenz-Check (injizierbar fuer Tests).
    public static func resolve(
        configuredPath: String,
        home: URL,
        isDirectory: (URL) -> Bool
    ) -> URL? {
        var candidates: [URL] = []
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            candidates.append(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        candidates.append(home.appendingPathComponent(defaultRelativePath, isDirectory: true))
        return candidates.first(where: isDirectory)
    }

    // Bequemer Aufruf mit echtem FileManager (Produktions-Pfad der App).
    public static func resolve(configuredPath: String, fm: FileManager = .default) -> URL? {
        resolve(configuredPath: configuredPath, home: fm.homeDirectoryForCurrentUser) { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}
