import XCTest
import ViciousSIDPlayerCore
@testable import ViciousSIDPlayer

// Der Import-Durchlauf im Simulator — die Abnahme, die der Plan verlangt:
// „Ordner-Import eines synthetischen, verschachtelten Testbaums erhaelt die
// Struktur, dedupliziert, ist abbrechbar; Bibliothek zuruecksetzen leert
// sauber; danach funktioniert ein erneuter Import."
//
// Warum als Test und nicht als Klickstrecke: der Dateiauswahl-Dialog laesst sich
// nicht sinnvoll fernsteuern, und ein Bildschirmfoto beweist ohnehin nichts
// ueber Struktur, Dedupe oder Abbruch. Hier laeuft dieselbe Kette, die auch der
// Knopf ausloest — `AppModel.importFolder(at:)` → `LibraryImporter` → Index —,
// nur eben nachpruefbar und wiederholbar.
//
// Getestet wird gegen die ECHTE Bibliothek der App im Simulator-Container. Das
// ist Absicht: nur so ist belegt, dass Wurzel, Support-Ordner und Index im
// Zusammenspiel stimmen. Jeder Test beginnt und endet mit einem Reset.
//
// Keine echten `.sid`-Dateien: alle Fixtures entstehen zur Laufzeit.
@MainActor
final class LibraryImportIntegrationTests: XCTestCase {

    private let fm = FileManager.default
    private var model: AppModel!
    /// Quellbaum ausserhalb der Bibliothek, wird nach jedem Test geloescht.
    private var source: URL!

    override func setUp() async throws {
        try await super.setUp()
        model = AppModel()
        source = fm.temporaryDirectory.appendingPathComponent("vicious-import-\(UUID().uuidString)")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        await resetLibrary()
    }

    override func tearDown() async throws {
        if let source { try? fm.removeItem(at: source) }
        await resetLibrary()
        model = nil
        try await super.tearDown()
    }

    // MARK: - Hilfen

    /// Minimale, gueltige PSID-Datei. Aufbau nach SID-Dateiformat, alle Zahlen
    /// big-endian: 0x00 "PSID", 0x04 Version, 0x06 Datenversatz, 0x08 Lade-,
    /// 0x0A Init-, 0x0C Play-Adresse, 0x0E Anzahl Subtunes, ab 0x16/0x36/0x56 je
    /// 32 Byte Latin-1-Text. Dahinter ein paar Fuellbytes als „Maschinencode".
    private func makeSidFixture(title: String, payload: [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x7C)

        func putUInt16(_ value: Int, at offset: Int) {
            bytes[offset] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 1] = UInt8(value & 0xFF)
        }
        func putText(_ text: String, at offset: Int) {
            let encoded = text.data(using: .isoLatin1) ?? Data()
            for (index, byte) in encoded.prefix(31).enumerated() {
                bytes[offset + index] = byte
            }
        }

        for (index, byte) in Array("PSID".utf8).enumerated() { bytes[index] = byte }
        putUInt16(2, at: 0x04)
        putUInt16(0x7C, at: 0x06)
        putUInt16(0x1000, at: 0x08)
        putUInt16(0x1000, at: 0x0A)
        putUInt16(0x1003, at: 0x0C)
        putUInt16(1, at: 0x0E)
        putUInt16(1, at: 0x10)
        putText(title, at: 0x16)
        putText("Test Author", at: 0x36)
        putText("2026 Vicious Test", at: 0x56)
        putUInt16(0x0014, at: 0x76)

