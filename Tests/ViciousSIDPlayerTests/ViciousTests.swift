import XCTest
@testable import ViciousSIDPlayerCore

final class ViciousTests: XCTestCase {
    func testViciousSynthesis() throws {
        // 1. Test-SID lokalisieren. Die Datei ist copyright-geschuetzt und liegt
        //    NICHT im Repo, sondern in der persoenlichen Sammlung unter
        //    ~/Music/Vicious SID Player/. Fehlt sie (frischer Checkout / CI), wird
        //    dieser Synthese-Smoke-Test uebersprungen statt fehlzuschlagen.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sidURL = home.appendingPathComponent("Music/Vicious SID Player/Cybernoid.sid")

        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: sidURL.path),
            "Test-SID nicht gefunden (\(sidURL.path)) — Synthese-Smoke-Test uebersprungen."
        )

        // 2. Parse the SID file
        let data = try Data(contentsOf: sidURL)
        let sidFile = try SidParser.parse(data: data)
        
        XCTAssertEqual(sidFile.metadata.title, "Cybernoid")
        XCTAssertEqual(sidFile.metadata.author, "Jeroen Tel")
        
        // 3. Initialize processor
        print("DEBUG parser: loadAddr = \(String(format: "0x%04X", sidFile.loadAddr)), initAddr = \(String(format: "0x%04X", sidFile.initAddr)), playAddr = \(String(format: "0x%04X", sidFile.playAddr))")
        print("DEBUG parser: binaryData count = \(sidFile.binaryData.count), first 16 bytes: \(sidFile.binaryData.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")
        let processor = ViciousProcessor(sampleRate: 44100.0)
        _ = processor.loadSID(sidFile: sidFile)
        
        // 4. Initialize subtune
        processor.initSubtune(sub: 0)
        processor.setVolume(vol: 1.0)
        
        // 5. Synthesize 5 seconds of audio to verify oscillation and timing
        var nonZeroCount = 0
        let totalSamples = 44100 * 5
        var maxSample: Double = 0.0
        var minSample: Double = 0.0
        
        for _ in 0..<totalSamples {
            let sample = processor.play()
            if abs(sample) > 0.000001 {
                nonZeroCount += 1
            }
            maxSample = max(maxSample, sample)
            minSample = min(minSample, sample)
        }
        
        let liveData = processor.getChannelsData()
        print("DEBUG final live channels data: envelopes=\(liveData.envelopes), frequencies=\(liveData.frequencies), gates=\(liveData.gates), waveforms=\(liveData.waveforms), pulsewidths=\(liveData.pulsewidths)")
        print("Test Synthesis Results: non-zero samples = \(nonZeroCount) / \(totalSamples), min = \(minSample), max = \(maxSample)")
        
        // Cybernoid should not be completely silent!
        XCTAssertGreaterThan(nonZeroCount, 1000, "Audio should oscillate and not be silent")
        
        // 6. Test Seek logic
        processor.seek(seconds: 10.0)
        let sampleAfterSeek = processor.play()
        print("Sample after seek: \(sampleAfterSeek)")
        
        // 7. Test Subtune changing
        processor.initSubtune(sub: 1)
        let sampleSubtune1 = processor.play()
        print("Sample subtune 1: \(sampleSubtune1)")
    }

    // Regression: Drag & Drop einer .sid-Datei aus dem Finder tat nichts, weil der
    // gelieferte "public.file-url"-Data-Eintrag (eine file://-URL) faelschlich an
    // URL(fileURLWithPath:) ging und so ans cwd gehaengt wurde. Erwartet: der
    // urspruengliche Pfad wird korrekt rekonstruiert.
    func testDropURLDecodeFromData() throws {
        let path = "/Users/test/Music/C64Music/GAMES/A-F/Asteroids.sid"
        // So liefert NSItemProvider den Finder-Drop aus: die file://-URL als Data.
        let data = URL(fileURLWithPath: path).dataRepresentation

        let decoded = DropURLDecoder.url(fromItem: data)
        XCTAssertEqual(decoded?.path, path, "Data-Eintrag muss zum Originalpfad zurueckfuehren")
    }

    func testDropURLDecodeFromURLAndString() throws {
        let path = "/Users/test/Music/Cybernoid.sid"
        let url = URL(fileURLWithPath: path)

        // Eintrag kommt direkt als URL
        XCTAssertEqual(DropURLDecoder.url(fromItem: url)?.path, path)
        // Eintrag kommt als URL-String (file://...) — muss per URL(string:) geparst werden
        XCTAssertEqual(DropURLDecoder.url(fromItem: url.absoluteString)?.path, path)
        // Unbekannter Typ -> nil
        XCTAssertNil(DropURLDecoder.url(fromItem: 42))
    }

    // Regression: Tunes mit mehr als 32 Subtunes crashten beim Abspielen von
    // Subtune >= 32 mit "Index out of range", weil timermode[subtune] auf ein
    // 32-Eintrag-Array zugriff (72 HVSC-Dateien betroffen). PSID-Spec: Subtune
    // 33+ nutzen das Flag von Subtune 32 -> Index muss begrenzt werden.
    //
    // Baut ein minimales synthetisches PSID mit 40 Subtunes: Init-/Play-Routine
    // ist ein einzelnes RTS (0x60); da initCPU SP=0xFF setzt, bricht der RTS-
    // Handler (SP>=0xFF -> 0xFE) die Init-Schleife sofort ab und erreicht direkt
    // die fragliche timermode-Indizierung.
    func testHighSubtuneCountDoesNotCrash() throws {
        var bytes = [UInt8](repeating: 0, count: 0x7C)
        bytes[0] = 0x50; bytes[1] = 0x53; bytes[2] = 0x49; bytes[3] = 0x44 // "PSID"
        bytes[5] = 0x02                 // Version 2
        bytes[7] = 0x7C                 // dataOffset = 0x7C
        // loadAddr 0x0000 (aus den Datenbytes) -> bytes 8/9 bleiben 0
        bytes[10] = 0x10                // initAddr = 0x1000
        bytes[12] = 0x10                // playAddr = 0x1000
        bytes[15] = 40                  // songs = 40 (> 32)
        bytes[17] = 0x01                // startSong = 1
        // Datenblock: Ladeadresse 0x1000 little-endian + RTS-Opcode
        bytes += [0x00, 0x10, 0x60]
        let data = Data(bytes)

        let sid = try SidParser.parse(data: data)
        XCTAssertEqual(sid.subtuneAmount, 40)
        XCTAssertEqual(sid.timermodes.count, 32)

        let processor = ViciousProcessor(sampleRate: 44100.0)
        _ = processor.loadSID(sidFile: sid)
        // Subtune 39 (> 31): wuerde ohne Index-Begrenzung crashen.
        processor.initSubtune(sub: 39)
        processor.setVolume(vol: 1.0)
        for _ in 0..<1000 { _ = processor.play() }
        // Kein Crash == bestanden.
    }

    // Regression: Umlaute in den Header-Feldern wurden als Ersatzzeichen
    // angezeigt ("C.H�lsbeck" statt "C.Hülsbeck"), weil die 32-Byte-Felder
    // Title/Author/Released als UTF-8 dekodiert wurden. Laut SID-Spec sind
    // sie ISO 8859-1 (Latin-1): das Byte 0xFC muss als "ü" ankommen.
    func testHeaderStringsDecodeAsLatin1() throws {
        var bytes = [UInt8](repeating: 0, count: 0x7C)
        bytes[0] = 0x50; bytes[1] = 0x53; bytes[2] = 0x49; bytes[3] = 0x44 // "PSID"
        bytes[5] = 0x02                 // Version 2
        bytes[7] = 0x7C                 // dataOffset = 0x7C
        bytes[10] = 0x10                // initAddr = 0x1000
        bytes[12] = 0x10                // playAddr = 0x1000
        bytes[15] = 1                   // songs = 1
        bytes[17] = 0x01                // startSong = 1
        // Author-Feld (0x36, 32 Bytes, null-terminiert): "C.Hülsbeck",
        // wobei "ü" das Latin-1-Byte 0xFC ist (in UTF-8 waere das ungueltig).
        let author: [UInt8] = [0x43, 0x2E, 0x48, 0xFC, 0x6C, 0x73, 0x62, 0x65, 0x63, 0x6B]
        for (i, b) in author.enumerated() { bytes[0x36 + i] = b }
        // Datenblock: Ladeadresse 0x1000 little-endian + RTS-Opcode
        bytes += [0x00, 0x10, 0x60]

        let sid = try SidParser.parse(data: Data(bytes))
        XCTAssertEqual(sid.metadata.author, "C.Hülsbeck")
    }

    // Regression: Bei explizitem loadAddress im Header (Feld != 0) beginnt der
    // Datenblock laut SID-Spec DIREKT mit dem C64-Binary — es gibt dann KEINE
    // eingebettete 2-Byte-Ladeadresse. Der Parser hat frueher immer 2 Bytes
    // uebersprungen, wodurch solche Dateien (z.B. "BotB 23584 Pegmode - Aiya!")
    // um 2 verschoben geladen wurden und stumm blieben.
    func testExplicitLoadAddressKeepsFirstTwoBinaryBytes() throws {
        var bytes = [UInt8](repeating: 0, count: 0x7C)
        bytes[0] = 0x50; bytes[1] = 0x53; bytes[2] = 0x49; bytes[3] = 0x44 // "PSID"
        bytes[5] = 0x02                 // Version 2
        bytes[7] = 0x7C                 // dataOffset = 0x7C
        bytes[8] = 0x10                 // loadAddr = 0x1000 (explizit im Header!)
        bytes[10] = 0x10                // initAddr = 0x1000
        bytes[12] = 0x10                // playAddr = 0x1000
        bytes[15] = 1                   // songs = 1
        bytes[17] = 0x01                // startSong = 1
        // Datenblock: Binary beginnt SOFORT (keine Ladeadresse davor).
        bytes += [0xA9, 0x0F, 0x60]     // LDA #$0F / RTS
        let sid = try SidParser.parse(data: Data(bytes))

        XCTAssertEqual(sid.loadAddr, 0x1000)
        // Die ersten Binary-Bytes muessen erhalten bleiben:
        XCTAssertEqual([UInt8](sid.binaryData.prefix(3)), [0xA9, 0x0F, 0x60])
    }

    // Gegenprobe: loadAddress 0 im Header -> Ladeadresse steckt in den ersten
    // zwei Datenbytes (little-endian) und wird NICHT Teil des Binaries.
    func testEmbeddedLoadAddressIsStripped() throws {
        var bytes = [UInt8](repeating: 0, count: 0x7C)
        bytes[0] = 0x50; bytes[1] = 0x53; bytes[2] = 0x49; bytes[3] = 0x44 // "PSID"
        bytes[5] = 0x02                 // Version 2
        bytes[7] = 0x7C                 // dataOffset = 0x7C
        // loadAddr-Feld bleibt 0 -> eingebettete Ladeadresse
        bytes[10] = 0x10                // initAddr = 0x1000
        bytes[12] = 0x10                // playAddr = 0x1000
        bytes[15] = 1                   // songs = 1
        bytes[17] = 0x01                // startSong = 1
        // Datenblock: Ladeadresse 0x1000 little-endian, dann Binary.
        bytes += [0x00, 0x10, 0xA9, 0x0F, 0x60]
        let sid = try SidParser.parse(data: Data(bytes))

        XCTAssertEqual(sid.loadAddr, 0x1000)
        XCTAssertEqual([UInt8](sid.binaryData.prefix(3)), [0xA9, 0x0F, 0x60])
    }

    // Regression (Code-Review F1): Eine fehlerhafte SID, deren Ladeadresse +
    // Payload ueber das 64-KB-C64-RAM (0x10000) hinausragt, darf NICHT crashen.
    // Die ueberstehenden Bytes werden sicher abgeklemmt (und eine Warnung geloggt);
    // der Rest laedt und spielt normal. loadAddr = 0xFFFE + 4 Payload-Bytes ->
    // 2 Bytes liegen jenseits von 0xFFFF und werden verworfen.
    func testOverflowingLoadAddressDoesNotCrash() throws {
        var bytes = [UInt8](repeating: 0, count: 0x7C)
        bytes[0] = 0x50; bytes[1] = 0x53; bytes[2] = 0x49; bytes[3] = 0x44 // "PSID"
        bytes[5] = 0x02                 // Version 2
        bytes[7] = 0x7C                 // dataOffset = 0x7C
        bytes[8] = 0xFF; bytes[9] = 0xFE // loadAddr = 0xFFFE (explizit, Binary folgt sofort)
        bytes[10] = 0xFF; bytes[11] = 0xFE // initAddr = 0xFFFE (dort steht ein RTS)
        bytes[12] = 0xFF; bytes[13] = 0xFE // playAddr = 0xFFFE
        bytes[15] = 1                   // songs = 1
        bytes[17] = 0x01                // startSong = 1
        // 4 Payload-Bytes: 0xFFFE/0xFFFF passen, die letzten zwei laufen ueber 0x10000.
        bytes += [0x60, 0x60, 0x60, 0x60] // RTS, ...
        let sid = try SidParser.parse(data: Data(bytes))

        XCTAssertEqual(sid.loadAddr, 0xFFFE)
        XCTAssertEqual(sid.binaryData.count, 4)

        let processor = ViciousProcessor(sampleRate: 44100.0)
        _ = processor.loadSID(sidFile: sid) // klemmt die 2 ueberstehenden Bytes ab
        processor.initSubtune(sub: 0)
        processor.setVolume(vol: 1.0)
        for _ in 0..<1000 { _ = processor.play() }
        // Kein Crash == bestanden.
    }

    // Autoplay-Ordner-Aufloesung (Einstellungen-Dialog): konfigurierter Ordner
    // gewinnt, wenn er existiert; sonst Standard-Ordner; sonst nil.
    func testAutoplayFolderResolve() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let defaultDir = home.appendingPathComponent(AutoplayFolder.defaultRelativePath, isDirectory: true)

        // Konfigurierter Ordner existiert -> er gewinnt.
        XCTAssertEqual(
            AutoplayFolder.resolve(configuredPath: "/Volumes/SIDs", home: home) { $0.path == "/Volumes/SIDs" }?.path,
            "/Volumes/SIDs"
        )
        // Konfigurierter Ordner fehlt -> Fallback auf den Standard-Ordner.
        XCTAssertEqual(
            AutoplayFolder.resolve(configuredPath: "/Volumes/Weg", home: home) { $0.path == defaultDir.path },
            defaultDir
        )
        // Nichts konfiguriert ("" bzw. nur Whitespace) -> Standard-Ordner.
        XCTAssertEqual(
            AutoplayFolder.resolve(configuredPath: "  ", home: home) { $0.path == defaultDir.path },
            defaultDir
        )
        // Gar kein Ordner existiert -> nil (App laedt nichts).
        XCTAssertNil(AutoplayFolder.resolve(configuredPath: "", home: home) { _ in false })
        // "~" im konfigurierten Pfad wird expandiert (kein woertliches "~" im Ergebnis).
        let tilde = AutoplayFolder.resolve(configuredPath: "~/sid", home: home) { _ in true }
        XCTAssertEqual(tilde?.path.contains("~"), false)
    }

    // Erscheinungsbild-Modus (Einstellungen-Dialog): Auto folgt dem System,
    // Hell/Dunkel sind fest; unbekannte/fehlende gespeicherte Werte -> Auto.
    func testThemeModeResolve() {
        // Auto: uebernimmt den System-Zustand 1:1.
        XCTAssertTrue(ThemeMode.auto.resolvesToDark(systemPrefersDark: true))
        XCTAssertFalse(ThemeMode.auto.resolvesToDark(systemPrefersDark: false))
        // Manuell: ignoriert den System-Zustand.
        XCTAssertFalse(ThemeMode.light.resolvesToDark(systemPrefersDark: true))
        XCTAssertTrue(ThemeMode.dark.resolvesToDark(systemPrefersDark: false))
        // Gespeicherte Werte: gueltige Strings mappen, alles andere faellt auf Auto.
        XCTAssertEqual(ThemeMode(storedValue: "dark"), .dark)
        XCTAssertEqual(ThemeMode(storedValue: "light"), .light)
        XCTAssertEqual(ThemeMode(storedValue: nil), .auto)
        XCTAssertEqual(ThemeMode(storedValue: "kaputt"), .auto)
    }
}
