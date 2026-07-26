import Foundation

// Der Bibliotheks-Index: welche SID-Dateien liegen unterhalb der Wurzel?
//
// WARUM RELATIVE PFADE ALS ID (das ist die wichtigste Entscheidung hier):
// Auf iOS bekommt der App-Container bei JEDER Neuinstallation eine neue UUID.
// Aus
//   /var/mobile/Containers/Data/Application/<UUID-A>/Documents/Tel_Jeroen/Cybernoid.sid
// wird nach dem naechsten Sideload
//   /var/mobile/Containers/Data/Application/<UUID-B>/Documents/Tel_Jeroen/Cybernoid.sid
// — dieselbe Datei, ein anderer absoluter Pfad. Wuerden Favoriten, Session-Restore
// oder der Index absolute URLs speichern, waeren sie nach jeder Neuinstallation
// wertlos. Deshalb ist die stabile ID eines Eintrags ausschliesslich sein Pfad
// RELATIV zur Bibliothekswurzel ("Tel_Jeroen/Cybernoid.sid"). Die absolute URL
// entsteht immer erst zur Laufzeit aus aktueller Wurzel + relativem Pfad.
//
// WARUM DER INDEX NIE DIE EINZIGE WAHRHEIT IST:
// Die Wurzel liegt auf iOS in `Documents/` und ist damit ueber die
// Finder-Dateifreigabe und die Dateien-App sichtbar. Der Nutzer kann dort
// jederzeit Ordner hineinziehen oder loeschen, ohne dass die App laeuft. Der
// Index ist deshalb nur eine schnelle Zwischenablage; `refresh()` gleicht ihn
// gegen das Dateisystem ab und meldet, was dazukam und was verschwand.

/// Ein Eintrag der Bibliothek — genau eine SID-Datei.
///
/// Bewusst OHNE Titel und Komponist: die stehen im Datei-Header und muessten
/// dafuer geparst werden. Bei mehreren tausend Dateien (HVSC hat >50.000) waere
/// das beim Scan viel zu teuer. Wer die Metadaten braucht, holt sie mit
/// `MusicLibrary.metadata(for:)` gezielt fuer einen Eintrag nach.
public struct MusicLibraryEntry: Codable, Hashable, Sendable, Identifiable {
    /// Pfad relativ zur Bibliothekswurzel, immer mit "/" getrennt und ohne
    /// fuehrenden Schraegstrich. Das ist die stabile ID (siehe oben).
    public let relativePath: String

    /// Anzeigename fuer Listen: Dateiname ohne Endung.
    public let displayName: String

    /// Dateigroesse in Bytes — zusammen mit dem Datum der billige Vergleich,
    /// ob sich eine Datei von aussen veraendert hat.
    public let fileSize: Int

    /// Aenderungsdatum der Datei.
    public let modificationDate: Date

    public var id: String { relativePath }

    public init(relativePath: String, displayName: String, fileSize: Int, modificationDate: Date) {
        self.relativePath = relativePath
        self.displayName = displayName
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }

    /// Die einzelnen Pfadbestandteile, z.B. ["Tel_Jeroen", "Cybernoid.sid"].
    public var pathComponents: [String] {
        relativePath.split(separator: "/").map(String.init)
    }

    /// Ordner, in dem die Datei liegt — relativ zur Wurzel.
    /// Leerer String heisst: direkt in der Wurzel.
    public var folderPath: String {
        pathComponents.dropLast().joined(separator: "/")
    }

    /// Dateiname mit Endung.
    public var fileName: String {
        pathComponents.last ?? relativePath
    }

    /// Absolute URL zur Laufzeit. Nie speichern — siehe Erklaerung oben.
    public func url(relativeTo root: URL) -> URL {
        var url = root
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return url
    }
}

/// Der auf Platte gespeicherte Index. Eigene Formatversion, damit ein spaeteres
/// Feld-Update den alten Index verwerfen kann, statt am Decoder zu scheitern.
public struct MusicLibraryIndex: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var entries: [MusicLibraryEntry]

    public init(formatVersion: Int = MusicLibrary.indexFormatVersion, entries: [MusicLibraryEntry] = []) {
        self.formatVersion = formatVersion
        self.entries = entries
    }
}

