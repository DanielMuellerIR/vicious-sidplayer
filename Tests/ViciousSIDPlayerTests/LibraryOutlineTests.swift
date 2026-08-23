import XCTest
@testable import ViciousSIDPlayerCore

// Tests fuer den flachgeklopften Ordnerbaum.
//
// Die Rechnung stand bis 2026-08-23 im iOS-App-Ziel und war damit aus XCTest
// gar nicht erreichbar. Genau die beiden Eigenschaften, auf die es bei einer
// HVSC-Sammlung ankommt, sind hier festgehalten: Zugeklappte Ordner werden
// nicht betreten, und die Anzeige sortiert natuerlich.
final class LibraryOutlineTests: XCTestCase {

    private func entry(_ relativePath: String) -> MusicLibraryEntry {
        MusicLibraryEntry(relativePath: relativePath,
                          displayName: ((relativePath as NSString).lastPathComponent as NSString)
                              .deletingPathExtension,
                          fileSize: 128,
                          modificationDate: Date(timeIntervalSince1970: 0))
    }

    private func tree(_ paths: [String]) -> MusicLibraryFolder {
        MusicLibrary.folderTree(for: paths.map(entry))
    }

    // MARK: - Aufklappen

    func testCollapsedFoldersShowOnlyTheirOwnRow() {
        let rows = LibraryOutline.rows(of: tree(["Hubbard/Commando.sid", "Hubbard/Warhawk.sid"]),
                                       expanded: [])
        XCTAssertEqual(rows.map(\.id), ["d:Hubbard"],
                       "Ein zugeklappter Ordner zeigt seine Titel nicht")
    }

    func testExpandedFolderShowsItsTracks() {
        let rows = LibraryOutline.rows(of: tree(["Hubbard/Commando.sid", "Hubbard/Warhawk.sid"]),
                                       expanded: ["Hubbard"])
        XCTAssertEqual(rows.map(\.id),
                       ["d:Hubbard", "f:Hubbard/Commando.sid", "f:Hubbard/Warhawk.sid"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1], "Titel stehen eine Stufe unter ihrem Ordner")
    }

    // Der eigentliche Grund fuer die flache Liste: Bei zehntausenden Dateien
    // darf ein zugeklappter Ast keine Arbeit machen.
    func testDeeplyNestedCollapsedBranchesCostNothing() {
        let rows = LibraryOutline.rows(of: tree(["A/B/C/D/Tune.sid"]), expanded: ["A"])
        XCTAssertEqual(rows.map(\.id), ["d:A", "d:A/B"],
                       "Nur die naechste Ebene wird sichtbar, nicht der ganze Ast")
    }

    func testFoldersComeBeforeTracksOfTheSameLevel() {
        let rows = LibraryOutline.rows(of: tree(["Zzz.sid", "Aaa/Tune.sid"]), expanded: [])
        XCTAssertEqual(rows.map(\.id), ["d:Aaa", "f:Zzz.sid"],
                       "Sonst verschwaenden die Unterordner zwischen den Dateien")
    }

    func testFolderCountsIncludeSubfolders() {
        let rows = LibraryOutline.rows(of: tree(["A/1.sid", "A/B/2.sid", "A/B/3.sid"]), expanded: [])
        guard case .folder(let a) = rows[0] else { return XCTFail("Ordnerzeile erwartet") }
        XCTAssertEqual(a.trackCount, 3, "Der Zaehler meint den ganzen Ast, nicht nur die Ebene")
        XCTAssertFalse(a.isExpanded)
    }

    // MARK: - Sortierung

    func testDisplayOrderIsNaturalNotByteOrder() {
        let rows = LibraryOutline.rows(of: tree(["Track10.sid", "Track2.sid"]), expanded: [])
        XCTAssertEqual(rows.map(\.id), ["f:Track2.sid", "f:Track10.sid"],
                       "Wie im Finder: Zahlen der Groesse nach, nicht nach Zeichen")
    }

    func testFolderOrderIsNaturalToo() {
        let rows = LibraryOutline.rows(of: tree(["Ordner10/a.sid", "Ordner2/a.sid"]), expanded: [])
        XCTAssertEqual(rows.map(\.id), ["d:Ordner2", "d:Ordner10"])
    }

    // MARK: - Alles aufklappen

    func testAllFolderPathsCoversEveryLevel() {
        XCTAssertEqual(LibraryOutline.allFolderPaths(of: tree(["A/B/C/Tune.sid", "X/Tune.sid"])),
                       ["A", "A/B", "A/B/C", "X"])
    }

    func testAllFolderPathsOfAFlatLibraryIsEmpty() {
        XCTAssertTrue(LibraryOutline.allFolderPaths(of: tree(["Tune.sid"])).isEmpty)
    }

    func testEmptyLibraryHasNoRows() {
        XCTAssertTrue(LibraryOutline.rows(of: tree([]), expanded: []).isEmpty)
    }
}
