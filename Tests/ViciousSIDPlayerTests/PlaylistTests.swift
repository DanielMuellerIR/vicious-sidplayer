import XCTest
@testable import ViciousSIDPlayerCore

// Tests fuer die Playlist-Logik, die bis 2026-08-15 unpruefbar in `MainView` der
// Mac-App lag: Titel-Identitaet, Duplikatpruefung, Suche, Favoriten und die
// Rechnung fuer den naechsten Titel.
//
// Der groesste Teil braucht kein Dateisystem — es sind reine Werte. Nur die
// beiden letzten Bloecke legen wirklich Dateien an, weil sie Scan und
// Index-Ablage pruefen.
final class PlaylistTests: XCTestCase {

    private let fm = FileManager.default
    private var base: URL!
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = fm.temporaryDirectory.appendingPathComponent("vicious-playlist-\(UUID().uuidString)")
        root = base.appendingPathComponent("Sammlung")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
        try super.tearDownWithError()
    }

    // Kurzschreibweise: eine Datei-URL unterhalb der Wurzel, ohne sie anzulegen.
    private func inRoot(_ relativePath: String) -> URL {
        var url = root!
        for component in relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func entry(_ relativePath: String) -> MusicLibraryEntry {
        MusicLibraryEntry(relativePath: relativePath,
                          displayName: (relativePath as NSString).lastPathComponent
                              .replacingOccurrences(of: ".sid", with: ""),
                          fileSize: 128,
                          modificationDate: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Titel-Identitaet

    func testTrackIDIsRelativeInsideTheLibraryAndAbsoluteOutside() {
        let inside = PlaylistTrackID.make(for: inRoot("Hubbard/Sanxion.sid"), root: root)
        XCTAssertEqual(inside, "Hubbard/Sanxion.sid")
        XCTAssertFalse(PlaylistTrackID.isExternal(inside))

        let outside = URL(fileURLWithPath: "/Users/test/Downloads/Fremd.sid")
        let external = PlaylistTrackID.make(for: outside, root: root)
        XCTAssertEqual(external, "/Users/test/Downloads/Fremd.sid")
        XCTAssertTrue(PlaylistTrackID.isExternal(external),
                      "Ein absoluter Pfad muss als Fremdtitel erkennbar bleiben")
    }

    func testTrackIDWithoutLibraryIsAlwaysAbsolute() {
        let id = PlaylistTrackID.make(for: inRoot("Sanxion.sid"), root: nil)
        XCTAssertTrue(PlaylistTrackID.isExternal(id))
    }

    // Der eigentliche Grund fuer die Umrechnung: die Mac-App hat Favoriten und
    // den zuletzt gespielten Titel frueher als absolute Pfade gesichert.
    func testStoredAbsolutePathsMigrateToRelativeIDs() {
        let stored = inRoot("Hubbard/Sanxion.sid").path
        XCTAssertEqual(PlaylistTrackID.migrate(stored, root: root), "Hubbard/Sanxion.sid")
    }

    func testMigrationIsIdempotentAndLeavesForeignPathsAlone() {
        let alreadyRelative = "Hubbard/Sanxion.sid"
        XCTAssertEqual(PlaylistTrackID.migrate(alreadyRelative, root: root), alreadyRelative,
                       "Ein zweiter Durchlauf darf nichts mehr veraendern")

        let foreign = "/Users/test/Downloads/Fremd.sid"
        XCTAssertEqual(PlaylistTrackID.migrate(foreign, root: root), foreign,
                       "Ausserhalb der Wurzel bleibt der absolute Pfad die Identitaet")
    }

    // MARK: - Aufnahme und Duplikate

    // Die zentrale Verhaltensentscheidung des Umbaus (2026-08-15): identisch
    // benannte Dateien in verschiedenen Ordnern sind verschiedene Titel. Vorher
    // galt auf dem Mac der blosse Dateiname, wodurch in einer nach Komponisten
    // sortierten Sammlung ganze Ordner unerreichbar blieben.
    func testSameFileNameInDifferentFoldersYieldsTwoTracks() {
        var playlist = Playlist()
        playlist.append([inRoot("Hubbard/Cybernoid.sid"), inRoot("Aleksi/Cybernoid.sid")], root: root)

        XCTAssertEqual(playlist.count, 2)
        XCTAssertEqual(playlist.tracks.map(\.id).sorted(),
                       ["Aleksi/Cybernoid.sid", "Hubbard/Cybernoid.sid"])
        XCTAssertEqual(Set(playlist.tracks.map(\.name)), ["Cybernoid"],
                       "Der Anzeigename bleibt der Dateiname; unterschieden wird ueber den Ordner")
    }

    func testTheSameFileIsNeverAddedTwice() {
        var playlist = Playlist()
        playlist.append([inRoot("Sanxion.sid")], root: root)
        let second = playlist.append([inRoot("Sanxion.sid")], root: root)

        XCTAssertEqual(playlist.count, 1)
        XCTAssertTrue(second.addedIDs.isEmpty)
        XCTAssertEqual(second.firstIndex, 0,
                       "Wer eine bereits geladene Datei erneut hereinzieht, will sie hoeren")
    }

    func testAdditionsReportTheFirstEntryOfTheBatch() {
        var playlist = Playlist()
        playlist.append([inRoot("A.sid")], root: root)
        let batch = playlist.append([inRoot("B.sid"), inRoot("C.sid")], root: root)

        XCTAssertEqual(batch.addedIDs, ["B.sid", "C.sid"])
        XCTAssertEqual(batch.firstIndex, 1)
    }

    // MARK: - Bibliothek und Fremdtitel nebeneinander

    func testLibraryReloadKeepsDroppedTracks() {
        var playlist = Playlist()
        let dropped = URL(fileURLWithPath: "/Users/test/Downloads/Fremd.sid")
        playlist.append([dropped], root: root)
        playlist.setLibrary([entry("Sanxion.sid"), entry("Commando.sid")], root: root)

        XCTAssertEqual(playlist.tracks.map(\.id),
                       ["Commando.sid", "Sanxion.sid", "/Users/test/Downloads/Fremd.sid"],
                       "Bibliothek vorn, hereingezogene Titel bleiben hinten stehen")
    }

    func testLibraryReloadReplacesTheOldLibraryPart() {
        var playlist = Playlist()
        playlist.setLibrary([entry("Alt.sid")], root: root)
        playlist.setLibrary([entry("Neu.sid")], root: root)

        XCTAssertEqual(playlist.tracks.map(\.id), ["Neu.sid"],
                       "Eine geloeschte Datei darf nach dem Abgleich nicht stehenbleiben")
    }

    // Der Index sortiert stur nach Zeichen, damit er reproduzierbar bleibt; die
    // Anzeige sortiert natuerlich, wie der Finder.
    func testLibraryTracksAreSortedNaturallyByFolderThenName() {
        var playlist = Playlist()
        playlist.setLibrary([entry("Track10.sid"), entry("Track2.sid"),
                             entry("Hubbard/Zeta.sid"), entry("Aleksi/alpha.sid")],
                            root: root)

        XCTAssertEqual(playlist.tracks.map(\.id),
                       ["Track2.sid", "Track10.sid", "Aleksi/alpha.sid", "Hubbard/Zeta.sid"],
                       "Wurzel zuerst, dann Ordner alphabetisch; Zahlen der Groesse nach")
    }

    // MARK: - Suche und Favoritenfilter

    func testSearchCoversNameAndFolder() {
        var playlist = Playlist()
        playlist.setLibrary([entry("Hubbard/Sanxion.sid"), entry("Galway/Rambo.sid")], root: root)
        let favorites = PlaylistFavorites()

        XCTAssertEqual(visibleIDs(playlist, search: "sanx", favorites: favorites), ["Hubbard/Sanxion.sid"])
        XCTAssertEqual(visibleIDs(playlist, search: "GALWAY", favorites: favorites), ["Galway/Rambo.sid"],
                       "Der Ordnername gehoert zur Suche und die Gross-/Kleinschreibung nicht")
        XCTAssertEqual(visibleIDs(playlist, search: "   ", favorites: favorites).count, 2,
                       "Nur Leerraum ist keine Suche")
    }

    func testFavoritesOnlyFilterCombinesWithSearch() {
        var playlist = Playlist()
        playlist.setLibrary([entry("Hubbard/Sanxion.sid"),
                             entry("Hubbard/Commando.sid"),
                             entry("Galway/Rambo.sid")], root: root)
        var favorites = PlaylistFavorites()
        favorites.toggle("Hubbard/Sanxion.sid")
        favorites.toggle("Galway/Rambo.sid")

        XCTAssertEqual(visibleIDs(playlist, search: "", favoritesOnly: true, favorites: favorites),
                       ["Galway/Rambo.sid", "Hubbard/Sanxion.sid"])
        XCTAssertEqual(visibleIDs(playlist, search: "hubbard", favoritesOnly: true, favorites: favorites),
                       ["Hubbard/Sanxion.sid"])
    }

    private func visibleIDs(_ playlist: Playlist,
                            search: String,
                            favoritesOnly: Bool = false,
                            favorites: PlaylistFavorites) -> [String] {
        playlist.visibleIndices(searchText: search, favoritesOnly: favoritesOnly, favorites: favorites)
            .map { playlist.tracks[$0].id }
    }

    // MARK: - Favoriten

    func testFavoritesLoadedFromOldAbsolutePathsSurviveTheRebuild() {
        let stored = [inRoot("Hubbard/Sanxion.sid").path,
                      "/Users/test/Downloads/Fremd.sid"]
        let favorites = PlaylistFavorites(storedValues: stored, root: root)

        XCTAssertTrue(favorites.contains("Hubbard/Sanxion.sid"),
                      "Der alte absolute Favorit muss den Titel weiterhin treffen")
        XCTAssertTrue(favorites.contains("/Users/test/Downloads/Fremd.sid"))
    }

    func testFavoriteToggleAndStorageOrder() {
        var favorites = PlaylistFavorites()
        XCTAssertTrue(favorites.toggle("B.sid"))
        XCTAssertTrue(favorites.toggle("A.sid"))
        XCTAssertFalse(favorites.toggle("B.sid"))

        XCTAssertEqual(favorites.storageValue, ["A.sid"],
                       "Gespeichert wird sortiert, damit die Einstellungen stabil bleiben")
    }

    // MARK: - Naechster und vorheriger Titel

    func testNextIndexWrapsAndStartsAtTheBeginning() {
        var playlist = Playlist()
        playlist.append([inRoot("A.sid"), inRoot("B.sid"), inRoot("C.sid")], root: root)

        XCTAssertEqual(playlist.nextIndex(after: 0, shuffle: false), 1)
        XCTAssertEqual(playlist.nextIndex(after: 2, shuffle: false), 0)
        XCTAssertEqual(playlist.nextIndex(after: -1, shuffle: false), 0,
                       "Ohne gewaehlten Titel beginnt die Wiedergabe vorn")
    }

    func testSingleTrackNeverAdvances() {
        var playlist = Playlist()
        playlist.append([inRoot("A.sid")], root: root)

        XCTAssertEqual(playlist.nextIndex(after: 0, shuffle: false), 0)
        XCTAssertEqual(playlist.nextIndex(after: 0, shuffle: true), 0)
        XCTAssertEqual(playlist.previousIndex(before: 0), 0)
    }

    func testShuffleNeverRepeatsTheRunningTrack() {
        var playlist = Playlist()
        playlist.append([inRoot("A.sid"), inRoot("B.sid"), inRoot("C.sid")], root: root)

        // Zufallsquelle, die stur den laufenden Titel liefert: die Wiedergabe
        // darf davon nicht haengenbleiben.
        XCTAssertEqual(playlist.nextIndex(after: 1, shuffle: true, randomIndex: { _ in 1 }), 2)
        // Und eine, die ausserhalb der Liste zeigt.
        XCTAssertEqual(playlist.nextIndex(after: 1, shuffle: true, randomIndex: { _ in 99 }), 0)
    }

    func testPreviousIndexWrapsToTheEnd() {
        var playlist = Playlist()
        playlist.append([inRoot("A.sid"), inRoot("B.sid"), inRoot("C.sid")], root: root)

        XCTAssertEqual(playlist.previousIndex(before: 0), 2)
        XCTAssertEqual(playlist.previousIndex(before: 2), 1)
        XCTAssertEqual(playlist.previousIndex(before: -1), 2,
                       "Ohne gewaehlten Titel fuehrt \"zurueck\" ans Ende der Liste")
    }

    // MARK: - Scan eines beliebigen Ordners

    // Der Weg fuer per Drag & Drop hereingezogene Ordner: derselbe Scan wie in
    // der Bibliothek, aber ohne Bibliothek und ohne Indexdatei.
    func testScanFolderWorksWithoutALibraryAndLeavesNoTraces() throws {
        let dropped = base.appendingPathComponent("Fremdordner")
        try fm.createDirectory(at: dropped.appendingPathComponent("Unterordner"),
                               withIntermediateDirectories: true)
        try Data([0x01]).write(to: dropped.appendingPathComponent("Eins.sid"))
        try Data([0x01]).write(to: dropped.appendingPathComponent("Unterordner/Zwei.SID"))
        try Data([0x01]).write(to: dropped.appendingPathComponent("liesmich.txt"))

        let entries = try MusicLibrary.scanFolder(dropped, fileManager: fm)

        XCTAssertEqual(entries.map(\.relativePath), ["Eins.sid", "Unterordner/Zwei.SID"],
                       "Rekursiv, Grossschreibung egal, Fremddateien draussen")
        XCTAssertEqual(entries[1].url(relativeTo: dropped).lastPathComponent, "Zwei.SID")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dropped.path).sorted(),
                       ["Eins.sid", "Unterordner", "liesmich.txt"],
                       "Der Scan darf im fremden Ordner nichts anlegen")
    }

    // MARK: - Index je Wurzel

    // Auf dem Mac ist der Bibliotheksordner in den Einstellungen frei waehlbar.
    // Mit einem gemeinsamen Indexnamen wuerde nach dem Umschalten der Index der
    // vorigen Sammlung geladen — und bliebe stehen, falls der Scan der neuen
    // Sammlung scheitert.
    func testEachRootKeepsItsOwnIndexFile() throws {
        let support = base.appendingPathComponent("Support")
        let rootA = base.appendingPathComponent("A")
        let rootB = base.appendingPathComponent("B")
        try fm.createDirectory(at: rootA, withIntermediateDirectories: true)
        try fm.createDirectory(at: rootB, withIntermediateDirectories: true)
        try Data([0x01]).write(to: rootA.appendingPathComponent("NurInA.sid"))

        let libraryA = MusicLibrary(root: rootA, supportDirectory: support, fileManager: fm,
                                    indexFileName: MusicLibrary.indexFileName(forRoot: rootA))
        try libraryA.refresh()
        XCTAssertEqual(libraryA.entries.map(\.relativePath), ["NurInA.sid"])

        // Dieselbe Ablage, andere Wurzel: der Index von A darf hier nicht
        // auftauchen — auch nicht vor dem ersten Abgleich.
        let libraryB = MusicLibrary(root: rootB, supportDirectory: support, fileManager: fm,
                                    indexFileName: MusicLibrary.indexFileName(forRoot: rootB))
        XCTAssertTrue(libraryB.isEmpty,
                      "Ein fremder Index darf nicht als Inhalt der neuen Wurzel erscheinen")
        XCTAssertNotEqual(libraryA.indexFileURL, libraryB.indexFileURL)

        // Und der Stand von A ueberlebt das Hin- und Herschalten.
        let backToA = MusicLibrary(root: rootA, supportDirectory: support, fileManager: fm,
                                   indexFileName: MusicLibrary.indexFileName(forRoot: rootA))
        XCTAssertEqual(backToA.entries.map(\.relativePath), ["NurInA.sid"])
    }
}
