import Foundation

// "Bibliothek zuruecksetzen" — alles wegwerfen und neu vom Mac holen.
//
// Klingt banal, ist es nicht. Drei Fallstricke, die dieser Code abfaengt:
//
//  1. AUF iOS IST DIE WURZEL `Documents/`. Dieses Verzeichnis gehoert dem
//     System, nicht uns. Geloescht wird deshalb ausschliesslich sein INHALT.
//     Waere `Documents/` selbst weg, funktionierte die Finder-Dateifreigabe
//     nicht mehr, und der naechste Import haette kein Ziel.
//  2. LOESCHEN IST UNUMKEHRBAR. Ein falsch berechneter Pfad — ein "..", ein
//     Symlink, eine leere Wurzel-URL — und der Reset raeumt Ordner ab, die ihm
//     nicht gehoeren. Deshalb geht JEDE Loeschung durch `remove(_:under:)`, das
//     vorher komponentenweise prueft, ob das Ziel wirklich unterhalb der
//     uebergebenen Wurzel liegt.
//  3. IDEMPOTENZ. Zweimal zuruecksetzen, oder auf einem schon leeren Zustand
//     zuruecksetzen, ist kein Fehler. Der Nutzer tippt in einem
//     Bestaetigungsdialog gerne zweimal.
public enum LibraryReset {

    /// Dateien im Support-Ordner, die zur berechneten Bibliothek gehoeren und
    /// mit weggeworfen werden.
    ///
    /// Der Name kommt aus `SongLengthCache`, damit er nicht an zwei Stellen
    /// gepflegt werden muss. Bleibt der Cache stehen, haette die frisch
    /// befuellte Bibliothek Laengen von Dateien, die es nicht mehr gibt — die
    /// HVSC-Datenbank und der Fallback bleiben davon unberuehrt.
    public static let cacheFileNames = [SongLengthCache.defaultCacheFileName]

    public enum ResetError: Error, Sendable, Equatable {
        /// Es wurde versucht, etwas ausserhalb der Wurzel zu loeschen.
        /// Das ist immer ein Programmierfehler, nie eine Nutzeraktion.
        case outsideRoot(String)
    }

    /// Was der Reset weggeraeumt hat.
    public struct Report: Sendable, Equatable {
        /// Geloeschte Musikdateien, rekursiv gezaehlt.
        public let removedFiles: Int
        /// Geloeschte Eintraege direkt in der Wurzel (Ordner zaehlen als einer).
        public let removedTopLevelItems: Int
        /// Namen der geloeschten Index-/Cache-Dateien im Support-Ordner.
        public let removedSupportFiles: [String]
        /// Wurden auch die Favoriten geleert?
        public let favoritesCleared: Bool

        public var isEmpty: Bool {
            removedFiles == 0 && removedTopLevelItems == 0 && removedSupportFiles.isEmpty
        }

        public init(removedFiles: Int,
                    removedTopLevelItems: Int,
                    removedSupportFiles: [String],
                    favoritesCleared: Bool) {
            self.removedFiles = removedFiles
            self.removedTopLevelItems = removedTopLevelItems
            self.removedSupportFiles = removedSupportFiles
            self.favoritesCleared = favoritesCleared
        }
    }