/// Ergebnis eines Abgleichs zwischen Index und Dateisystem.
public struct MusicLibraryChanges: Sendable, Equatable {
    /// Von aussen dazugekommen (Finder-Dateifreigabe, Dateien-App, Import).
    public let added: [MusicLibraryEntry]
    /// Von aussen geloescht — die Eintraege, wie sie im alten Index standen.
    public let removed: [MusicLibraryEntry]
    /// Gleicher relativer Pfad, aber andere Groesse oder anderes Datum.
    public let modified: [MusicLibraryEntry]

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && modified.isEmpty }

    public init(added: [MusicLibraryEntry] = [],
                removed: [MusicLibraryEntry] = [],
                modified: [MusicLibraryEntry] = []) {
        self.added = added
        self.removed = removed
        self.modified = modified
    }
}

/// Ein Knoten des Ordnerbaums — genau das, was die Bibliotheks-Ansicht zum
/// Auf- und Zuklappen braucht. Wird aus den Eintraegen berechnet, nicht
/// gespeichert; die Wahrheit bleiben die relativen Pfade.
public struct MusicLibraryFolder: Sendable, Hashable, Identifiable {
    /// Pfad relativ zur Wurzel; leerer String = die Wurzel selbst.
    public let path: String
    /// Nur der Ordnername. Bei der Wurzel leer — wie sie heisst, entscheidet die UI.
    public let name: String
    /// Unterordner, alphabetisch.
    public let subfolders: [MusicLibraryFolder]
    /// Dateien, die DIREKT in diesem Ordner liegen (nicht in Unterordnern).
    public let entries: [MusicLibraryEntry]

    public var id: String { path }

    /// Anzahl aller Dateien in diesem Ordner UND allen Unterordnern.
    public var totalEntryCount: Int {
        entries.count + subfolders.reduce(0) { $0 + $1.totalEntryCount }
    }

    public init(path: String,
                name: String,
                subfolders: [MusicLibraryFolder],
                entries: [MusicLibraryEntry]) {
        self.path = path
        self.name = name
        self.subfolders = subfolders
        self.entries = entries
    }
}

/// Die Musikbibliothek: Wurzelordner, rekursiver Scan, Index.
///
/// Alle Pfade sind injizierbar, damit Tests in einem temporaeren Verzeichnis
/// laufen koennen; `standard()` liefert die echten Orte aus `MusicLibraryLocation`.
///
/// Nebenlaeufigkeit: `@unchecked Sendable` mit einem `NSLock` um den Index —
/// dasselbe Muster wie beim `SongLengthCache`. Der Index darf aus Hintergrund-
/// Tasks (Import, Scan) und aus der UI gelesen werden.
public final class MusicLibrary: @unchecked Sendable {

    /// Dateiname des Index im Support-Ordner. Bewusst NICHT in der Wurzel: dort
    /// wuerde ihn der Nutzer in der Dateifreigabe zwischen seiner Musik sehen.
    public static let indexFileName = "library-index.json"

    /// Format des gespeicherten Index. Passt sie nicht, wird der Index verworfen.
    public static let indexFormatVersion = 1

    /// Wurzel der Bibliothek. Absolute URL — gilt nur fuer diesen Programmlauf.
    public let root: URL

    /// Ort fuer Index und Caches (nicht nutzersichtbar).
    public let supportDirectory: URL

    public let fileManager: FileManager

    private let lock = NSLock()
    private var storedIndex: MusicLibraryIndex

    /// - Parameters:
    ///   - root: Wurzelordner der Musikbibliothek.
    ///   - supportDirectory: Ort fuer Index und Caches.
    ///   - fileManager: fuer Tests austauschbar.
    ///
    /// Legt beide Verzeichnisse bei Bedarf an und laedt einen vorhandenen Index.
    public init(root: URL, supportDirectory: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.supportDirectory = supportDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.storedIndex = MusicLibraryIndex()
        ensureDirectories()
        loadIndex()
    }

