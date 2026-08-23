import XCTest
@testable import ViciousSIDPlayerCore

// Tests fuer die STIL-Datenbank der HVSC (`DOCUMENTS/STIL.txt`).
//
// Die echte Datei wird bewusst nicht mitgeliefert (sie gehoert dem
// HVSC-Projekt), deshalb arbeiten diese Tests mit Ausschnitten, die dem
// dokumentierten Format nachgebaut sind: Kopftext, Ordner- und Datei-Eintraege,
// Felder je Subtune, umgebrochene Absaetze und Windows-Zeilenenden.
final class STILTests: XCTestCase {

    // Ein Ausschnitt in der Form, wie ihn die HVSC ausliefert.
    private let sample = """
    #  STIL.txt - SID Tune Information List
    #
    #  Dieser Kopftext gehoert zu keinem Eintrag.

    /MUSICIANS/H/Hubbard_Rob/
    COMMENT: Rob Hubbard ist einer der bekanntesten C64-Komponisten.

    /MUSICIANS/H/Hubbard_Rob/Commando.sid
    COMMENT: Umsetzung des Arcade-Automaten. Der Absatz laeuft ueber
             mehrere Zeilen, weil die HVSC hart umbricht.
    (#1)
      NAME: Titelmusik
      ARTIST: Rob Hubbard
    (#2)
      NAME: Ingame

    /MUSICIANS/G/Galway_Martin/Wizball.sid
    TITLE: Wizball
    ARTIST: Martin Galway
    """

    private func db() -> STILDatabase { STILDatabase.parse(text: sample) }

    // MARK: - Aufbau

    func testHeaderBeforeTheFirstEntryIsIgnored() {
        let parsed = db()
        XCTAssertEqual(parsed.count, 2, "Zwei Datei-Eintraege, der Kopftext zaehlt nicht mit")
        XCTAssertEqual(parsed.folderCount, 1)
    }

    func testFileEntryKeepsItsGlobalComment() {
        let entry = db().entry(forHVSCPath: "/MUSICIANS/H/Hubbard_Rob/Commando.sid")
        XCTAssertEqual(entry?.global.first?.label, "COMMENT")
        XCTAssertEqual(entry?.global.first?.value,
                       "Umsetzung des Arcade-Automaten. Der Absatz laeuft ueber mehrere Zeilen, weil die HVSC hart umbricht.",
                       "Umgebrochene Absaetze gehoeren wieder zusammengefuegt")
    }

    func testSubtuneFieldsAreKeptApart() {
        let entry = db().entry(forHVSCPath: "/MUSICIANS/H/Hubbard_Rob/Commando.sid")
        XCTAssertEqual(entry?.subtunes[1]?.map(\.label), ["NAME", "ARTIST"])
        XCTAssertEqual(entry?.subtunes[1]?.first?.value, "Titelmusik")
        XCTAssertEqual(entry?.subtunes[2]?.map(\.value), ["Ingame"])
    }

    func testLookupIgnoresUpperAndLowerCase() {
        XCTAssertNotNil(db().entry(forHVSCPath: "/musicians/g/galway_martin/wizball.sid"))
    }

    func testUnknownPathHasNoEntry() {
        XCTAssertNil(db().entry(forHVSCPath: "/MUSICIANS/H/Hubbard_Rob/Sanxion.sid"))
    }

    // MARK: - Anzeige fuer einen Titel

    // Der Player zaehlt Subtunes ab 0, die Datei ab 1. Genau diese Umrechnung
    // ist die Stelle, an der ein Fehler dem Nutzer den falschen Text zeigt.
    func testInfoTranslatesTheZeroBasedSubtuneOfThePlayer() {
        let info = db().info(forHVSCPath: "/MUSICIANS/H/Hubbard_Rob/Commando.sid", subtune: 0)
        XCTAssertEqual(info.subtune.first?.value, "Titelmusik")

        let second = db().info(forHVSCPath: "/MUSICIANS/H/Hubbard_Rob/Commando.sid", subtune: 1)
        XCTAssertEqual(second.subtune.first?.value, "Ingame")
    }

    func testInfoAddsTheCommentOfTheSurroundingFolder() {
        let info = db().info(forHVSCPath: "/MUSICIANS/H/Hubbard_Rob/Commando.sid", subtune: 0)
        XCTAssertEqual(info.folder.first?.value,
                       "Rob Hubbard ist einer der bekanntesten C64-Komponisten.")
        XCTAssertEqual(info.orderedFields.map(\.label), ["NAME", "ARTIST", "COMMENT", "COMMENT"],
                       "Vom Genauen zum Allgemeinen: Subtune, dann Datei, dann Ordner")
    }

    func testInfoOfAnUnknownTrackIsEmpty() {
        XCTAssertTrue(db().info(forHVSCPath: "/DEMOS/Unbekannt.sid", subtune: 0).isEmpty)
    }

    // Ein Titel, zu dem es nur einen Ordnerkommentar gibt, ist kein leerer Fall:
    // die Anmerkung gilt trotzdem.
    func testFolderCommentAloneIsStillShown() {
        let info = db().info(forHVSCPath: "/MUSICIANS/H/Hubbard_Rob/Warhawk.sid", subtune: 0)
        XCTAssertFalse(info.isEmpty)
        XCTAssertTrue(info.file.isEmpty)
        XCTAssertEqual(info.folder.count, 1)
    }

    // MARK: - Zeilenenden

