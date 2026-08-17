import XCTest
@testable import ViciousSIDPlayerCore

/// Regressionstests zu den Funden des Nacht-Reviews vom 2026-08-17.
final class ReviewFixes20260817Tests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("vsp-review-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Ordner-Scan

    /// Eine minimale, gueltige PSID-Datei — echte SID-Dateien duerfen nicht ins
    /// Repo (Urheberrecht).
    private func writeSID(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 0x7C)
        for (index, byte) in Array("PSID".utf8).enumerated() { bytes[index] = byte }
        func putUInt16(_ value: Int, at offset: Int) {
            bytes[offset] = UInt8((value >> 8) & 0xFF)
            bytes[offset + 1] = UInt8(value & 0xFF)
        }
        putUInt16(2, at: 0x04)
        putUInt16(0x7C, at: 0x06)
        putUInt16(0x1000, at: 0x08)
        putUInt16(0x1000, at: 0x0A)
        putUInt16(0x1003, at: 0x0C)
        putUInt16(1, at: 0x0E)
        putUInt16(1, at: 0x10)
        try (Data(bytes) + Data([0x60, 0xEA])).write(to: url)
    }

    /// Ein Unterordner ohne Leserecht (0o000).
    private func makeUnreadableFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        return url
    }

    func testTeilergebnisBehaeltDieLesbarenDateien() throws {
        // Review-Fund 2026-08-17: Ein einziger unlesbarer Unterordner liess
        // auch alle bereits gefundenen, LESBAREN Titel verschwinden — die App
        // meldete dann „Keine .sid Dateien gefunden".
        try writeSID("Lesbar/eins.sid")
        try writeSID("Lesbar/zwei.sid")
        // Erst befuellen, DANN sperren — sonst laesst sich nichts hineinlegen.
        try writeSID("Gesperrt/versteckt.sid")
        let gesperrt = root.appendingPathComponent("Gesperrt", isDirectory: true)
        defer { try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: gesperrt.path) }
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: gesperrt.path)

        let ergebnis = try MusicLibrary.scanFolderAllowingPartialResults(root)

        XCTAssertEqual(ergebnis.entries.map(\.relativePath).sorted(),
                       ["Lesbar/eins.sid", "Lesbar/zwei.sid"],
                       "Die lesbaren Titel muessen erhalten bleiben")
        XCTAssertNotNil(ergebnis.traversalError,
                        "Der unlesbare Ast muss ausdruecklich gemeldet werden")

        // Der Alles-oder-nichts-Weg fuer die Bibliothek bleibt unveraendert.
        XCTAssertThrowsError(try MusicLibrary.scanFolder(root))
    }

    func testAusgeschlossenerAstScheitertNichtAmGanzenScan() throws {
        // Review-Fund 2026-08-17: Der Enumerator betrat den ausgeschlossenen
        // Ast trotzdem; ein Problem darin liess den gesamten Abgleich werfen und
        // hielt die sichtbare Bibliothek auf dem alten Indexstand fest.
        try writeSID("Musik/titel.sid")
        let inbox = try makeUnreadableFolder("Inbox")
        defer { try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: inbox.path) }

        let eintraege = try MusicLibrary.scanFolder(root, excludedFolderNames: ["Inbox"])

        XCTAssertEqual(eintraege.map(\.relativePath), ["Musik/titel.sid"])
    }

    // MARK: - Prozessor

    func testNegativerSubtuneStuerztNichtAb() throws {
        // Review-Fund 2026-08-17: `initSubtune` ist oeffentlich und speicherte
        // negative Werte unveraendert. `min(-1, 31)` ergibt wieder -1, und der
        // Zugriff auf `timermode[-1]` beendete den Prozess mit einem Index-Trap.
        let processor = ViciousProcessor(sampleRate: 44100)
        // Ohne geladene Datei tut initEmulation nichts — genau das ist hier der
        // Punkt: Der Aufruf darf unter keinen Umstaenden abstuerzen.
        processor.initSubtune(sub: -1)
        processor.initSubtune(sub: Int.min)
        processor.initSubtune(sub: Int.max)
    }
}
