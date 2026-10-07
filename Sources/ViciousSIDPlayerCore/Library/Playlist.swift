import Foundation

// Die Playlist eines Frontends: welche Titel stehen zur Auswahl, welche davon
// sind gerade sichtbar, und welcher kommt als naechster?
//
// WARUM DAS HIER IM CORE STEHT:
// Bis 2026-08-15 lag diese Logik in `MainView.swift` der Mac-App — Ordner-Scan,
// Duplikatpruefung, Suche, Favoriten und die Naechster-Titel-Rechnung standen
// als `@State`-Felder mitten in einer SwiftUI-Ansicht. Eine solche Ansicht liegt
// in einem `executableTarget` und ist aus XCTest gar nicht erreichbar; die Regeln
// waren also unpruefbar, obwohl der Core mit `MusicLibrary` dieselbe Arbeit
// bereits getestet erledigte. Hier sind es reine Werte und Funktionen: kein
// Dateisystem, keine Oberflaeche, vollstaendig testbar.
//
// DIE STABILE IDENTITAET EINES TITELS (das Wichtigste an dieser Datei):
// Ein Titel wird ueber seinen Pfad RELATIV zur Bibliothekswurzel identifiziert,
// genau wie in `MusicLibrary` — "Hubbard/Sanxion.sid". Nur so ueberleben
// Favoriten und Sitzungswiederherstellung ein Verschieben der Sammlung, und auf
// iOS ueberhaupt eine Neuinstallation (dort wechselt die Container-UUID und
// damit jeder absolute Pfad).
//
// Die Mac-App kennt zusaetzlich Titel, die gar nicht in der Bibliothek liegen:
// per Drag & Drop oder "Oeffnen mit" hereingereichte Dateien von irgendwo auf
// der Platte. Die werden bewusst NICHT in die Bibliothek kopiert — der Nutzer
// hat sie ja nur kurz anhoeren wollen. Sie behalten ihren absoluten Pfad als
// Identitaet. Beide Faelle stehen in derselben Zeichenkette und lassen sich
// eindeutig unterscheiden: ein absoluter Pfad beginnt mit "/", ein relativer
// Bibliothekspfad nie.

/// Bildung und Umzug der stabilen Titel-Identitaet.
public enum PlaylistTrackID {

    /// Die ID einer Datei: ihr Pfad relativ zur Bibliothekswurzel, sonst ihr
    /// absoluter Pfad.
    ///
    /// - Parameter root: Bibliothekswurzel; `nil`, wenn gerade keine bekannt ist
    ///   (dann ist jede Datei ein Fremdtitel).
    public static func make(for url: URL, root: URL?) -> String {
        if let root,
           let relative = LibraryPath.relativePath(of: url,
                                                   underRootComponents: LibraryPath.normalizedComponents(root)) {
            return relative
        }
        return url.standardizedFileURL.path
    }

    /// Liegt der Titel ausserhalb der Bibliothek?
    ///
    /// Absolute Pfade beginnen mit "/", die relativen Pfade aus `MusicLibrary`
    /// niemals — die Unterscheidung braucht also keine zweite gespeicherte
    /// Angabe.
    public static func isExternal(_ id: String) -> Bool {
        id.hasPrefix("/")
    }

    /// Rechnet eine gespeicherte Identitaet auf die aktuelle Wurzel um.
    ///
    /// Dafuer gibt es einen konkreten Anlass: die Mac-App hat Favoriten und den
    /// zuletzt gespielten Titel frueher als ABSOLUTE Pfade gesichert. Ohne diese
    /// Umrechnung waeren nach dem Umbau alle Favoriten des Nutzers wertlos, denn
    /// die Titel heissen jetzt relativ.
    ///
    /// Die Funktion ist absichtlich mehrfach anwendbar: ein bereits relativer
    /// Wert geht unveraendert durch, ein absoluter Pfad ausserhalb der Wurzel
    /// ebenso (das ist ein Fremdtitel und soll absolut bleiben).
    public static func migrate(_ storedID: String, root: URL?) -> String {
        guard isExternal(storedID) else { return storedID }
        return make(for: URL(fileURLWithPath: storedID), root: root)
    }
}

