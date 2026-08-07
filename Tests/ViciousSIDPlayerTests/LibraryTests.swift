import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import ViciousSIDPlayerCore

// Tests fuer die Bibliothek: Scan, Index, Import, Reset.
//
// KEINE ECHTEN SID-DATEIEN. Alles hier arbeitet mit synthetisch erzeugten
// PSID-Dateien (siehe `makeSidFixture`) in einem temporaeren Verzeichnis, das
// nach jedem Test wieder verschwindet. Echte SIDs sind copyright-geschuetzt und
// gehoeren weder ins Repo noch in einen Testlauf.
final class LibraryTests: XCTestCase {

    private let fm = FileManager.default
    /// Alles Temporaere dieses Tests haengt unter diesem einen Ordner.
    private var base: URL!
    private var root: URL!
    private var support: URL!
    private var source: URL!
    private var library: MusicLibrary!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = fm.temporaryDirectory.appendingPathComponent("vicious-library-\(UUID().uuidString)")
        root = base.appendingPathComponent("Library")
        support = base.appendingPathComponent("Support")
        source = base.appendingPathComponent("Source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        library = MusicLibrary(root: root, supportDirectory: support, fileManager: fm)
    }

    override func tearDownWithError() throws {
        library = nil
        if let base { try? fm.removeItem(at: base) }
        try super.tearDownWithError()
    }

    /// Ueberspringt einen Test, der Unlesbarkeit ueber Dateirechte herstellt,
    /// wenn der Testlauf als root laeuft.
    ///
    /// Root umgeht die Rechtebits: ein `chmod 000` bleibt fuer ihn lesbar, ein
    /// nur-lesbarer Elternordner beschreibbar. Der Test scheiterte dann nicht am
    /// Produktcode, sondern an einer Voraussetzung, die es gar nicht gibt. Genau
    /// das ist der Fall im Linux-CI: der Job laeuft im Container `swift:6.0`
    /// ohne `sudo`, also als UID 0 (Review-Fund 2026-08-07).
    private func skipIfRootIgnoresFilePermissions() throws {
        try XCTSkipIf(geteuid() == 0,
                      "Laeuft als root: Dateirechte greifen nicht, die Voraussetzung dieses Tests fehlt.")
    }

    // MARK: - Synthetische Fixtures

    /// Baut eine minimale, gueltige PSID-Datei im Speicher.
    ///
    /// Aufbau nach SID-Dateiformat (alle Zahlen big-endian):
    ///   0x00 "PSID" | 0x04 Version | 0x06 dataOffset | 0x08 loadAddress
    ///   0x0A initAddress | 0x0C playAddress | 0x0E Anzahl Subtunes
    ///   0x10 Startsubtune | 0x12 Speed-Bits | 0x16/0x36/0x56 je 32 Byte
    ///   Latin-1-Text (Titel/Autor/Freigabe) | 0x76 Flags | … bis 0x7C.
    /// Danach folgt der C64-Maschinencode; hier ein paar Fuellbytes, denn der
    /// Parser verlangt einen nicht leeren Datenblock.
    private func makeSidFixture(title: String = "Test Tune",
                                author: String = "Test Author",
                                released: String = "2026 Vicious Test",
                                subtunes: Int = 1,
                                payload: [UInt8] = [0x60, 0xEA, 0xEA, 0xEA]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x7C)