    // Die HVSC liefert ihre Textdateien mit Windows-Zeilenenden aus. In Swift
    // ist "\r\n" EIN Character; ein Parser, der an "\n" trennt, sieht deshalb
    // eine einzige Riesenzeile und findet gar nichts.
    func testWindowsLineEndingsParseTheSameAsUnixOnes() {
        let crlf = sample.replacingOccurrences(of: "\n", with: "\r\n")
        let parsed = STILDatabase.parse(text: crlf)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed.entry(forHVSCPath: "/MUSICIANS/G/Galway_Martin/Wizball.sid")?
                        .global.map(\.label), ["TITLE", "ARTIST"])
    }

    // MARK: - Einzelteile des Parsers

    func testSubtuneMarkerIsRecognizedOnlyInItsExactForm() {
        XCTAssertEqual(STILDatabase.subtuneNumber("(#12)"), 12)
        XCTAssertNil(STILDatabase.subtuneNumber("(#)"))
        XCTAssertNil(STILDatabase.subtuneNumber("(#a)"))
        XCTAssertNil(STILDatabase.subtuneNumber("Text (#1) mittendrin"))
    }

    // Ohne diese Einschraenkung waere jede Kommentarzeile mit Doppelpunkt
    // ("Siehe auch: ...") ein neues Feld und riesse den Absatz auseinander.
    func testOnlyUppercaseLabelsCountAsFields() {
        XCTAssertEqual(STILDatabase.field("COMMENT: Text")?.0, "COMMENT")
        XCTAssertEqual(STILDatabase.field("COMMENT: Text")?.1, "Text")
        XCTAssertNil(STILDatabase.field("Siehe auch: dort"))
        XCTAssertNil(STILDatabase.field("Kein Doppelpunkt"))
    }

    func testIndentedLinesStartingWithASlashStayPartOfTheComment() {
        let text = """
        /DEMOS/Test.sid
        COMMENT: Pfad im Text:
                 /MUSICIANS/H/Hubbard_Rob/Commando.sid gehoert dazu.
        """
        let parsed = STILDatabase.parse(text: text)
        XCTAssertEqual(parsed.count, 1, "Die eingerueckte Zeile ist kein neuer Eintrag")
        XCTAssertEqual(parsed.entry(forHVSCPath: "/DEMOS/Test.sid")?.global.first?.value,
                       "Pfad im Text: /MUSICIANS/H/Hubbard_Rob/Commando.sid gehoert dazu.")
    }

    // MARK: - Datei finden und Pfade umrechnen

    func testAutodetectFindsTheFileInTheCollectionAndAboveIt() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("vicious-stil-\(UUID().uuidString)")
        let hvsc = base.appendingPathComponent("HVSC")
        let musicians = hvsc.appendingPathComponent("MUSICIANS/H/Hubbard_Rob")
        try fm.createDirectory(at: musicians, withIntermediateDirectories: true)
        try fm.createDirectory(at: hvsc.appendingPathComponent("DOCUMENTS"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let stil = hvsc.appendingPathComponent("DOCUMENTS/STIL.txt")
        try "".write(to: stil, atomically: true, encoding: .utf8)

        // Aus einem Unterordner der Sammlung heraus gefunden.
        let found = try XCTUnwrap(STILDatabase.autodetect(nearFolder: musicians, fm: fm))
        XCTAssertEqual(found.standardizedFileURL, stil.standardizedFileURL)

        // Und die Wurzel dazu ist der Ordner ueber DOCUMENTS.
        XCTAssertEqual(STILDatabase.hvscRoot(forSTILFile: found).standardizedFileURL,
                       hvsc.standardizedFileURL)
    }

    func testAutodetectStopsAfterFourLevels() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("vicious-stil-\(UUID().uuidString)")
        let deep = base.appendingPathComponent("a/b/c/d/e")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("DOCUMENTS"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        try "".write(to: base.appendingPathComponent("DOCUMENTS/STIL.txt"),
                     atomically: true, encoding: .utf8)

        XCTAssertNil(STILDatabase.autodetect(nearFolder: deep, fm: fm),
                     "Fuenf Ebenen tiefer wird bewusst nicht mehr gesucht")
    }

    func testHVSCPathIsTheFilePathRelativeToTheRoot() {
        let root = URL(fileURLWithPath: "/Volumes/Musik/HVSC")
        let file = root.appendingPathComponent("MUSICIANS/H/Hubbard_Rob/Commando.sid")
        XCTAssertEqual(STILDatabase.hvscPath(for: file, root: root),
                       "/MUSICIANS/H/Hubbard_Rob/Commando.sid")
    }

    // Eine Datei ausserhalb der HVSC-Wurzel bekommt keinen geratenen Pfad:
    // Lieber keine Anmerkung als die eines fremden Titels.
    func testFileOutsideTheRootHasNoHVSCPath() {
        let root = URL(fileURLWithPath: "/Volumes/Musik/HVSC")
        let outside = URL(fileURLWithPath: "/Users/test/Downloads/Commando.sid")
        XCTAssertNil(STILDatabase.hvscPath(for: outside, root: root))
    }

    func testLoadFallsBackToLatin1WhenTheFileIsNotUTF8() throws {
        // "COMMENT: Grün" in ISO-8859-1 — als UTF-8 gelesen waere das ungueltig.
        var bytes: [UInt8] = Array("/DEMOS/Test.sid\nCOMMENT: Gr".utf8)
        bytes.append(0xFC)                       // "ü" in ISO-8859-1
        bytes.append(contentsOf: Array("n".utf8))
        let text = STILDatabase.decode(Data(bytes))
        let parsed = STILDatabase.parse(text: text)
        XCTAssertEqual(parsed.entry(forHVSCPath: "/DEMOS/Test.sid")?.global.first?.value, "Grün")
    }
}