/// Welcher Ausschnitt der Playlist in ein Aufklappmenue gehoert.
///
/// Hintergrund: Der Titelwaehler oben im Mac-Player war ein `Picker` ueber die
/// GANZE Liste. Auf macOS wird daraus ein Menue mit einem Eintrag je Titel —
/// bei einer HVSC-Sammlung also 50.000 Menueeintraege. Gemessen am 2026-08-23
/// kostete das rund 100 KB je Titel (5,2 GB bei 50.001 Titeln) und liess die
/// App beim Start abstuerzen. Deshalb zeigt das Menue ab einer Obergrenze nur
/// noch einen Ausschnitt rund um den laufenden Titel; gesucht wird in der
/// Titelliste der Seitenleiste.
public enum PlaylistMenuWindow {

    /// So viele Eintraege zeigt das Menue hoechstens.
    public static let defaultLimit = 300

    /// Die Positionen, die ins Menue gehoeren.
    ///
    /// - Parameters:
    ///   - count: Laenge der Playlist.
    ///   - anchor: Position des laufenden Titels; -1, wenn keiner laeuft.
    ///   - limit: Obergrenze der Eintraege.
    /// - Returns: bei kurzen Listen alle Positionen, sonst ein Fenster von
    ///   `limit` Positionen, das den laufenden Titel moeglichst mittig enthaelt
    ///   und die Listengrenzen nie ueberschreitet.
    public static func indices(count: Int,
                               anchor: Int,
                               limit: Int = defaultLimit) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }

        let center = (anchor >= 0 && anchor < count) ? anchor : 0
        // Erst mittig setzen, dann an den Rand schieben, falls das Fenster
        // sonst vor dem Anfang oder hinter dem Ende der Liste laege.
        let start = min(max(0, center - limit / 2), count - limit)
        return Array(start..<(start + limit))
    }
}

/// Ein Eintrag der Playlist.
///
/// Bewusst schlank und ohne Titel/Komponist aus dem Datei-Header: die stehen
/// erst nach dem Parsen fest, und bei einer grossen Sammlung waere das Parsen
/// aller Dateien beim Start unbezahlbar. Angezeigt wird deshalb der Dateiname;
/// die echten Metadaten liefert der Koordinator, sobald der Titel laeuft.
public struct PlaylistTrack: Identifiable, Hashable, Sendable {

    /// Stabile Identitaet — siehe `PlaylistTrackID`.
    public let id: String

    /// Anzeigename: Dateiname ohne Endung.
    public let name: String

    /// Ordner des Titels. Bei Bibliothekstiteln relativ zur Wurzel und leer,
    /// wenn die Datei direkt in der Wurzel liegt; bei Fremdtiteln der absolute
    /// Ordnerpfad. Die Suche schaut hier mit hinein, damit zwei gleichnamige
    /// Dateien aus verschiedenen Ordnern unterscheidbar bleiben.
    public let folderPath: String

    /// Absolute URL zur Laufzeit. Wird beim Aufbau der Playlist aus Wurzel und
    /// ID gebildet und nie gespeichert.
    public let url: URL

    /// Titel ausserhalb der Bibliothek (Drag & Drop, "Oeffnen mit").
    public var isExternal: Bool { PlaylistTrackID.isExternal(id) }