        func putUInt16(_ value: Int, at offset: Int) {
            bytes[offset] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 1] = UInt8(value & 0xFF)
        }
        // Textfelder sind 32 Byte lang und nullterminiert — deshalb hoechstens
        // 31 Zeichen uebernehmen.
        func putText(_ text: String, at offset: Int) {
            let encoded = text.data(using: .isoLatin1) ?? Data()
            for (index, byte) in encoded.prefix(31).enumerated() {
                bytes[offset + index] = byte
            }
        }

        for (index, byte) in Array("PSID".utf8).enumerated() { bytes[index] = byte }
        putUInt16(2, at: 0x04)          // Header-Version 2 (keine Multi-SID-Felder)
        putUInt16(0x7C, at: 0x06)       // Datenblock beginnt direkt hinter dem Header
        putUInt16(0x1000, at: 0x08)     // loadAddress != 0 -> Binary ohne Vorsatz
        putUInt16(0x1000, at: 0x0A)     // initAddress
        putUInt16(0x1003, at: 0x0C)     // playAddress
        putUInt16(subtunes, at: 0x0E)
        putUInt16(1, at: 0x10)          // Startsubtune
        putText(title, at: 0x16)
        putText(author, at: 0x36)
        putText(released, at: 0x56)
        putUInt16(0x0014, at: 0x76)     // Flags: bevorzugtes Modell 6581

        return Data(bytes) + Data(payload)
    }

    /// Schreibt eine Fixture unter `relativePath` in `directory` (Ordner werden
    /// bei Bedarf angelegt).
    @discardableResult
    private func writeFixture(_ relativePath: String,
                              in directory: URL,
                              title: String = "Test Tune",
                              payload: [UInt8] = [0x60, 0xEA, 0xEA, 0xEA]) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeSidFixture(title: title, payload: payload).write(to: url)
        return url
    }

    private func writeText(_ text: String, to relativePath: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Fixture selbst

    // Die Fixture muss durch den echten Parser gehen — sonst testen die
    // folgenden Tests nur sich selbst.
    func testFixtureIsAValidSidFile() throws {
        let parsed = try SidParser.parse(data: makeSidFixture(title: "Cyber Test",
                                                              author: "Jane Doe",
                                                              subtunes: 3))
        XCTAssertEqual(parsed.metadata.title, "Cyber Test")
        XCTAssertEqual(parsed.metadata.author, "Jane Doe")
        XCTAssertEqual(parsed.metadata.subtunesCount, 3)
        XCTAssertEqual(parsed.loadAddr, 0x1000)
        XCTAssertEqual(parsed.playAddr, 0x1003)
        XCTAssertFalse(parsed.binaryData.isEmpty)
    }

    // MARK: - Scan und Index

    func testScanFindsNestedFilesAndIgnoresEverythingElse() throws {
        try writeFixture("top.sid", in: root)
        try writeFixture("A/one.sid", in: root)
        try writeFixture("A/B/two.SID", in: root)          // Grossschreibung zaehlt auch
        try writeText("kein SID", to: "A/notes.txt", in: root)
        try writeFixture(".hidden.sid", in: root)          // versteckte Datei
        try writeFixture(".hiddenFolder/deep.sid", in: root) // versteckter Ordner

        let changes = try library.refresh()

        XCTAssertEqual(library.entries.map(\.relativePath),
                       ["A/B/two.SID", "A/one.sid", "top.sid"])
        XCTAssertEqual(changes.added.count, 3)
        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertEqual(library.entry(withRelativePath: "A/one.sid")?.displayName, "one")
        XCTAssertGreaterThan(library.entry(withRelativePath: "top.sid")?.fileSize ?? 0, 0x7C)
    }

    func testFolderTreeMirrorsSubdirectories() throws {
        try writeFixture("top.sid", in: root)
        try writeFixture("A/one.sid", in: root)
        try writeFixture("A/B/two.sid", in: root)
        try library.refresh()

        let tree = library.folderTree()
        XCTAssertEqual(tree.path, "")
        XCTAssertEqual(tree.entries.map(\.fileName), ["top.sid"])
        XCTAssertEqual(tree.totalEntryCount, 3)
        XCTAssertEqual(tree.subfolders.map(\.name), ["A"])

        let folderA = try XCTUnwrap(tree.subfolders.first)
        XCTAssertEqual(folderA.path, "A")
        XCTAssertEqual(folderA.entries.map(\.fileName), ["one.sid"])
        XCTAssertEqual(folderA.totalEntryCount, 2)

        let folderB = try XCTUnwrap(folderA.subfolders.first)
        XCTAssertEqual(folderB.path, "A/B")
        XCTAssertEqual(folderB.name, "B")
        XCTAssertEqual(folderB.entries.map(\.fileName), ["two.sid"])
    }

    func testMetadataIsLoadedOnDemandOnly() throws {
        try writeFixture("tune.sid", in: root, title: "Nachgeladen")
        try library.refresh()

        let entry = try XCTUnwrap(library.entry(withRelativePath: "tune.sid"))
        // Im Index steht nur der Dateiname — der Titel kommt erst auf Nachfrage.
        XCTAssertEqual(entry.displayName, "tune")
        XCTAssertEqual(try library.metadata(for: entry).title, "Nachgeladen")
        XCTAssertEqual(try library.metadata(forRelativePath: "tune.sid").author, "Test Author")
    }

    func testIndexSurvivesSaveAndLoad() throws {
        try writeFixture("A/one.sid", in: root)
        try writeFixture("top.sid", in: root)
        try library.refresh()
        XCTAssertTrue(fm.fileExists(atPath: library.indexFileURL.path))

        // Frische Instanz auf denselben Ordnern: sie muss den Index von Platte
        // lesen, ohne zu scannen.
        let reopened = MusicLibrary(root: root, supportDirectory: support, fileManager: fm)
        XCTAssertEqual(reopened.entries, library.entries)
        XCTAssertEqual(reopened.entry(withRelativePath: "A/one.sid")?.displayName, "one")
    }

    func testBrokenIndexYieldsEmptyLibraryInsteadOfCrashing() throws {
        try writeFixture("top.sid", in: root)
        try library.refresh()

        // Halb geschriebene / manuell zerschossene Datei.
        try Data("{ das ist kein JSON".utf8).write(to: library.indexFileURL)
        let reopened = MusicLibrary(root: root, supportDirectory: support, fileManager: fm)
        XCTAssertTrue(reopened.isEmpty)

        // Und der naechste Abgleich baut ihn wieder auf.
        let changes = try reopened.refresh()
        XCTAssertEqual(changes.added.map(\.relativePath), ["top.sid"])
        XCTAssertEqual(reopened.count, 1)
    }

    func testRefreshDetectsExternallyAddedAndDeletedFiles() throws {
        try writeFixture("keep.sid", in: root)
        try writeFixture("gone.sid", in: root)
        try library.refresh()

        // Genau das passiert bei der Finder-Dateifreigabe: jemand raeumt im
        // Ordner um, ohne dass die App etwas davon mitbekommt.
        try fm.removeItem(at: root.appendingPathComponent("gone.sid"))
        try writeFixture("Neu/fresh.sid", in: root)

        let changes = try library.refresh()
        XCTAssertEqual(changes.added.map(\.relativePath), ["Neu/fresh.sid"])
        XCTAssertEqual(changes.removed.map(\.relativePath), ["gone.sid"])
        XCTAssertTrue(changes.modified.isEmpty)
        XCTAssertFalse(changes.isEmpty)
        XCTAssertEqual(library.entries.map(\.relativePath), ["Neu/fresh.sid", "keep.sid"])

        // Zweiter Abgleich ohne Aenderung meldet nichts mehr.
        XCTAssertTrue(try library.refresh().isEmpty)
    }

    // MARK: - Import

    func testImportPreservesFolderStructure() async throws {
        try writeFixture("Composer/Great/one.sid", in: source)
        try writeFixture("Composer/two.sid", in: source)
        try writeFixture("three.sid", in: source)
        try writeText("Liesmich", to: "Composer/readme.txt", in: source)

        let report = try await LibraryImporter(library: library).importFolder(at: source)

        XCTAssertEqual(report.imported.sorted(),
                       ["Composer/Great/one.sid", "Composer/two.sid", "three.sid"])
        XCTAssertTrue(report.skipped.isEmpty)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertFalse(report.wasCancelled)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("Composer/Great/one.sid").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Composer/readme.txt").path))
        // Der Index kennt die neuen Dateien direkt nach dem Import.
        XCTAssertEqual(library.entries.map(\.relativePath),
                       ["Composer/Great/one.sid", "Composer/two.sid", "three.sid"])
    }

    func testImportReportsProgress() async throws {
        try writeFixture("a.sid", in: source)
        try writeFixture("b.sid", in: source)

        // Der Callback laeuft im Hintergrund-Task, deshalb ein gesperrter Sammler.
        let collector = ProgressCollector()
        _ = try await LibraryImporter(library: library).importFolder(at: source) { progress in
            collector.append(progress)
        }

        let seen = collector.values
        XCTAssertEqual(seen.first?.completed, 0)
        XCTAssertEqual(seen.first?.total, 2)
        XCTAssertEqual(seen.first?.currentFileName, "a.sid")
        XCTAssertEqual(seen.last?.completed, 2)
        XCTAssertEqual(seen.last?.fraction, 1.0)
    }

    func testImportSkipsIdenticalDuplicatesOnSecondRun() async throws {
        try writeFixture("Composer/one.sid", in: source)
        try writeFixture("two.sid", in: source)

        let importer = LibraryImporter(library: library)
        _ = try await importer.importFolder(at: source)
        let second = try await importer.importFolder(at: source)

        XCTAssertTrue(second.imported.isEmpty)
        XCTAssertEqual(second.skipped.map(\.sourceRelativePath).sorted(), ["Composer/one.sid", "two.sid"])
        XCTAssertEqual(second.skipped.map(\.reason), [.duplicate, .duplicate])
        // Keine "-2"-Kopien entstanden.
        XCTAssertEqual(library.count, 2)
    }

    func testImportRenamesOnNameCollisionWithDifferentContent() async throws {
        try writeFixture("tune.sid", in: source, title: "Erste Fassung", payload: [0x60, 0x01])
        let importer = LibraryImporter(library: library)
        _ = try await importer.importFolder(at: source)

        // Gleicher Name, anderer Inhalt: darf die vorhandene Datei NICHT ueberschreiben.
        try writeFixture("tune.sid", in: source, title: "Zweite Fassung", payload: [0x60, 0x02])
        let second = try await importer.importFolder(at: source)

        XCTAssertEqual(second.imported, ["tune-2.sid"])
        XCTAssertEqual(try library.metadata(forRelativePath: "tune.sid").title, "Erste Fassung")
        XCTAssertEqual(try library.metadata(forRelativePath: "tune-2.sid").title, "Zweite Fassung")
        XCTAssertEqual(library.count, 2)

        // Derselbe Inhalt ein drittes Mal: jetzt ist er als "tune-2.sid" bereits
        // da und wird uebersprungen, statt "tune-3.sid" anzulegen.
        let third = try await importer.importFolder(at: source)
        XCTAssertTrue(third.imported.isEmpty)
        XCTAssertEqual(third.skipped.count, 1)
        XCTAssertEqual(library.count, 2)
    }

    func testImportCollectsPerFileFailuresWithoutStopping() async throws {
        try skipIfRootIgnoresFilePermissions()
        try writeFixture("a.sid", in: source)
        try writeFixture("locked.sid", in: source)
        try writeFixture("z.sid", in: source)

        // Datei unlesbar machen. Im Teardown wieder freigeben, sonst laesst sich
        // das temporaere Verzeichnis nicht aufraeumen.
        let lockedPath = source.appendingPathComponent("locked.sid").path
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedPath)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedPath)
        }

        let report = try await LibraryImporter(library: library).importFolder(at: source)

        XCTAssertEqual(report.imported.sorted(), ["a.sid", "z.sid"])
        XCTAssertEqual(report.failed.map(\.sourceRelativePath), ["locked.sid"])
        XCTAssertFalse(report.wasCancelled)
        // Die uebrigen Dateien sind vollstaendig da — ein Fehler bricht nichts ab.
        XCTAssertEqual(library.entries.map(\.relativePath), ["a.sid", "z.sid"])
    }

    func testImportCancellationLeavesConsistentState() async throws {
        for index in 0..<8 {
            try writeFixture(String(format: "tune-%02d.sid", index), in: source, payload: [0x60, UInt8(index)])
        }

        // Deterministischer Abbruch: der Fortschritts-Callback haelt den Import
        // an, sobald drei Dateien fertig sind. Erst dann bricht der Test den Task
        // ab und laesst ihn weiterlaufen. Ohne dieses Handshaking waere der Test
        // ein Wettrennen zwischen Abbruch und Importende.
        let gate = ImportGate()
        let importer = LibraryImporter(library: library)
        let sourceFolder = source!

        let task = Task {
            try await importer.importFolder(at: sourceFolder) { progress in
                if progress.completed == 3 { gate.pause() }
            }
        }

        // Auf das Erreichen warten, ohne den Testthread zu blockieren.
        var waited = 0
        while !gate.hasPaused && waited < 3000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertTrue(gate.hasPaused, "Import hat die Abbruchstelle nie erreicht")
        task.cancel()
        gate.resume()

        let report = try await task.value
        XCTAssertTrue(report.wasCancelled)
        XCTAssertGreaterThanOrEqual(report.imported.count, 1)
        XCTAssertLessThan(report.imported.count, 8)

        // Kein Bruchstueck: jede gemeldete Datei liegt vollstaendig und parsebar
        // in der Bibliothek, und der Index deckt sich exakt mit der Platte.
        for relativePath in report.imported {
            let data = try Data(contentsOf: library.url(forRelativePath: relativePath))
            XCTAssertNoThrow(try SidParser.parse(data: data))
        }
        XCTAssertEqual(library.entries.map(\.relativePath).sorted(), report.imported.sorted())
        XCTAssertTrue(try library.refresh().isEmpty)
    }

    func testImportFilesLandsFlatInTheRoot() async throws {
        let first = try writeFixture("Tief/verschachtelt/a.sid", in: source)
        let second = try writeFixture("b.sid", in: source)
        try writeText("egal", to: "c.txt", in: source)
        let ignored = source.appendingPathComponent("c.txt")

        let report = try await LibraryImporter(library: library).importFiles([first, second, ignored])

        XCTAssertEqual(report.imported.sorted(), ["a.sid", "b.sid"])
        XCTAssertEqual(library.entries.map(\.relativePath), ["a.sid", "b.sid"])
    }

    // MARK: - Nebenlaeufige Refreshes

    // Regression: App-Reload und Importer rufen refresh() aus verschiedenen
    // Hintergrund-Tasks. Ein FRUEHER gestarteter, aber SPAETER fertig werdender
    // Durchlauf darf den Index eines dazwischen gelaufenen, neueren nicht
    // ueberschreiben. Der `GatedFileManager` haelt Durchlauf A zwischen Scan und
    // Speichern an, damit der Test dieses Fenster deterministisch trifft.
    func testStaleRefreshCannotOverwriteNewerRefresh() async throws {
        let gatedFM = GatedFileManager()
        let gatedRoot = base.appendingPathComponent("GatedLibrary")
        let gatedSupport = base.appendingPathComponent("GatedSupport")
        let gatedLibrary = MusicLibrary(root: gatedRoot, supportDirectory: gatedSupport, fileManager: gatedFM)
        try writeFixture("old.sid", in: gatedRoot)
        // Erst jetzt scharf schalten — die Initialisierung oben legt selbst
        // Verzeichnisse an und soll nicht schon haengen bleiben.
        gatedFM.arm()

        // Durchlauf A: liest den alten Stand und haelt vor dem Speichern an.
        let first = Task.detached { try gatedLibrary.refresh() }
        try await waitUntil("Durchlauf A hat den Haltepunkt nie erreicht.") { gatedFM.hasPaused }

        // Waehrend A haengt, aendert sich die Welt: alte Datei weg, neue da.
        try fm.removeItem(at: gatedRoot.appendingPathComponent("old.sid"))
        try writeFixture("new.sid", in: gatedRoot)

        // Durchlauf B startet jetzt. Ist refresh() serialisiert, wartet er am
        // Anfang und kommt bis zum Speichern gar nicht durch; ohne
        // Serialisierung liefe er sofort komplett durch.
        let second = Task.detached { try gatedLibrary.refresh() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(gatedFM.arrivalsAfterGate, 0,
                       "Durchlauf B hat mitten in Durchlauf A gespeichert.")

        gatedFM.release()
        _ = try await first.value
        _ = try await second.value

        // Der neuere Stand gewinnt — im Speicher UND auf Platte.
        XCTAssertEqual(gatedLibrary.entries.map(\.relativePath), ["new.sid"])
        let reopened = MusicLibrary(root: gatedRoot, supportDirectory: gatedSupport, fileManager: fm)
        XCTAssertEqual(reopened.entries.map(\.relativePath), ["new.sid"],
                       "Der gespeicherte Index traegt den veralteten Stand.")
    }

    // Ein unlesbarer Ast darf den Index NICHT durch ein halbes Ergebnis
    // ersetzen: sonst verschwinden vorhandene Titel aus Ansicht und Index und
    // gelten als von aussen geloescht (Review-Fund 2026-08-07).
    func testScanThrowsInsteadOfReportingAnIncompleteLibrary() throws {
        try skipIfRootIgnoresFilePermissions()
        try writeFixture("one.sid", in: root)
        try writeFixture("Sub/two.sid", in: root)
        try library.refresh()
        XCTAssertEqual(library.count, 2)

        let blockedPath = root.appendingPathComponent("Sub").path
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blockedPath)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedPath)
        }

        XCTAssertThrowsError(try library.scan())
        XCTAssertThrowsError(try library.refresh())
        // Fail-closed: der zuletzt gueltige Stand bleibt stehen.
        XCTAssertEqual(library.count, 2, "Ein gescheiterter Scan hat den Index geleert.")
    }

    // Die System-Inbox liegt auf iOS mitten in der Bibliothekswurzel. Was dort
    // liegt, ist Zwischenablage und darf nicht als regulaerer Titel erscheinen.
    func testScanSkipsExcludedTopLevelFolders() throws {
        let inboxRoot = base.appendingPathComponent("InboxLibrary")
        let inboxSupport = base.appendingPathComponent("InboxSupport")
        let inboxLibrary = MusicLibrary(root: inboxRoot,
                                        supportDirectory: inboxSupport,
                                        fileManager: fm,
                                        excludedFolderNames: [MusicLibraryLocation.inboxFolderName])
        try writeFixture("real.sid", in: inboxRoot)
        try writeFixture("Inbox/airdrop.sid", in: inboxRoot)
        // Gleicher Name TIEFER im Baum bleibt normaler Nutzerinhalt.
        try writeFixture("Composer/Inbox/deep.sid", in: inboxRoot)

        try inboxLibrary.refresh()

        XCTAssertEqual(inboxLibrary.entries.map(\.relativePath),
                       ["Composer/Inbox/deep.sid", "real.sid"])
    }

    // MARK: - Fehlerpfade des Imports

    // Ein Unterordner, den der Enumerator nicht betreten kann, darf nicht
    // stillschweigend fehlen — er muss als Fehler im Bericht stehen.
    func testImportReportsUnreadableSubtreeInsteadOfSilentlySkippingIt() async throws {
        try skipIfRootIgnoresFilePermissions()
        try writeFixture("ok/one.sid", in: source)
        try writeFixture("blocked/two.sid", in: source)

        let blockedPath = source.appendingPathComponent("blocked").path
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blockedPath)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedPath)
        }

        let report = try await LibraryImporter(library: library).importFolder(at: source)

        XCTAssertEqual(report.imported, ["ok/one.sid"], "Der lesbare Teil muss durchlaufen.")
        XCTAssertEqual(report.failed.map(\.sourceRelativePath), ["blocked"])
        XCTAssertEqual(report.failed.map(\.reason), [.unreadable])
        XCTAssertFalse(report.wasCancelled)
    }

    // Ist die QUELLWURZEL selbst unlesbar, konnte kein einziger Auftrag
    // entstehen. Das ist der dokumentierte Gesamtfehler und nicht ein
    // abgeschlossener Import mit einem Einzelfehler (Review-Fund 2026-08-07).
    func testImportThrowsWhenSourceFolderItselfIsUnreadable() async throws {
        try skipIfRootIgnoresFilePermissions()
        try writeFixture("one.sid", in: source)

        let sourcePath = source.path
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: sourcePath)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sourcePath)
        }

        do {
            _ = try await LibraryImporter(library: library).importFolder(at: source)
            XCTFail("Eine unlesbare Quellwurzel muss den Gesamtfehler werfen.")
        } catch let error as LibraryImportError {
            guard case .sourceUnreadable = error else {
                return XCTFail("Falscher Fehler: \(error)")
            }
        }
    }

    // Der Fortschritt ist ein oeffentlicher Vertrag: Traversierungsfehler
    // gehoeren zu keinem Auftrag und duerfen den Zaehler nicht ueber den Nenner
    // treiben ("8/7" — Review-Fund 2026-08-07).
    func testProgressCompletedNeverExceedsTotal() async throws {
        try skipIfRootIgnoresFilePermissions()
        try writeFixture("ok/one.sid", in: source)
        try writeFixture("blocked/two.sid", in: source)

        let blockedPath = source.appendingPathComponent("blocked").path
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blockedPath)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedPath)
        }

        let progress = ProgressCollector()
        _ = try await LibraryImporter(library: library).importFolder(at: source) { step in
            progress.append(step)
        }

        let steps = progress.values
        XCTAssertEqual(steps.last?.completed, 1)
        XCTAssertEqual(steps.last?.total, 1)
        XCTAssertFalse(steps.contains { $0.completed > $0.total },
                       "Der Fortschritt hat mehr erledigte als vorhandene Auftraege gemeldet.")
    }

    // Ohne `LocalizedError` zeigte die Oberflaeche nur die generische
    // NSError-Bruecke statt des Grundes (Review-Fund 2026-08-07).
    func testImportErrorsCarryReadableDescriptions() {
        let source = LibraryImportError.sourceUnreadable("Sammlung")
        XCTAssertTrue(source.localizedDescription.contains("Sammlung"),
                      "Meldung ohne Ordnernamen: \(source.localizedDescription)")

        let destination = LibraryImportError.destinationUnavailable("Kein Platz auf dem Gerät")
        XCTAssertTrue(destination.localizedDescription.contains("Kein Platz auf dem Gerät"),
                      "Meldung ohne Klartext: \(destination.localizedDescription)")
    }

    // Fehlt die Bibliothekswurzel und laesst sie sich nicht anlegen, ist der
    // dokumentierte Gesamtfehler faellig — nicht ein "Erfolg" voller copyFailed.
    func testImportThrowsWhenLibraryRootCannotBeCreated() async throws {
        try skipIfRootIgnoresFilePermissions()
        let lockedParent = base.appendingPathComponent("LockedParent")
        let lockedRoot = lockedParent.appendingPathComponent("Library")
        let lockedSupport = base.appendingPathComponent("LockedSupport")
        // Der Initializer legt beide Ordner an; danach Wurzel entfernen und den
        // Elternordner schreibschuetzen, damit sie sich nicht neu anlegen laesst.
        let lockedLibrary = MusicLibrary(root: lockedRoot, supportDirectory: lockedSupport, fileManager: fm)
        try writeFixture("a.sid", in: source)
        try fm.removeItem(at: lockedRoot)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedParent.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedParent.path)
        }

        do {
            _ = try await LibraryImporter(library: lockedLibrary).importFolder(at: source)
            XCTFail("Ohne erreichbare Wurzel muss der Import werfen.")
        } catch let error as LibraryImportError {
            guard case .destinationUnavailable = error else {
                return XCTFail("Falscher Fehler: \(error)")
            }
        }
    }

    // Abbruch WAEHREND der Zaehlphase: die Enumeration grosser Quellbaeume muss
    // den Task-Abbruch bemerken, statt erst nach vollstaendigem Durchlauf zu
    // reagieren — und liefert dann den normalen abgebrochenen Bericht.
    func testCancellationDuringEnumerationStopsBeforeCopying() async throws {
        // Mehr als 256 Dateien, denn genau alle 256 Eintraege prueft die
        // Enumeration den Abbruchzustand.
        for index in 0..<300 {
            try writeFixture(String(format: "bulk-%03d.sid", index), in: source, payload: [0x60, UInt8(index % 251)])
        }

        let cancelledRoot = base.appendingPathComponent("CancelledLibrary")
        let cancelledSupport = base.appendingPathComponent("CancelledSupport")
        let cancelledLibrary = MusicLibrary(root: cancelledRoot,
                                            supportDirectory: cancelledSupport,
                                            fileManager: fm)
        let importer = LibraryImporter(library: cancelledLibrary)
        let sourceFolder = source!

        // Deterministisch: der Import startet erst, wenn der Task schon
        // abgebrochen ist — die Enumeration laeuft dann auf einem
        // gecancelten Task.
        let task = Task { () -> LibraryImportReport in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return try await importer.importFolder(at: sourceFolder)
        }
        task.cancel()
        let report = try await task.value

        XCTAssertTrue(report.wasCancelled)
        XCTAssertTrue(report.imported.isEmpty)
        // Beweis, dass schon die ZAEHLPHASE ausgestiegen ist: die Kopierphase
        // gleicht zum Schluss immer den Index ab und schreibt ihn dabei auf
        // Platte. Ohne die Abbruchpruefung in der Enumeration liefe sie an —
        // die Indexdatei gaebe es dann.
        XCTAssertFalse(fm.fileExists(atPath: cancelledLibrary.indexFileURL.path),
                       "Der Import ist bis in die Kopierphase gelaufen, statt beim Zaehlen abzubrechen.")
    }

    // MARK: - Reset

    // Ein Berechtigungs-/Dateisystemfehler beim Auflisten der Wurzel darf NICHT
    // wie eine leere Bibliothek aussehen: sonst meldet der Reset Erfolg,
    // loescht Index und Cache, und die Musikdateien bleiben liegen.
    func testResetThrowsWhenRootContentsCannotBeListed() throws {
        try skipIfRootIgnoresFilePermissions()
        try writeFixture("one.sid", in: root)
        try library.refresh()
        XCTAssertTrue(fm.fileExists(atPath: library.indexFileURL.path))

        // Pfad vorher festhalten: der Teardown-Block laeuft, wenn `root` schon
        // aufgeraeumt ist, und darf den Test nicht mehr festhalten.
        let rootPath = root.path
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: rootPath)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootPath)
        }

        XCTAssertThrowsError(try LibraryReset.run(library: library))

        // Fail-closed: nichts wurde halb weggeraeumt.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertTrue(fm.fileExists(atPath: library.indexFileURL.path),
                      "Der Index darf bei einem gescheiterten Reset nicht verschwinden.")
        XCTAssertFalse(library.isEmpty,
                       "Der In-Memory-Index darf bei einem gescheiterten Reset nicht geleert werden.")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("one.sid").path))
    }

    // Laesst sich die Wurzel nach dem Loeschen nicht wieder anlegen, darf der
    // Reset keinen Erfolg melden: die Bibliothek haette danach kein
    // beschreibbares Ziel mehr (Review-Fund 2026-08-07).
    func testResetThrowsWhenRootCannotBeRecreated() throws {
        try skipIfRootIgnoresFilePermissions()
        let lockedParent = base.appendingPathComponent("LockedParent")
        let lockedRoot = lockedParent.appendingPathComponent("Library")
        let lockedSupport = base.appendingPathComponent("LockedSupport")
        let lockedLibrary = MusicLibrary(root: lockedRoot,
                                         supportDirectory: lockedSupport,
                                         fileManager: fm)
        try writeFixture("one.sid", in: lockedRoot)
        try lockedLibrary.refresh()
        XCTAssertTrue(fm.fileExists(atPath: lockedLibrary.indexFileURL.path))

        // Wurzel entfernen und den Elternordner schreibschuetzen: Schritt 1 des
        // Resets sieht eine fehlende Wurzel (kein Fehler), Schritt 2 kann sie
        // aber nicht neu anlegen.
        try fm.removeItem(at: lockedRoot)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedParent.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedParent.path)
        }

        XCTAssertThrowsError(try LibraryReset.run(library: lockedLibrary))
        XCTAssertTrue(fm.fileExists(atPath: lockedLibrary.indexFileURL.path),
                      "Der Index darf bei einem gescheiterten Reset nicht verschwinden.")
    }

    // Eine FEHLENDE Wurzel ist dagegen kein Fehler: nichts zu loeschen,
    // Wurzel wird wieder angelegt (Idempotenz).
    func testResetTreatsMissingRootAsEmpty() throws {
        try fm.removeItem(at: root)

        let report = try LibraryReset.run(library: library)

        XCTAssertEqual(report.removedFiles, 0)
        XCTAssertEqual(report.removedTopLevelItems, 0)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue, "Die Wurzel muss nach dem Reset wieder existieren.")
    }

    func testResetIsIdempotentAndAllowsReimport() async throws {
        try writeFixture("Composer/one.sid", in: source)
        try writeFixture("two.sid", in: source)
        let importer = LibraryImporter(library: library)
        _ = try await importer.importFolder(at: source)

        // Berechneten Songlaengen-Cache vortaeuschen, damit der Reset ihn
        // nachweislich mitnimmt.
        let cache = support.appendingPathComponent(LibraryReset.cacheFileNames[0])
        try Data("{}".utf8).write(to: cache)

        let report = try LibraryReset.run(library: library)
        XCTAssertEqual(report.removedFiles, 2)
        XCTAssertEqual(report.removedTopLevelItems, 2)     // "Composer" und "two.sid"
        XCTAssertEqual(report.removedSupportFiles.sorted(),
                       [LibraryReset.cacheFileNames[0], MusicLibrary.indexFileName].sorted())
        XCTAssertFalse(report.favoritesCleared)
        XCTAssertFalse(report.isEmpty)

        // Die Wurzel selbst bleibt bestehen (auf iOS ist das `Documents/`).
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fm.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path), [])
        XCTAssertTrue(library.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: library.indexFileURL.path))
        XCTAssertFalse(fm.fileExists(atPath: cache.path))

        // Zweiter Aufruf auf leerem Stand: kein Fehler, nichts mehr zu tun.
        let again = try LibraryReset.run(library: library)
        XCTAssertTrue(again.isEmpty)

        // Und danach laesst sich wieder importieren.
        let reimport = try await importer.importFolder(at: source)
        XCTAssertEqual(reimport.imported.sorted(), ["Composer/one.sid", "two.sid"])
        XCTAssertEqual(library.count, 2)
    }

    func testResetClearsFavoritesOnlyWhenAsked() throws {
        let cleared = FlagBox()
        _ = try LibraryReset.run(library: library)
        XCTAssertFalse(cleared.value)

        let report = try LibraryReset.run(library: library) { cleared.value = true }
        XCTAssertTrue(cleared.value)
        XCTAssertTrue(report.favoritesCleared)
    }

    func testResetNeverDeletesOutsideTheRoot() throws {
        // Nachbarordner mit gemeinsamem Namensanfang — der klassische Fall, bei
        // dem ein simpler Praefix-Vergleich ("Library" ist Praefix von
        // "Library2") die falsche Antwort gibt.
        let sibling = base.appendingPathComponent("Library2")
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        let outsideFile = sibling.appendingPathComponent("fremd.sid")
        try makeSidFixture().write(to: outsideFile)

        XCTAssertThrowsError(try LibraryReset.remove(outsideFile, under: root, fm: fm)) { error in
            guard case LibraryReset.ResetError.outsideRoot = error else {
                return XCTFail("Falscher Fehlertyp: \(error)")
            }
        }
        XCTAssertTrue(fm.fileExists(atPath: outsideFile.path), "Fremde Datei muss unangetastet bleiben")

        // Die Wurzel selbst darf nie geloescht werden.
        XCTAssertFalse(LibraryReset.isContained(root, in: root))
        XCTAssertThrowsError(try LibraryReset.remove(root, under: root, fm: fm))
        XCTAssertTrue(fm.fileExists(atPath: root.path))

        // Ausbruchsversuch ueber "..".
        XCTAssertFalse(LibraryReset.isContained(root.appendingPathComponent("../Library2/fremd.sid"), in: root))
        XCTAssertFalse(LibraryReset.isContained(sibling, in: root))
        // Was wirklich drin liegt, wird korrekt erkannt — auch wenn es die Datei
        // noch gar nicht gibt.
        XCTAssertTrue(LibraryReset.isContained(root.appendingPathComponent("A/tief/x.sid"), in: root))
    }

    // MARK: - Kleine Helfer

    /// Wartet, bis `condition` zutrifft (hoechstens `timeout` Sekunden), ohne
    /// den Testthread zu blockieren. Schlaegt sonst mit `message` fehl.
    private func waitUntil(_ message: String,
                           timeout: TimeInterval = 10,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(message, file: file, line: line)
    }

    /// FileManager, der den ersten Speichervorgang nach `arm()` anhaelt.
    ///
    /// Haltepunkt ist `createDirectory`, weil `MusicLibrary.refresh()` genau
    /// dort zwischen Scan und Schreiben vorbeikommt: `saveIndex()` legt zuerst
    /// Wurzel und Support-Ordner an und schreibt danach die Indexdatei. Der
    /// Verzeichnis-Enumerator waere der naheliegendere Ort, laesst sich aber
    /// nicht abfangen — `FileManager.enumerator(at:…)` ist in einer
    /// Swift-Erweiterung deklariert und deshalb nicht ueberschreibbar.
    private final class GatedFileManager: FileManager, @unchecked Sendable {
        private let stateLock = NSLock()
        private let proceed = DispatchSemaphore(value: 0)
        private var isArmed = false
        private var didGate = false
        private var paused = false
        private var otherArrivals = 0

        /// Steht ein Aufrufer am Haltepunkt?
        var hasPaused: Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return paused
        }

        /// Wie viele NICHT angehaltene Aufrufer kamen seit `arm()` vorbei?
        var arrivalsAfterGate: Int {
            stateLock.lock()
            defer { stateLock.unlock() }
            return otherArrivals
        }

        /// Scharf schalten. Erst nach dem Anlegen der Bibliothek aufrufen.
        func arm() {
            stateLock.lock()
            isArmed = true
            stateLock.unlock()
        }

        /// Aus dem Test heraus: den angehaltenen Aufrufer weiterlaufen lassen.
        func release() { proceed.signal() }

        override func createDirectory(at url: URL,
                                      withIntermediateDirectories createIntermediates: Bool,
                                      attributes: [FileAttributeKey: Any]? = nil) throws {
            stateLock.lock()
            let armed = isArmed
            let shouldGate = armed && !didGate
            if shouldGate {
                didGate = true
                paused = true
            } else if armed {
                otherArrivals += 1
            }
            stateLock.unlock()

            if shouldGate { proceed.wait() }
            try super.createDirectory(at: url,
                                      withIntermediateDirectories: createIntermediates,
                                      attributes: attributes)
        }
    }

    /// Handshake fuer den Abbruchtest: der Fortschritts-Callback (synchron, im
    /// Hintergrund-Task) haelt hier an, der Test merkt das und laesst ihn nach
    /// dem Abbruch weiterlaufen.
    private final class ImportGate: @unchecked Sendable {
        private let lock = NSLock()
        private var paused = false
        private let proceed = DispatchSemaphore(value: 0)

        var hasPaused: Bool {
            lock.lock()
            defer { lock.unlock() }
            return paused
        }

        /// Aus dem Callback heraus: melden und warten.
        func pause() {
            lock.lock()
            paused = true
            lock.unlock()
            proceed.wait()
        }

        /// Aus dem Test heraus: weiterlaufen lassen.
        func resume() { proceed.signal() }
    }

    /// Sammelt Fortschrittsmeldungen threadsicher ein — der Callback laeuft
    /// ausdruecklich nicht auf dem Main-Actor.
    private final class ProgressCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [LibraryImportProgress] = []

        func append(_ progress: LibraryImportProgress) {
            lock.lock()
            storage.append(progress)
            lock.unlock()
        }

        var values: [LibraryImportProgress] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); storage = newValue; lock.unlock() }
        }
    }
}