    /// Die Bibliothek an ihrem echten Ort (iOS: `Documents/`, macOS:
    /// `~/Music/Vicious SID Player`). `nil`, wenn das System die Ordner nicht
    /// herausrueckt — dann ist etwas grundlegend kaputt und der Aufrufer muss
    /// eine Fehlermeldung zeigen, statt zu raten.
    public static func standard(fm: FileManager = .default) -> MusicLibrary? {
        guard let root = MusicLibraryLocation.root(fm: fm),
              let support = MusicLibraryLocation.support(fm: fm) else {
            return nil
        }
        return MusicLibrary(root: root, supportDirectory: support, fileManager: fm)
    }

    /// Ablageort des Index.
    public var indexFileURL: URL {
        supportDirectory.appendingPathComponent(MusicLibrary.indexFileName)
    }

    // MARK: - Zugriff auf den Index

    /// Alle Eintraege, nach relativem Pfad sortiert.
    public var entries: [MusicLibraryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storedIndex.entries
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedIndex.entries.count
    }

    public var isEmpty: Bool { count == 0 }

    /// Eintrag ueber seine stabile ID (den relativen Pfad).
    public func entry(withRelativePath path: String) -> MusicLibraryEntry? {
        lock.lock()
        defer { lock.unlock() }
        return storedIndex.entries.first { $0.relativePath == path }
    }

    /// Absolute URL eines Eintrags — erst zur Laufzeit gebildet.
    public func url(for entry: MusicLibraryEntry) -> URL {
        entry.url(relativeTo: root)
    }