    public init(id: String, name: String, folderPath: String, url: URL) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.url = url
    }

    /// Eintrag aus einer beliebigen Datei-URL. Liegt sie unterhalb von `root`,
    /// wird sie zum Bibliothekstitel, sonst zum Fremdtitel.
    public init(url: URL, root: URL?) {
        let id = PlaylistTrackID.make(for: url, root: root)
        let folder: String
        if PlaylistTrackID.isExternal(id) {
            folder = url.standardizedFileURL.deletingLastPathComponent().path
        } else {
            folder = id.split(separator: "/").dropLast().joined(separator: "/")
        }
        self.init(id: id,
                  name: url.deletingPathExtension().lastPathComponent,
                  folderPath: folder,
                  url: url.standardizedFileURL)
    }

    /// Eintrag aus einem Bibliotheks-Index. Die absolute URL entsteht erst hier,
    /// aus der aktuellen Wurzel.
    public init(entry: MusicLibraryEntry, root: URL) {
        self.init(id: entry.relativePath,
                  name: entry.displayName,
                  folderPath: entry.folderPath,
                  url: entry.url(relativeTo: root))
    }
}

/// Die Suchregel der Titelliste — an genau einer Stelle, weil Mac-App und
/// iPhone-App dieselbe erwarten.
public enum PlaylistSearch {

    /// Passt ein Titel zum Suchbegriff?
    ///
    /// Gesucht wird in Titel- UND Ordnername. Der Ordner gehoert dazu, weil eine
    /// Sammlung wie die HVSC nach Komponisten sortiert ist: "hubbard" findet so
    /// dessen Ordner, und zwei gleichnamige Dateien aus verschiedenen Ordnern
    /// bleiben auseinanderzuhalten.
    ///
    /// Ein leerer Suchbegriff (auch einer aus lauter Leerzeichen) passt auf
    /// alles — sonst waere die Liste beim versehentlichen Druecken der
    /// Leertaste ploetzlich leer.
    public static func matches(name: String, folderPath: String, needle: String) -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(trimmed)
            || folderPath.localizedCaseInsensitiveContains(trimmed)
    }
}

/// Favoriten als Menge stabiler Titel-IDs.
///
/// Gespeichert wird eine sortierte Liste von Zeichenketten in den
/// Benutzereinstellungen — dasselbe Format wie bisher, nur mit relativen statt
/// absoluten Pfaden. Deshalb bleibt auch der Schluessel unveraendert: der alte
/// Bestand wird beim Laden umgerechnet (`migrated(storedValues:root:)`) und
/// nicht etwa verworfen.
public struct PlaylistFavorites: Equatable, Sendable {

    /// Schluessel in den Benutzereinstellungen. Unveraendert seit der ersten
    /// Fassung der Mac-App, damit vorhandene Favoriten erhalten bleiben.
    public static let userDefaultsKey = "favoriteTrackPaths"

    public private(set) var ids: Set<String>

    public init(ids: Set<String> = []) {
        self.ids = ids
    }

    /// Gespeicherte Werte, auf die aktuelle Wurzel umgerechnet.
    ///
    /// Absolute Pfade unterhalb der Wurzel werden relativ; alles andere bleibt,
    /// wie es ist. Ein zweiter Aufruf aendert nichts mehr.
    public init(storedValues: [String], root: URL?) {
        self.ids = Set(storedValues.map { PlaylistTrackID.migrate($0, root: root) })
    }

    /// Form fuer die Benutzereinstellungen: sortiert, damit die Datei bei
    /// gleichem Inhalt gleich aussieht und nicht bei jedem Start anders.
    public var storageValue: [String] { ids.sorted() }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// Schaltet den Favoritenstatus um.
    /// - Returns: `true`, wenn der Titel jetzt Favorit ist.
    @discardableResult
    public mutating func toggle(_ id: String) -> Bool {
        if ids.contains(id) {
            ids.remove(id)
            return false
        }
        ids.insert(id)
        return true
    }
}

/// Was ein Aufnahme-Auftrag (Drag & Drop, Dateiauswahl, "Oeffnen mit") bewirkt hat.
public struct PlaylistAdditions: Equatable, Sendable {

    /// Titel, die wirklich neu in die Liste kamen.
    public let addedIDs: [String]