    /// Loescht Bibliotheksinhalt, Index und berechnete Songlaengen.
    ///
    /// - Parameters:
    ///   - library: die betroffene Bibliothek. Ihre Wurzel bleibt als leerer
    ///     Ordner bestehen, damit direkt danach wieder importiert werden kann.
    ///   - clearFavorites: Favoriten liegen NICHT im Core (auf beiden Plattformen
    ///     in den Benutzereinstellungen), deshalb reicht der Aufrufer hier eine
    ///     Aktion herein. `nil` heisst: Favoriten behalten. Beispiel aus der UI:
    ///
    ///         try LibraryReset.run(library: library,
    ///                              clearFavorites: wipeFavorites ? { store.removeAllFavorites() } : nil)
    ///
    /// - Throws: `ResetError.outsideRoot`, wenn die Pfadpruefung anschlaegt, oder
    ///   den Dateisystemfehler, wenn etwas Vorhandenes sich nicht loeschen laesst.
    @discardableResult
    public static func run(library: MusicLibrary,
                           clearFavorites: (() -> Void)? = nil) throws -> Report {
        let fm = library.fileManager
        let root = library.root

        // 1. Inhalt der Wurzel loeschen — die Wurzel selbst NICHT (siehe oben).
        //    Ohne `.skipsHiddenFiles`, damit auch `.DS_Store` und Konsorten gehen.
        var removedFiles = 0
        var removedTopLevelItems = 0
        let contents = (try? fm.contentsOfDirectory(at: root,
                                                    includingPropertiesForKeys: [.isRegularFileKey],
                                                    options: [])) ?? []
        for item in contents {
            removedFiles += countFiles(under: item, fm: fm)
            try remove(item, under: root, fm: fm)
            removedTopLevelItems += 1
        }

        // 2. Wurzel sicherstellen: sie kann vorher schon gefehlt haben, und ohne
        //    sie schlaegt der naechste Import fehl.
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        // 3. Index und Caches im Support-Ordner. Hier wird namentlich geloescht,
        //    nicht der ganze Ordner geleert: auf iOS ist "Application Support"
        //    der gesamte interne Bereich der App.
        var removedSupportFiles: [String] = []
        let supportNames = [MusicLibrary.indexFileName] + cacheFileNames
        for name in supportNames {
            let url = library.supportDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            try remove(url, under: library.supportDirectory, fm: fm)
            removedSupportFiles.append(name)
        }

        // 4. Index auch im Speicher leeren — sonst zeigt die UI weiter Eintraege
        //    an, deren Dateien es nicht mehr gibt.
        library.clearIndex()

        // 5. Favoriten nur, wenn der Aufrufer das ausdruecklich will.
        let favoritesCleared = clearFavorites != nil
        clearFavorites?()

        return Report(removedFiles: removedFiles,
                      removedTopLevelItems: removedTopLevelItems,
                      removedSupportFiles: removedSupportFiles,
                      favoritesCleared: favoritesCleared)
    }

    // MARK: - Sicherheitsnetz

    /// Liegt `url` echt unterhalb von `root`?
    ///
    /// "Echt" heisst: die Wurzel selbst ist NICHT enthalten — sie darf nie
    /// geloescht werden. Der Vergleich laeuft komponentenweise ueber
    /// normalisierte Pfade, damit weder "..", noch Symlinks, noch der
    /// Praefix-Zufall ("/tmp/lib" gegen "/tmp/lib2") durchrutschen.
    public static func isContained(_ url: URL, in root: URL) -> Bool {
        LibraryPath.isContained(url, in: root)
    }

    /// Loescht `url`, aber nur wenn es unterhalb von `root` liegt.
    ///
    /// Das ist die einzige Stelle im Reset, die tatsaechlich loescht. Wer hier
    /// vorbeigeht, umgeht das Sicherheitsnetz.
    public static func remove(_ url: URL, under root: URL, fm: FileManager = .default) throws {
        guard isContained(url, in: root) else {
            throw ResetError.outsideRoot(url.lastPathComponent)
        }
        do {
            try fm.removeItem(at: url)
        } catch let error as NSError {
            // Schon weg? Dann ist nichts zu tun — der Reset ist idempotent.
            if error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { return }
            throw error
        }
    }

    /// Zaehlt die Dateien unterhalb eines Eintrags (fuer den Bericht).
    /// Eine einzelne Datei zaehlt als 1, ein Ordner als die Summe seines Inhalts.
    private static func countFiles(under url: URL, fm: FileManager) -> Int {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return 1 }

        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: []) else {
            return 0
        }
        var count = 0
        for case let child as URL in enumerator {
            if (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }
}
