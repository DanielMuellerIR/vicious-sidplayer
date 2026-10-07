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
//     nicht gehoeren. Deshalb wird der gesamte Auftrag zuerst komponentenweise
//     geprueft und vor dem Commit ausschliesslich ruecknehmbar verschoben.
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

    public enum ResetError: LocalizedError, Sendable, Equatable {
        /// Es wurde versucht, etwas ausserhalb der Wurzel zu loeschen.
        /// Das ist immer ein Programmierfehler, nie eine Nutzeraktion.
        case outsideRoot(String)
        case overlappingRoots
        case rollbackFailed([String])

        public var errorDescription: String? {
            switch self {
            case .outsideRoot(let name): return "Eintrag liegt außerhalb der Bibliothek: \(name)"
            case .overlappingRoots: return "Musik- und Support-Ordner dürfen sich nicht überschneiden."
            case .rollbackFailed(let paths):
                return "Dateien konnten nicht an ihren ursprünglichen Ort zurückgelegt werden. Erhalten unter: " + paths.joined(separator: ", ")
            }
        }
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
        /// Nach dem erfolgreichen Zustandswechsel noch nicht freigegebener Speicher.
        public let retainedCleanupDirectories: [URL]

        public var isEmpty: Bool {
            removedFiles == 0 && removedTopLevelItems == 0 && removedSupportFiles.isEmpty
        }

        public init(removedFiles: Int,
                    removedTopLevelItems: Int,
                    removedSupportFiles: [String],
                    favoritesCleared: Bool,
                    retainedCleanupDirectories: [URL] = []) {
            self.removedFiles = removedFiles
            self.removedTopLevelItems = removedTopLevelItems
            self.removedSupportFiles = removedSupportFiles
            self.favoritesCleared = favoritesCleared
            self.retainedCleanupDirectories = retainedCleanupDirectories
        }
    }

    /// Entfernt Bibliotheksinhalt, Index und berechnete Songlaengen transaktional.
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
    /// - Throws: Pfad-, Auflistungs- oder Verschiebefehler vor dem Commit. Bereits
    ///   verschobene Dateien werden zurueckgelegt. Verhindert ein weiterer
    ///   Dateisystemfehler die Ruecknahme, nennt `rollbackFailed` die erhaltenen
    ///   Wiederherstellungsorte. Eine fehlende Wurzel wird leer neu angelegt.
    /// - Returns: Der erfolgreich entfernte Zustand. Fehler beim anschliessenden
    ///   Freigeben des Speichers stehen in `retainedCleanupDirectories`; sie
    ///   duerfen dem Nutzer nicht als fehlgeschlagener Reset gemeldet werden.
    @discardableResult
    public static func run(library: MusicLibrary,
                           clearFavorites: (() -> Void)? = nil) throws -> Report {
        let fm = library.fileManager
        let root = library.root

        let support = library.supportDirectory
        guard LibraryPath.normalizedComponents(root) != LibraryPath.normalizedComponents(support),
              !isContained(support, in: root), !isContained(root, in: support) else {
            throw ResetError.overlappingRoots
        }
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: root,
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [])
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            contents = []
        }
        let supportFiles = ([library.indexFileName] + cacheFileNames).map {
            support.appendingPathComponent($0)
        }.filter { fm.fileExists(atPath: $0.path) }

        // Erst den GESAMTEN Auftrag pruefen. Insbesondere darf ein spaeterer
        // Symlinkfehler nicht bereits geloeschte, fruehere Eintraege hinterlassen.
        for (items, parent) in [(contents, root), (supportFiles, support)] {
            for item in items where !isContained(item, in: parent) {
                throw ResetError.outsideRoot(item.lastPathComponent)
            }
        }
        let removedFiles = contents.reduce(0) { $0 + countFiles(under: $1, fm: fm) }
        try LibraryDirectory.ensure(root, fm: fm)

        // Ein Verzeichnis je Dateisystem: Verschieben bleibt dadurch ein Rename
        // statt eines moeglicherweise nur teilweise gelungenen Kopiervorgangs.
        let token = ".vicious-reset-" + UUID().uuidString
        let musicStage = root.appendingPathComponent(token, isDirectory: true)
        let supportStage = support.appendingPathComponent(token, isDirectory: true)
        var stages: [URL] = []
        var moved: [(original: URL, staged: URL)] = []
        do {
            for (items, stage) in [(contents, musicStage), (supportFiles, supportStage)] where !items.isEmpty {
                try fm.createDirectory(at: stage, withIntermediateDirectories: false)
                stages.append(stage)
                for (index, item) in items.enumerated() {
                    let destination = stage.appendingPathComponent(String(index))
                    try fm.moveItem(at: item, to: destination)
                    moved.append((item, destination))
                }
            }
        } catch {
            let originalError = error
            var unrestored: [String] = []
            for item in moved.reversed() {
                do { try fm.moveItem(at: item.staged, to: item.original) }
                catch { unrestored.append(item.staged.path) }
            }
            // Fehlgeschlagene Ruecknahmen niemals wegraeumen: Dort liegt die
            // erhaltene Datei; der Fehler nennt ihren Wiederherstellungsort.
            if !unrestored.isEmpty { throw ResetError.rollbackFailed(unrestored) }
            for stage in stages { try? fm.removeItem(at: stage) }
            throw originalError
        }

        // Commit-Grenze: Erst jetzt ist der ganze Bibliothekszustand erfolgreich
        // entfernt. Vorher bleiben Index, Favoriten und die UI unveraendert.
        library.clearIndex()
        clearFavorites?()

        // Das Freigeben des Speichers ist nach dem Commit kein fehlgeschlagener
        // Reset mehr. Bleibt eine Sicherheitskopie uebrig, meldet der Bericht
        // das ausdruecklich; sie wird niemals als Musik neu indiziert.
        var retained: [URL] = []
        for stage in stages {
            do { try fm.removeItem(at: stage) }
            catch { retained.append(stage) }
        }
        return Report(removedFiles: removedFiles,
                      removedTopLevelItems: contents.count,
                      removedSupportFiles: supportFiles.map(\.lastPathComponent),
                      favoritesCleared: clearFavorites != nil,
                      retainedCleanupDirectories: retained)
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
