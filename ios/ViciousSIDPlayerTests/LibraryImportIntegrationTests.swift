import XCTest
import ViciousSIDPlayerCore
@testable import ViciousSIDPlayer

/// Haelt genau den ersten Dateizugriff offen, bis der Test den zweiten Import
/// gestartet hat. So prueft der Test das Wettrennen ohne Dateigroessen- oder
/// Scheduler-Glueck.
private actor ImportReadBarrier {
    private let blockedURL: URL
    private var didReachBlockedRead = false
    private var wasReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(blockedURL: URL) {
        self.blockedURL = blockedURL.standardizedFileURL
    }

    var isWaiting: Bool {
        didReachBlockedRead && !wasReleased
    }

    func load(_ url: URL) async throws -> Data {
        if url.standardizedFileURL == blockedURL {
            didReachBlockedRead = true
            // Der echte Import bricht den ersten Auftrag ab. Die Test-Sperre
            // muss auf diesen Abbruch reagieren, sonst koennte der zweite
            // Auftrag nie hinter dem ersten weiterlaufen.
            await withTaskCancellationHandler {
                await waitUntilReleased()
            } onCancel: {
                Task { await self.release() }
            }
        }
        return try Data(contentsOf: url)
    }

    private func waitUntilReleased() async {
        guard !wasReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        wasReleased = true
        continuation?.resume()
        continuation = nil
    }
}

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

    private enum MetadataImport {
        case stil
        case songlengths
    }

    private let fm = FileManager.default
    private var model: AppModel!
    /// Quellbaum ausserhalb der Bibliothek, wird nach jedem Test geloescht.
    private var source: URL!
    /// Eigene UserDefaults-Suite, damit der Test nichts im produktiven
    /// Speicher der Test-App hinterlaesst (Review-Fund 2026-08-17).
    // Ein stabiler Name verhindert eine neue zurückbleibende plist je Test.
    private let suiteName = "vsp-tests-library-import"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        model = AppModel(defaults: defaults)
        source = fm.temporaryDirectory.appendingPathComponent("vicious-import-\(UUID().uuidString)")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        await resetLibrary()
    }

    override func tearDown() async throws {
        if let source { try? fm.removeItem(at: source) }
        await resetLibrary()
        model = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
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

    /// Wartet den Dateisystem-Commit und den anschliessenden UI-Zustandswechsel ab.
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
        XCTAssertEqual(model.folderTree.totalEntryCount, 3)
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
        XCTAssertEqual(model.folderTree.totalEntryCount, 0)

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

    // Regression: „Zuruecksetzen" ist eine EXKLUSIVE Bibliotheksoperation.
    // Solange es laeuft, darf kein Import starten — er kopierte sonst in einen
    // Ordner, den der Reset gerade leert, und waere sofort wieder weg.
    //
    // Der Test bleibt bewusst ohne `await` zwischen Reset-Start und
    // Importversuch: `resetLibrary` setzt `resetTask` synchron, und ohne
    // Unterbrechung bleibt der MainActor bis zur Pruefung in unserer Hand. So
    // trifft der Importversuch garantiert das offene Reset-Fenster.
    func testImportIsRefusedWhileResetIsRunning() async throws {
        try write("A/one.sid", payload: [0x60, 0x61])
        await importSource()
        XCTAssertEqual(model.tracks.count, 1)

        model.resetLibrary(keepFavorites: true)
        XCTAssertNotNil(model.services.resetTask, "Das Zuruecksetzen laeuft noch nicht.")

        model.importFolder(at: source)
        XCTAssertNil(model.importTask, "Waehrend des Zuruecksetzens darf kein Import starten.")
        XCTAssertNil(model.importProgress)
        XCTAssertNotNil(model.errorMessage, "Der abgelehnte Import muss gemeldet werden.")

        await waitForReset()
        await waitForLibrary()
        XCTAssertTrue(model.tracks.isEmpty, "Der Reset muss trotzdem sauber durchlaufen.")
    }

    // Regression: der Reset wartet das Ende eines laufenden Imports ab, statt
    // ihm nur `cancel()` zuzurufen. Sonst schriebe der noch laufende
    // Kopierauftrag nach dem Loeschen eine Datei zurueck — die Bibliothek waere
    // nach dem Zuruecksetzen nicht leer.
    func testResetWaitsForTheRunningImportAndLeavesNothingBehind() async throws {
        for index in 0..<200 {
            try write("Bulk/\(String(format: "%03d", index)).sid",
                      payload: [0x60, UInt8(index % 251), UInt8(index / 251)])
        }

        model.importFolder(at: source)
        // Kurz laufen lassen, damit der Reset wirklich mitten hineinfaellt.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNotNil(model.importTask, "Der Import laeuft schon nicht mehr.")

        model.resetLibrary(keepFavorites: true)
        await waitForReset()

        XCTAssertNil(model.importTask,
                     "Der Reset war fertig, obwohl der Import noch lief — er hat nicht abgewartet.")
        let root = try XCTUnwrap(model.libraryRoot)
        let leftovers = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "Nach dem Zuruecksetzen liegt noch etwas in der Wurzel: \(leftovers)")

        await waitForLibrary()
        XCTAssertTrue(model.tracks.isEmpty)
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

    func testFailedResetPreservesTrackPositionSessionFavoritesAndLibrary() async throws {
        try write("A/one.sid")
        await importSource()
        XCTAssertTrue(model.loadTrack(id: "A/one.sid", autoplay: false))
        model.cancelLengthEstimate()
        model.coordinator.seek(seconds: 12)
        model.toggleFavorite("A/one.sid")
        model.saveSessionState()
        let md5 = try XCTUnwrap(model.currentMD5)
        model.lengthCache.store(md5: md5, subtune: 0, seconds: 99)
        model.computedLength = 99
        let tracks = model.tracks
        let session = defaults.dictionaryRepresentation()
        let root = try XCTUnwrap(model.libraryRoot)
        let link = root.appendingPathComponent("outside-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: source)
        defer { try? fm.removeItem(at: link) }

        model.resetLibrary(keepFavorites: false)
        await waitForReset()

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.currentTrackID, "A/one.sid")
        XCTAssertEqual(model.coordinator.elapsedSeconds, 12)
        XCTAssertFalse(model.coordinator.isPlaying)
        XCTAssertEqual(model.tracks, tracks)
        XCTAssertTrue(model.isFavorite("A/one.sid"))
        XCTAssertEqual(model.computedLength, 99)
        XCTAssertEqual(model.lengthCache.length(md5: md5, subtune: 0), 99)
        for key in [AppModel.Keys.lastTrackID, AppModel.Keys.lastSubtune, AppModel.Keys.lastPosition] {
            XCTAssertEqual(defaults.object(forKey: key) as? NSObject, session[key] as? NSObject)
        }
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("A/one.sid").path))
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

    // MARK: - Review-Fund 2026-08-17

    /// Der Shuffle-Sonderfall von `restoreSessionIfPossible` mit einer ECHTEN,
    /// ladbaren Bibliothek.
    ///
    /// Der bisherige Test dazu setzte die Bibliothek absichtlich leer — die
    /// Methode kehrte schon an `guard !tracks.isEmpty` zurueck und erreichte
    /// weder den Shuffle-Zweig noch die Wiederherstellung. Er waere auch nach
    /// dem Entfernen der zugesagten Sonderregel gruen geblieben.
    func testShuffleRestorePreparesARandomTrackInsteadOfTheSavedOne() async throws {
        try write("A/eins.sid", payload: [0x60, 0x01])
        try write("A/zwei.sid", payload: [0x60, 0x02])
        await importSource()
        XCTAssertEqual(model.tracks.count, 2)

        let gespeichert = try XCTUnwrap(model.tracks.first).id
        defaults.set(gespeichert, forKey: "lastTrackID")
        model.setCurrentTrackID(nil)

        // Mit Shuffle: irgendein Titel wird bereitgestellt, aber NICHT gespielt
        // und nicht zwingend der gespeicherte.
        model.shuffle = true
        model.restoreSessionIfPossible()
        let vorbereitet = try XCTUnwrap(model.currentTrackID,
                                        "Shuffle muss einen Titel bereitstellen")
        XCTAssertTrue(model.tracks.contains { $0.id == vorbereitet })
        XCTAssertFalse(model.coordinator.isPlaying, "Shuffle stellt nur bereit, es spielt nicht los")

        // Ohne Shuffle: genau der gespeicherte Titel kommt zurueck.
        model.setCurrentTrackID(nil)
        model.shuffle = false
        model.restoreSessionIfPossible()
        XCTAssertEqual(model.currentTrackID, gespeichert,
                       "Ohne Shuffle wird der gespeicherte Titel wiederhergestellt")
        XCTAssertFalse(model.coordinator.isPlaying)
    }

    // MARK: - Review-Fund 2026-08-20

    /// Der Shuffle-Zweig muss auch dann greifen, wenn die gespeicherte ID gar
    /// nicht mehr existiert.
    ///
    /// Der Test oben allein reichte nicht: Dort ist die gespeicherte ID gueltig,
    /// und die normale Wiederherstellung haette denselben Titel geladen. Entfernt
    /// jemand den Shuffle-Sonderfall, bliebe er gruen. Mit einer UNGUELTIGEN ID
    /// scheitert die normale Wiederherstellung an ihrer eigenen Pruefung — es
    /// kann also nur der Shuffle-Zweig sein, der hier noch einen Titel bereitlegt.
    func testShuffleRestoreWorksEvenWhenTheSavedTrackIsGone() async throws {
        try write("A/eins.sid", payload: [0x60, 0x01])
        try write("A/zwei.sid", payload: [0x60, 0x02])
        await importSource()

        defaults.set("Gibt/Es/Nicht.sid", forKey: "lastTrackID")
        model.setCurrentTrackID(nil)
        model.shuffle = true

        model.restoreSessionIfPossible()

        let vorbereitet = try XCTUnwrap(model.currentTrackID,
                                        "Shuffle muss auch ohne brauchbare gespeicherte ID einen Titel bereitstellen")
        XCTAssertTrue(model.tracks.contains { $0.id == vorbereitet })
        XCTAssertFalse(model.coordinator.isPlaying)
        XCTAssertEqual(defaults.string(forKey: "lastTrackID"), "Gibt/Es/Nicht.sid",
                       "Die gespeicherte Sitzung darf die Zufallsvorbereitung nicht mitbekommen")
    }

    /// Ohne frueheren Sitzungsstand darf ein Shuffle-Start auch keinen anlegen.
    ///
    /// `loadTrack` speichert die geladene ID selbst, wenn die
    /// Sitzungswiederherstellung eingeschaltet ist. Der Shuffle-Zweig legte den
    /// vorherigen Stand nur mit `if let` zurueck — war vorher gar nichts
    /// gespeichert, blieb die zufaellige ID stehen und tauchte spaeter, nach dem
    /// Ausschalten von Shuffle, als angeblich letzter Nutzungsstand wieder auf
    /// (Review-Fund 2026-08-20).
    func testShuffleStartWithoutAPreviousSessionLeavesNoSession() async throws {
        try write("A/eins.sid", payload: [0x60, 0x01])
        try write("A/zwei.sid", payload: [0x60, 0x02])
        await importSource()

        defaults.removeObject(forKey: "lastTrackID")
        defaults.removeObject(forKey: "lastSubtune")
        defaults.removeObject(forKey: "lastPosition")
        model.setCurrentTrackID(nil)
        model.shuffle = true

        model.restoreSessionIfPossible()

        XCTAssertNotNil(model.currentTrackID, "Shuffle stellt trotzdem einen Titel bereit")
        XCTAssertNil(defaults.object(forKey: "lastTrackID"),
                     "Ohne frueheren Stand darf kein Titel als Sitzung zurueckbleiben")
        XCTAssertNil(defaults.object(forKey: "lastSubtune"),
                     "Ohne frueheren Stand darf kein Subtune als Sitzung zurueckbleiben")
        XCTAssertNil(defaults.object(forKey: "lastPosition"),
                     "Ohne frueheren Stand darf keine Position als Sitzung zurueckbleiben")
    }

    // MARK: - Import von STIL und Songlaengen

    /// Review-Fund 2026-08-25: Der Kopiervorgang lief als losgelassener
    /// `Task.detached`. Zwei kurz aufeinanderfolgende Auswahlen schrieben beide
    /// dasselbe Ziel, und zuletzt gewann der LANGSAMERE — die App arbeitete
    /// danach mit einer anderen Datei als der zuletzt gewaehlten.
    func testZweiterSTILImportGewinntGegenDenErsten() async throws {
        try await assertSecondMetadataImportWins(.stil)
    }

    /// Derselbe Schutz gilt fuer die zweite Importstrecke. Ein reiner STIL-Test
    /// wuerde eine spaetere Regression in `importSonglengths` nicht bemerken.
    func testZweiterSonglengthsImportGewinntGegenDenErsten() async throws {
        try await assertSecondMetadataImportWins(.songlengths)
    }

    /// Startet den zweiten Auftrag erst, wenn der erste nachweislich im Leser
    /// wartet. Gegen die alte, unkoordinierte Implementierung schreibt der erste
    /// Auftrag nach seiner Freigabe zuletzt und dieser Test wird rot.
    private func assertSecondMetadataImportWins(_ kind: MetadataImport) async throws {
        let oldURL = source.appendingPathComponent("metadata-old.txt")
        let newURL = source.appendingPathComponent("metadata-new.txt")
        let oldText: String
        let newText: String

        switch kind {
        case .stil:
            oldText = "/MUSICIANS/A/Alt/AltesStueck.sid\nCOMMENT: Erste Auswahl.\n"
            newText = "/MUSICIANS/N/Neu/NeuesStueck.sid\nCOMMENT: Zweite Auswahl.\n"
        case .songlengths:
            oldText = "[Database]\naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=1:00\n"
            newText = "[Database]\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb=2:00\n"
        }
        try oldText.write(to: oldURL, atomically: true, encoding: .utf8)
        try newText.write(to: newURL, atomically: true, encoding: .utf8)

        let barrier = ImportReadBarrier(blockedURL: oldURL)
        model.services.importDataLoader = { url in
            try await barrier.load(url)
        }

        startMetadataImport(kind, from: oldURL)
        let firstImport = try XCTUnwrap(metadataImportTask(kind))
        guard await waitUntilImportIsBlocked(barrier) else {
            await barrier.release()
            XCTFail("Der erste Metadaten-Import erreichte die kontrollierte Lesesperre nicht.")
            return
        }

        // Jetzt ist der alte Auftrag sicher offen. Erst in diesem Zustand wird
        // die zweite Auswahl eingereicht; danach darf nur sie noch schreiben.
        startMetadataImport(kind, from: newURL)
        let secondImport = try XCTUnwrap(metadataImportTask(kind))

        // Der neue Auftrag muss den alten abbrechen und selbst ganz fertig
        // werden, waehrend der Test den ersten Leser noch festhaelt. In der
        // frueheren, unkoordinierten Fassung war genau das moeglich; erst danach
        // geben wir den alten Auftrag frei und beweisen, dass er nichts mehr
        // ueberschreibt.
        guard await waitUntilMetadataImportFinishes(kind) else {
            await barrier.release()
            await firstImport.value
            await secondImport.value
            XCTFail("Der zweite Metadaten-Import wurde nicht rechtzeitig fertig.")
            return
        }
        await barrier.release()
        await firstImport.value
        await secondImport.value
        await metadataLoadTask(kind)?.value

        let destination = try XCTUnwrap(metadataDestination(kind))
        XCTAssertEqual(try Data(contentsOf: destination), Data(newText.utf8),
                       "Auf der Platte muss exakt die zuletzt gewaehlte Datei stehen")

        switch kind {
        case .stil:
            model.setCurrentTrackID("NeuesStueck.sid")
            XCTAssertNotNil(model.currentSTILInfo,
                            "Geladen sein muss der STIL-Bestand der zweiten Auswahl")
            model.setCurrentTrackID("AltesStueck.sid")
            XCTAssertNil(model.currentSTILInfo)
        case .songlengths:
            XCTAssertEqual(model.songlengthDB?.lengths(forMD5: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
                           [120])
            XCTAssertNil(model.songlengthDB?.lengths(forMD5: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        }
    }

    private func startMetadataImport(_ kind: MetadataImport, from url: URL) {
        switch kind {
        case .stil: model.importSTIL(from: url)
        case .songlengths: model.importSonglengths(from: url)
        }
    }

    private func metadataImportTask(_ kind: MetadataImport) -> Task<Void, Never>? {
        switch kind {
        case .stil: model.services.stilImportTask
        case .songlengths: model.services.songlengthImportTask
        }
    }

    private func metadataLoadTask(_ kind: MetadataImport) -> Task<Void, Never>? {
        switch kind {
        case .stil: model.services.stilLoadTask
        case .songlengths: model.services.songlengthLoadTask
        }
    }

    private func metadataDestination(_ kind: MetadataImport) -> URL? {
        switch kind {
        case .stil: model.stilFileURL
        case .songlengths: model.songlengthsFileURL
        }
    }

    /// Begrenzt das Warten selbst. Ein XCTest-Zeitlimit koennte eine haengende
    /// Continuation nicht aufloesen und damit die ganze Suite festhalten.
    private func waitUntilImportIsBlocked(_ barrier: ImportReadBarrier,
                                          timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await barrier.isWaiting { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func waitUntilMetadataImportFinishes(_ kind: MetadataImport,
                                                 timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if metadataImportTask(kind) == nil { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