    /// Absolute URL zu einem relativen Pfad.
    public func url(forRelativePath path: String) -> URL {
        var url = root
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    /// Leert den Index im Speicher. Die Index-DATEI wird davon nicht angefasst
    /// (das macht `LibraryReset`, der dabei die Pfadpruefung anwendet).
    public func clearIndex() {
        lock.lock()
        storedIndex = MusicLibraryIndex()
        lock.unlock()
    }

    // MARK: - Metadaten bei Bedarf

    /// Titel, Komponist und Subtune-Anzahl einer einzelnen Datei.
    ///
    /// Wird ABSICHTLICH nicht beim Scan gemacht: dafuer muss die Datei gelesen
    /// und der PSID-Header geparst werden. Einmal pro angezeigter Zeile ist das
    /// billig, einmal pro Datei beim Start waere es eine halbe Ewigkeit.
    public func metadata(for entry: MusicLibraryEntry) throws -> SidMetadata {
        let data = try Data(contentsOf: url(for: entry))
        return try SidParser.parse(data: data).metadata
    }

    /// Wie oben, aber ueber den relativen Pfad.
    public func metadata(forRelativePath path: String) throws -> SidMetadata {
        let data = try Data(contentsOf: url(forRelativePath: path))
        return try SidParser.parse(data: data).metadata
    }

    // MARK: - Scannen und Abgleichen

    /// Reine Dateisystem-Sicht: was liegt gerade unterhalb der Wurzel?
    /// Der Index wird dabei NICHT veraendert.
    ///
    /// Rekursiv ueber `FileManager.enumerator` mit `.skipsHiddenFiles` (versteckte
    /// Ordner werden gar nicht erst betreten), gefiltert ueber `SidFileType`.
    /// Reagiert auf Task-Abbruch, weil ein Scan ueber eine grosse Sammlung
    /// mehrere Sekunden dauern kann.
    public func scan() throws -> [MusicLibraryEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let rootComponents = LibraryPath.normalizedComponents(root)
        var result: [MusicLibraryEntry] = []
        var seen = 0

        for case let url as URL in enumerator {
            seen += 1
            // Nicht bei jeder Datei den Task-Status abfragen — alle 256 Eintraege
            // reicht voellig und kostet nichts.
            if seen.isMultiple(of: 256) { try Task.checkCancellation() }

            guard SidFileType.matches(url) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            guard let relative = LibraryPath.relativePath(of: url, underRootComponents: rootComponents) else {
                continue
            }

            result.append(MusicLibraryEntry(
                relativePath: relative,
                displayName: url.deletingPathExtension().lastPathComponent,
                fileSize: values?.fileSize ?? 0,
                // Ohne Datum (z.B. auf exotischen Dateisystemen) nehmen wir den
                // Beginn der Unix-Zeitrechnung: definiert und vergleichbar.
                modificationDate: values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            ))
        }

        try Task.checkCancellation()
        // Stabile, plattformunabhaengige Ordnung. Eine "natuerliche" Sortierung
        // (Track2 vor Track10) waere huebscher, ist aber sprachabhaengig und
        // damit nicht reproduzierbar — das darf die UI selbst machen.
        result.sort { $0.relativePath < $1.relativePath }
        return result
    }

    /// Gleicht den Index gegen das Dateisystem ab ("reconcile"), speichert ihn
    /// und meldet, was dazukam, verschwand oder sich geaendert hat.
    ///
    /// Das ist die Pflichtuebung fuer Import-Weg B (Finder-Dateifreigabe): dort
    /// legt der Nutzer Dateien ab, ohne dass die App etwas davon mitbekommt.
    @discardableResult
    public func refresh() throws -> MusicLibraryChanges {
        let scanned = try scan()

        lock.lock()
        let previous = storedIndex.entries
        storedIndex = MusicLibraryIndex(entries: scanned)
        lock.unlock()

        try saveIndex()
        return MusicLibrary.changes(from: previous, to: scanned)
    }

    /// Vergleicht zwei Eintragslisten. Getrennt und pur, damit die Logik ohne
    /// Dateisystem testbar bleibt.
    public static func changes(from previous: [MusicLibraryEntry],
                               to current: [MusicLibraryEntry]) -> MusicLibraryChanges {
        var previousByPath: [String: MusicLibraryEntry] = [:]
        previousByPath.reserveCapacity(previous.count)
        for entry in previous { previousByPath[entry.relativePath] = entry }

        var added: [MusicLibraryEntry] = []
        var modified: [MusicLibraryEntry] = []

        for entry in current {
            guard let old = previousByPath.removeValue(forKey: entry.relativePath) else {
                added.append(entry)
                continue
            }
            if !isUnchanged(old, entry) { modified.append(entry) }
        }

        // Was jetzt noch in der Zuordnung uebrig ist, stand im Index, liegt aber
        // nicht mehr auf Platte — also von aussen geloescht.
        let removed = previousByPath.values.sorted { $0.relativePath < $1.relativePath }
        return MusicLibraryChanges(added: added, removed: removed, modified: modified)
    }

    /// Gleiche Groesse und (bis auf eine Millisekunde) gleiches Datum = unveraendert.
    /// Die Toleranz faengt Rundungsunterschiede ab, die beim JSON-Umweg oder
    /// zwischen Dateisystemen mit unterschiedlicher Zeitaufloesung entstehen.
    private static func isUnchanged(_ lhs: MusicLibraryEntry, _ rhs: MusicLibraryEntry) -> Bool {
        guard lhs.fileSize == rhs.fileSize else { return false }
        let delta = abs(lhs.modificationDate.timeIntervalSince1970 - rhs.modificationDate.timeIntervalSince1970)
        return delta <= 0.001
    }

    // MARK: - Ordnerbaum

    /// Baut den Ordnerbaum aus den aktuellen Eintraegen. Ordner ohne SID-Dateien
    /// tauchen nicht auf — sie waeren in der Bibliotheksansicht nur leere Zweige.
    public func folderTree() -> MusicLibraryFolder {
        MusicLibrary.folderTree(for: entries)
    }

    /// Reine Funktion, damit sie ohne Dateisystem testbar ist.
    public static func folderTree(for entries: [MusicLibraryEntry]) -> MusicLibraryFolder {
        makeFolder(path: "", name: "", entries: entries, depth: 0)
    }

    /// Gruppiert die Eintraege rekursiv nach ihrer `depth`-ten Pfadkomponente.
    /// Beispiel bei depth 0 und "Tel_Jeroen/Cybernoid.sid": Schluessel
    /// "Tel_Jeroen". Eintraege, deren Pfad genau `depth + 1` Komponenten hat,
    /// liegen direkt in diesem Ordner.
    private static func makeFolder(path: String,
                                   name: String,
                                   entries: [MusicLibraryEntry],
                                   depth: Int) -> MusicLibraryFolder {
        var direct: [MusicLibraryEntry] = []
        var buckets: [String: [MusicLibraryEntry]] = [:]

        for entry in entries {
            let components = entry.pathComponents
            if components.count == depth + 1 {
                direct.append(entry)
            } else if components.count > depth + 1 {
                buckets[components[depth], default: []].append(entry)
            }
        }

        let subfolders = buckets.keys.sorted().map { key in
            makeFolder(path: path.isEmpty ? key : path + "/" + key,
                       name: key,
                       entries: buckets[key] ?? [],
                       depth: depth + 1)
        }

        return MusicLibraryFolder(
            path: path,
            name: name,
            subfolders: subfolders,
            entries: direct.sorted { $0.fileName < $1.fileName }
        )
    }

    // MARK: - Laden und Speichern

    /// Laedt den Index von Platte. Fehlende oder kaputte Datei ist KEIN Fehler:
    /// dann startet die Bibliothek leer und der naechste `refresh()` baut sie neu
    /// auf. Ein Absturz waere hier die schlechteste aller Reaktionen — der Index
    /// ist Wegwerf-Information, die Musik liegt weiter im Ordner.
    public func loadIndex() {
        let decoded: MusicLibraryIndex?
        if let data = try? Data(contentsOf: indexFileURL),
           let parsed = try? JSONDecoder().decode(MusicLibraryIndex.self, from: data),
           parsed.formatVersion == MusicLibrary.indexFormatVersion {
            decoded = parsed
        } else {
            decoded = nil
        }

        lock.lock()
        storedIndex = decoded ?? MusicLibraryIndex()
        lock.unlock()
    }

    /// Schreibt den Index atomar (erst temporaer, dann umbenennen) — ein
    /// Absturz mitten im Schreiben hinterlaesst so keine halbe Datei.
    public func saveIndex() throws {
        lock.lock()
        let snapshot = storedIndex
        lock.unlock()

        ensureDirectories()
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: indexFileURL, options: .atomic)
    }