        return Data(bytes) + Data(payload)
    }

    @discardableResult
    private func write(_ relativePath: String, payload: [UInt8] = [0x60, 0xEA, 0xEA, 0xEA]) throws -> URL {
        let url = source.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeSidFixture(title: url.deletingPathExtension().lastPathComponent, payload: payload).write(to: url)
        return url
    }

    /// Wartet, bis kein Import mehr laeuft. Der Import arbeitet in einem eigenen
    /// Task; ohne Warten pruefte der Test einen Zwischenstand.
    private func waitForImport(timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.importProgress != nil || model.importTask != nil {
            if Date() > deadline {
                XCTFail("Import wurde nicht innerhalb von \(Int(timeout)) s fertig.")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Wartet, bis die Bibliotheksansicht neu aufgebaut ist.
    private func waitForLibrary(timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.services.libraryReloadTask != nil {
            if Date() > deadline {
                XCTFail("Bibliotheks-Abgleich wurde nicht fertig.")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Wartet, bis das Zuruecksetzen wirklich durch ist. Die Ansicht ist sofort
    /// leer, die Dateien verschwinden aber im Hintergrund — ohne dieses Warten
    /// pruefte der Test gegen einen halb geleerten Ordner.
    private func waitForReset(timeout: TimeInterval = 30) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.services.resetTask != nil {
            if Date() > deadline {
                XCTFail("Zuruecksetzen wurde nicht fertig.")
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func resetLibrary(keepFavorites: Bool = false) async {
        model.resetLibrary(keepFavorites: keepFavorites)
        await waitForReset()
        await waitForLibrary()
    }

    private func importSource() async {
        model.importFolder(at: source)
        await waitForImport()
        await waitForLibrary()
    }

    // MARK: - Struktur, Filter, Dedupe

    func testFolderImportKeepsStructureAndIgnoresForeignFiles() async throws {
        try write("Demos/Intro.sid")
        try write("Musicians/T/Tel_Jeroen/Cybernoid.sid", payload: [0x60, 0x01])
        try write("Musicians/H/Hubbard_Rob/Commando.sid", payload: [0x60, 0x02])
        // Diese beiden duerfen NICHT in der Bibliothek landen.
        try "kein SID".write(to: source.appendingPathComponent("Demos/liesmich.txt"),
                             atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: source.appendingPathComponent("Demos/cover.png"))

        await importSource()

        let ids = Set(model.tracks.map(\.id))
        XCTAssertEqual(ids, [
            "Demos/Intro.sid",
            "Musicians/T/Tel_Jeroen/Cybernoid.sid",
            "Musicians/H/Hubbard_Rob/Commando.sid"
        ], "Die Unterordnerstruktur muss 1:1 erhalten bleiben.")

        XCTAssertFalse(ids.contains { $0.hasSuffix(".txt") || $0.hasSuffix(".png") })

        // Die Dateien liegen auch wirklich dort, nicht nur im Index.
        let root = try XCTUnwrap(model.libraryRoot)
        for id in ids {
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(id).path),
                          "Fehlt auf der Platte: \(id)")
        }

        // Der Ordnerbaum, den die Bibliotheksansicht zeichnet.
        XCTAssertEqual(model.folderTree.totalTrackCount, 3)
        XCTAssertEqual(Set(model.folderTree.subfolders.map(\.name)), ["Demos", "Musicians"])

        let report = try XCTUnwrap(model.lastImportReport)
        XCTAssertEqual(report.imported, 3)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertFalse(report.wasCancelled)
    }

    func testSecondImportOfTheSameFolderSkipsEverything() async throws {
        try write("A/one.sid", payload: [0x60, 0x11])
        try write("A/B/two.sid", payload: [0x60, 0x22])

        await importSource()
        XCTAssertEqual(model.tracks.count, 2)

        // Genau dieselbe Quelle noch einmal: nichts Neues, nichts doppelt.
        await importSource()
        XCTAssertEqual(model.tracks.count, 2, "Ein zweiter Import darf nichts verdoppeln.")

        let report = try XCTUnwrap(model.lastImportReport)
        XCTAssertEqual(report.imported, 0)
        XCTAssertEqual(report.skipped, 2)
    }

    func testSameNameDifferentContentDoesNotOverwrite() async throws {
        try write("A/tune.sid", payload: [0x60, 0xAA])
        await importSource()
        XCTAssertEqual(model.tracks.count, 1)

        // Gleicher Zielpfad, anderer Inhalt: die vorhandene Datei darf nicht
        // verlorengehen, die neue braucht einen eigenen Namen.
        try write("A/tune.sid", payload: [0x60, 0xBB])
        await importSource()

        XCTAssertEqual(model.tracks.count, 2, "Bei Namenskollision darf nichts ueberschrieben werden.")
        XCTAssertTrue(model.tracks.contains { $0.id == "A/tune.sid" })
    }

    // MARK: - Abbruch

    func testCancelLeavesLibraryUsableAndAllowsAnotherImport() async throws {
        // Genug Dateien, damit der Abbruch realistisch mitten hinein faellt.
        for index in 0..<300 {
            try write("Bulk/\(String(format: "%03d", index)).sid",
                      payload: [0x60, UInt8(index % 251), UInt8(index / 251)])
        }

        model.importFolder(at: source)
        // Kurz laufen lassen, dann abbrechen.
        try? await Task.sleep(nanoseconds: 150_000_000)
        model.cancelImport()
        await waitForImport()
        await waitForLibrary()

        // Der Abbruch darf keinen Halbzustand hinterlassen: kein haengender
        // Fortschrittsbalken, und was kopiert wurde, ist im Index.
        XCTAssertNil(model.importProgress, "Nach dem Abbruch darf kein Fortschritt stehenbleiben.")
        let root = try XCTUnwrap(model.libraryRoot)
        for track in model.tracks {
            XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(track.id).path),
                          "Index nennt eine Datei, die es nicht gibt: \(track.id)")
        }

        // Und danach laesst sich der Rest ganz normal nachholen.
        await importSource()
        XCTAssertEqual(model.tracks.count, 300, "Nach einem Abbruch muss ein erneuter Import vollstaendig durchlaufen.")
    }

    // MARK: - Zuruecksetzen

    func testResetEmptiesLibraryAndImportWorksAgain() async throws {
        try write("A/one.sid", payload: [0x60, 0x31])
        try write("A/B/two.sid", payload: [0x60, 0x32])
        try write("C/three.sid", payload: [0x60, 0x33])
        await importSource()
        XCTAssertEqual(model.tracks.count, 3)

        await resetLibrary()

        XCTAssertTrue(model.tracks.isEmpty, "Nach dem Zuruecksetzen darf kein Titel uebrig sein.")
        XCTAssertEqual(model.folderTree.totalTrackCount, 0)

        // Die Wurzel selbst muss bleiben — auf iOS ist das `Documents/`, und ohne
        // sie schluege der naechste Import fehl.
        let root = try XCTUnwrap(model.libraryRoot)
        var isDir: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: root.path, isDirectory: &isDir) && isDir.boolValue)
        let leftovers = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "In der Wurzel liegt noch: \(leftovers)")

        // Zweimal zuruecksetzen ist kein Fehler.
        await resetLibrary()
        XCTAssertTrue(model.tracks.isEmpty)

        // Und danach geht es wieder von vorn los.
        await importSource()
        XCTAssertEqual(model.tracks.count, 3, "Nach dem Zuruecksetzen muss ein erneuter Import funktionieren.")
    }

    func testResetKeepsFavoritesWhenAsked() async throws {
        try write("A/one.sid", payload: [0x60, 0x41])
        await importSource()
        model.toggleFavorite("A/one.sid")
        XCTAssertTrue(model.isFavorite("A/one.sid"))

        await resetLibrary(keepFavorites: true)
        XCTAssertTrue(model.isFavorite("A/one.sid"),
                      "Mit eingeschaltetem Favoriten-behalten duerfen sie nicht verschwinden.")

        await resetLibrary(keepFavorites: false)
        XCTAssertFalse(model.isFavorite("A/one.sid"))
    }

    // MARK: - Fremdablage (Finder-Dateifreigabe)

    // Weg B des Plans: der Nutzer legt ueber den Finder Dateien direkt in
    // `Documents/` ab oder loescht welche. Die App muss das beim naechsten
    // Vordergrundwechsel bemerken — sonst fuehlt sich dieser Importweg kaputt an.
    func testRefreshPicksUpOutsideChanges() async throws {
        try write("A/one.sid", payload: [0x60, 0x51])
        await importSource()
        XCTAssertEqual(model.tracks.count, 1)

        let root = try XCTUnwrap(model.libraryRoot)

        // Von aussen hinzugefuegt.
        let smuggled = root.appendingPathComponent("Fremd/extern.sid")
        try fm.createDirectory(at: smuggled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeSidFixture(title: "Extern", payload: [0x60, 0x52]).write(to: smuggled)

        model.refreshLibrary()
        await waitForLibrary()
        XCTAssertTrue(model.tracks.contains { $0.id == "Fremd/extern.sid" },
                      "Von aussen abgelegte Dateien muessen auftauchen.")

        // Von aussen geloescht.
        try fm.removeItem(at: smuggled)
        model.refreshLibrary()
        await waitForLibrary()
        XCTAssertFalse(model.tracks.contains { $0.id == "Fremd/extern.sid" },
                       "Von aussen geloeschte Dateien muessen verschwinden.")
    }
}