    /// Index des ersten Titels aus dem Auftrag — auch dann gesetzt, wenn dieser
    /// Titel schon in der Liste stand. Genau darauf springt die Oberflaeche
    /// anschliessend: wer eine bereits geladene Datei noch einmal hereinzieht,
    /// erwartet, dass sie gespielt wird, und nicht, dass nichts passiert.
    public let firstIndex: Int?

    public init(addedIDs: [String] = [], firstIndex: Int? = nil) {
        self.addedIDs = addedIDs
        self.firstIndex = firstIndex
    }
}

/// Die Titelliste eines Frontends.
///
/// Sie besteht aus zwei Teilen in einer Reihenfolge: zuerst die Titel der
/// Bibliothek (sortiert), danach die Fremdtitel in der Reihenfolge, in der sie
/// hereingereicht wurden. Ein erneutes Laden der Bibliothek tauscht nur den
/// vorderen Teil aus — was der Nutzer per Drag & Drop dazugelegt hat, bleibt
/// stehen.
public struct Playlist: Equatable, Sendable {

    public private(set) var tracks: [PlaylistTrack]

    public init(tracks: [PlaylistTrack] = []) {
        self.tracks = tracks
    }

    public var count: Int { tracks.count }
    public var isEmpty: Bool { tracks.isEmpty }

    /// Titel an einer Position — `nil` bei ungueltigem Index, damit die Aufrufer
    /// nicht jedes Mal selbst pruefen muessen (und ein Fehler nicht abstuerzt).
    public func track(at index: Int) -> PlaylistTrack? {
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }

    public func index(forID id: String) -> Int? {
        tracks.firstIndex { $0.id == id }
    }

    public mutating func removeAll() {
        tracks.removeAll()
    }

    // MARK: - Aufbau

    /// Ersetzt den Bibliotheksteil der Liste durch den uebergebenen Indexstand.
    /// Fremdtitel bleiben erhalten und ruecken hinter die Bibliothekstitel.
    ///
    /// Sortiert wird nach Ordner, dann nach Name, und zwar mit
    /// `localizedStandardCompare` — der "natuerlichen" Sortierung des Finders:
    /// "Track2" vor "Track10", Gross- und Kleinschreibung gemischt statt in zwei
    /// Bloecken. `MusicLibrary` sortiert bewusst stur nach Zeichen, weil ein
    /// gespeicherter Index reproduzierbar sein muss; wie die Liste dem Nutzer
    /// praesentiert wird, entscheidet erst diese Stelle.
    public mutating func setLibrary(_ entries: [MusicLibraryEntry], root: URL) {
        let libraryTracks = entries
            .map { PlaylistTrack(entry: $0, root: root) }
            .sorted(by: Playlist.isOrderedBefore)
        let external = tracks.filter(\.isExternal)
        tracks = libraryTracks + external
    }

    /// Wie `setLibrary`, haelt dabei aber den laufenden Titel fest.
    ///
    /// Gebraucht wird das, seit der Abgleich mit dem Dateisystem im Hintergrund
    /// laeuft: Das Ergebnis trifft ein, waehrend schon gespielt wird. Die Liste
    /// wird dabei neu aufgebaut und sortiert, der laufende Titel steht danach
    /// also an einer anderen POSITION — ein einfach beibehaltener Index zeigte
    /// auf einen fremden Titel. Wiedergefunden wird er ueber seine stabile ID.
    ///
    /// - Parameter currentIndex: Position des laufenden Titels vor dem Abgleich.
    /// - Returns: seine Position danach, oder -1, wenn vorher keiner lief oder
    ///   der Titel nicht mehr in der Liste steht (aus der Bibliothek geloescht).
    @discardableResult
    public mutating func setLibrary(_ entries: [MusicLibraryEntry],
                                    root: URL,
                                    keepingTrackAt currentIndex: Int) -> Int {
        let keptID = track(at: currentIndex)?.id
        setLibrary(entries, root: root)
        guard let keptID else { return -1 }
        return index(forID: keptID) ?? -1
    }