    /// Legt Wurzel und Support-Ordner an, falls sie fehlen. Absichtlich ohne
    /// Fehlerweitergabe: schlaegt es fehl, scheitert der naechste echte Zugriff
    /// mit einer aussagekraeftigeren Meldung.
    private func ensureDirectories() {
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }
}

// Gemeinsame Pfad-Arithmetik fuer Bibliothek, Importer und Reset.
//
// Warum nicht einfach `url.path.hasPrefix(root.path)`? Weil dabei zu viel
// schiefgeht: "/tmp/lib2" faengt mit "/tmp/lib" an, ist aber ein ganz anderer
// Ordner; "../" im Pfad wuerde stillschweigend nach oben zeigen; und auf macOS
// ist `/tmp` ein Symlink auf `/private/tmp`, weshalb derselbe Ordner zwei
// verschiedene Schreibweisen hat. Deshalb wird immer normalisiert und dann
// KOMPONENTENWEISE verglichen.
enum LibraryPath {

    /// Pfadbestandteile in normalisierter Form: ".." aufgeloest, Symlinks
    /// aufgeloest. Beide Seiten eines Vergleichs muessen hier durch.
    static func normalizedComponents(_ url: URL) -> [String] {
        var components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        // Sonderfall macOS: `/var`, `/tmp` und `/etc` sind Symlinks nach
        // `/private/…`. Foundation entfernt das "/private" beim Aufloesen nur
        // dann, wenn der Pfad tatsaechlich existiert — ein noch nicht angelegtes
        // Ziel saehe sonst anders aus als sein bereits vorhandener Elternordner,
        // und der Vergleich schluege fehl. Deshalb hier IMMER entfernen.
        // Diese Komponenten dienen ausschliesslich dem Vergleich; es wird nie
        // eine Datei ueber sie geoeffnet.
        if components.count >= 2, components[0] == "/", components[1] == "private" {
            components.remove(at: 1)
        }
        return components
    }

    /// Pfad von `url` relativ zur Wurzel, oder `nil`, wenn `url` gar nicht
    /// unterhalb der Wurzel liegt (die Wurzel selbst zaehlt nicht als "unterhalb").
    static func relativePath(of url: URL, underRootComponents rootComponents: [String]) -> String? {
        let components = normalizedComponents(url)
        guard components.count > rootComponents.count else { return nil }
        guard Array(components.prefix(rootComponents.count)) == rootComponents else { return nil }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Liegt `url` echt unterhalb von `root`?
    static func isContained(_ url: URL, in root: URL) -> Bool {
        relativePath(of: url, underRootComponents: normalizedComponents(root)) != nil
    }
}