    /// Nimmt Dateien in die Liste auf, ohne Doppelte.
    ///
    /// Doppelt heisst: gleiche stabile ID, also dieselbe Datei. Bis 2026-08-15
    /// galt auf dem Mac stattdessen "gleicher DATEINAME, egal wo" — bei einer
    /// verschachtelten Sammlung blieben damit ganze Ordner unerreichbar, weil
    /// zwei Komponisten dieselbe Spielmusik gesetzt haben und nur die erste
    /// Fassung in der Liste landete.
    @discardableResult
    public mutating func append(_ urls: [URL], root: URL?) -> PlaylistAdditions {
        var addedIDs: [String] = []
        var firstIndex: Int?

        for url in urls {
            let candidate = PlaylistTrack(url: url, root: root)
            if let existing = index(forID: candidate.id) {
                if firstIndex == nil { firstIndex = existing }
                continue
            }
            tracks.append(candidate)
            addedIDs.append(candidate.id)
            if firstIndex == nil { firstIndex = tracks.count - 1 }
        }

        return PlaylistAdditions(addedIDs: addedIDs, firstIndex: firstIndex)
    }

    /// Fremddateien bleiben auch neben dem Bibliotheks-Ordnerbaum erreichbar.
    public var externalIndices: [Int] {
        tracks.indices.filter { tracks[$0].isExternal }
    }

    // MARK: - Anzeige

    /// Die sichtbaren Positionen nach Suche und Favoritenfilter.
    ///
    /// Absichtlich Indizes und keine Titel: Auswahl, Auto-Next und
    /// Zufallswiedergabe der Mac-App rechnen mit Positionen in der VOLLEN Liste.
    /// Der Filter aendert nur, was zu sehen ist, nicht, was gespielt wird.
    public func visibleIndices(searchText: String,
                               favoritesOnly: Bool,
                               favorites: PlaylistFavorites) -> [Int] {
        tracks.indices.filter { index in
            let track = tracks[index]
            if favoritesOnly && !favorites.contains(track.id) { return false }
            return PlaylistSearch.matches(name: track.name,
                                          folderPath: track.folderPath,
                                          needle: searchText)
        }
    }

    // MARK: - Naechster und vorheriger Titel

    /// Position des naechsten Titels.
    ///
    /// - Parameters:
    ///   - current: aktuelle Position; -1 (nichts gewaehlt) ergibt den ersten Titel.
    ///   - shuffle: bei Zufallswiedergabe ein anderer als der laufende.
    ///   - randomIndex: Zufallsquelle, fuer Tests austauschbar. Bekommt die
    ///     Anzahl der Titel und liefert eine Position darin.
    public func nextIndex(after current: Int,
                          shuffle: Bool,
                          randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Int {
        guard count > 1 else { return current }
        if shuffle {
            var candidate = randomIndex(count)
            // Sicherheitsnetz gegen eine kaputte Zufallsquelle und gegen den
            // Fall "wieder derselbe Titel": beides wuerde die Wiedergabe
            // festhaengen lassen.
            if !tracks.indices.contains(candidate) { candidate = 0 }
            if candidate == current { candidate = (candidate + 1) % count }
            return candidate
        }
        guard current >= 0 else { return 0 }
        return (current + 1) % count
    }

    /// Position des vorherigen Titels. Ohne gewaehlten Titel der letzte —
    /// "zurueck" vom Nichts fuehrt ans Ende der Liste, nicht irgendwohin.
    public func previousIndex(before current: Int) -> Int {
        guard count > 1 else { return current }
        guard current >= 0 else { return count - 1 }
        return (current - 1 + count) % count
    }

    // MARK: - Sortierung

    /// Ordner zuerst, dann Dateiname — beides natuerlich sortiert.
    private static func isOrderedBefore(_ lhs: PlaylistTrack, _ rhs: PlaylistTrack) -> Bool {
        let folders = lhs.folderPath.localizedStandardCompare(rhs.folderPath)
        if folders != .orderedSame { return folders == .orderedAscending }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
