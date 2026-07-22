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

    // Voice-Muting + Filter-Bypass: alle 3 Stimmen stumm -> Ausgabe still; wieder
    // laut + Filter-Bypass -> Ausgabe weiter hoerbar (unabhaengige Messung ueber
    // die tatsaechlich synthetisierten Samples, nicht ueber den Mute-Zustand).
    func testVoiceMutingAndFilterToggle() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sidURL = home.appendingPathComponent("Music/Vicious SID Player/Cybernoid.sid")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: sidURL.path),
            "Test-SID nicht gefunden (\(sidURL.path)) — Muting-Test uebersprungen."
        )

        let sidFile = try SidParser.parse(data: try Data(contentsOf: sidURL))
        let processor = ViciousProcessor(sampleRate: 44100.0)
        _ = processor.loadSID(sidFile: sidFile)
        processor.initSubtune(sub: 0)
        processor.setVolume(vol: 1.0)

        // Anspielen (1 s), damit die Stimmen sicher klingen.
        var audible = 0
        for _ in 0..<44100 where abs(processor.play()) > 0.000001 { audible += 1 }
        XCTAssertGreaterThan(audible, 1000, "Referenz: Tune muss hoerbar sein")

        // Alle 3 Stimmen stumm -> still (Emulation laeuft weiter). Der Filter
        // klingt nach dem Stummschalten noch kurz aus (sein Zustand laeuft bewusst
        // warm weiter) — daher erst 0,1 s Ausklingphase, dann muss Stille sein.
        for v in 0..<3 { processor.setVoiceMuted(voice: v, muted: true) }
        for _ in 0..<4410 { _ = processor.play() }
        var mutedNonZero = 0
        for _ in 0..<44100 where abs(processor.play()) > 0.000001 { mutedNonZero += 1 }
        XCTAssertEqual(mutedNonZero, 0, "Alle Stimmen stumm -> keine Ausgabe")

        // Wieder laut + Filter-Bypass -> wieder hoerbar, kein Crash.
        for v in 0..<3 { processor.setVoiceMuted(voice: v, muted: false) }
        processor.setFilterEnabled(false)
        var bypassAudible = 0
        for _ in 0..<44100 where abs(processor.play()) > 0.000001 { bypassAudible += 1 }
        XCTAssertGreaterThan(bypassAudible, 1000, "Filter-Bypass darf den Ton nicht toeten")
    }

    // WAV-Export: korrekter RIFF-Header + hoerbarer Inhalt. Header/Samples werden
    // unabhaengig aus den geschriebenen Datei-Bytes geprueft, nicht ueber den
    // Renderer selbst.
    func testWavRenderer() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sidURL = home.appendingPathComponent("Music/Vicious SID Player/Cybernoid.sid")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: sidURL.path),
            "Test-SID nicht gefunden (\(sidURL.path)) — WAV-Test uebersprungen."
        )

        let sidFile = try SidParser.parse(data: try Data(contentsOf: sidURL))
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("vicious-wav-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dest) }

        try WavRenderer.render(sidFile: sidFile, subtune: 0, seconds: 2.0, to: dest)

        let wav = try Data(contentsOf: dest)
        // 44 Byte Header + 2 s * 44100 Samples * 2 Bytes
        XCTAssertEqual(wav.count, 44 + 2 * 44100 * 2)
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        // Mono, 16 Bit, 44100 Hz (little-endian Felder im fmt-Chunk)
        XCTAssertEqual(wav[22], 1)   // channels
        XCTAssertEqual(UInt32(wav[24]) | UInt32(wav[25]) << 8 | UInt32(wav[26]) << 16 | UInt32(wav[27]) << 24, 44100)
        XCTAssertEqual(UInt16(wav[34]) | UInt16(wav[35]) << 8, 16)
        // Inhalt darf nicht still sein.
        var nonZero = 0
        var i = 44
        while i + 1 < wav.count {
            if wav[i] != 0 || wav[i + 1] != 0 { nonZero += 1 }
            i += 2
        }
        XCTAssertGreaterThan(nonZero, 1000, "WAV-Inhalt darf nicht still sein")

        // Ungueltige Dauer -> sauberer Fehler statt Endlos-Render.
        XCTAssertThrowsError(try WavRenderer.render(sidFile: sidFile, seconds: 0, to: dest))
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
        let loadResult = processor.loadSID(sidFile: sid) // klemmt die 2 ueberstehenden Bytes ab
        XCTAssertEqual(loadResult.diagnostics.count, 1)
        XCTAssertTrue(loadResult.diagnostics[0].contains("2 Byte(s)"))
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

    // Songlengths.md5-Parser: Kommentare/Sektionen ignorieren, M:SS und
    // M:SS.mmm parsen, Attribute in Klammern abschneiden, kaputte Zeilen skippen.
    func testSonglengthDBParse() {
        let text = """
        [Database]
        ; /MUSICIANS/T/Tel_Jeroen/Cybernoid.sid
        c2a01b2e5a55278e6b37b1d63a11e19c=2:51 1:07.500 0:45(G)
        ; kaputte Zeilen:
        zukurz=1:00
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=kaputt
        """
        let db = SonglengthDB.parse(text: text)
        XCTAssertEqual(db.count, 1)
        let lengths = db.lengths(forMD5: "C2A01B2E5A55278E6B37B1D63A11E19C") // case-insensitiv
        XCTAssertEqual(lengths?.count, 3)
        XCTAssertEqual(lengths?[0] ?? 0, 171.0, accuracy: 0.001)
        XCTAssertEqual(lengths?[1] ?? 0, 67.5, accuracy: 0.001)
        XCTAssertEqual(lengths?[2] ?? 0, 45.0, accuracy: 0.001)
        XCTAssertNil(db.lengths(forMD5: "ffffffffffffffffffffffffffffffff"))
        // MD5-Hex gegen bekannten Referenzwert ("abc").
        XCTAssertEqual(SonglengthDB.md5Hex(of: Data("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
    }

    // Auto-Fund der Songlengths.md5: liegt unter <HVSC-Root>/DOCUMENTS/, auch
    // wenn der Startordner ein Unterordner (z.B. MUSICIANS/) ist.
    func testSonglengthDBAutodetect() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vicious-hvsc-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let docs = root.appendingPathComponent("C64Music/DOCUMENTS")
        let musicians = root.appendingPathComponent("C64Music/MUSICIANS/T")
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try fm.createDirectory(at: musicians, withIntermediateDirectories: true)
        let dbFile = docs.appendingPathComponent("Songlengths.md5")
        try Data("[Database]\n".utf8).write(to: dbFile)

        // Vom HVSC-Root und aus einem Unterordner gefunden; woanders nicht.
        XCTAssertEqual(SonglengthDB.autodetect(nearFolder: root.appendingPathComponent("C64Music"), fm: fm)?.path, dbFile.path)
        XCTAssertEqual(SonglengthDB.autodetect(nearFolder: musicians, fm: fm)?.path, dbFile.path)
        XCTAssertNil(SonglengthDB.autodetect(nearFolder: fm.temporaryDirectory, fm: fm))
    }

    // Berechneter Songlaengen-Cache: Roundtrip + Persistenz ueber Instanzen.
    func testSongLengthCache() {
        let fm = FileManager.default
        let file = fm.temporaryDirectory.appendingPathComponent("vicious-cache-\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: file) }

        let cache = SongLengthCache(fileURL: file)
        XCTAssertNil(cache.length(md5: "abc", subtune: 0))
        cache.store(md5: "abc", subtune: 0, seconds: 123.5)
        cache.store(md5: "abc", subtune: 1, seconds: -1)   // "kein Ende gefunden"
        XCTAssertEqual(cache.length(md5: "ABC", subtune: 0), 123.5)
        XCTAssertEqual(cache.length(md5: "abc", subtune: 1), -1)

        // Neue Instanz liest dieselbe Datei -> persistent.
        let reloaded = SongLengthCache(fileURL: file)
        XCTAssertEqual(reloaded.length(md5: "abc", subtune: 0), 123.5)
    }

    // Songlaengen-Berechnung: ein synthetischer Tune, der nach ~0,5 s die
    // Master-Lautstaerke auf 0 setzt (endet in Stille), muss eine Laenge um
    // 1 s liefern; ein komplett stiller Tune liefert nil (kein Ende erkennbar).
    func testSongLengthEstimator() throws {
        // PSID-Header: init $1000, play $1040, 1 Song.
        var bytes = [UInt8](repeating: 0, count: 0x7C)
        bytes[0] = 0x50; bytes[1] = 0x53; bytes[2] = 0x49; bytes[3] = 0x44 // "PSID"
        bytes[5] = 0x02                 // Version 2
        bytes[7] = 0x7C                 // dataOffset
        bytes[10] = 0x10                // initAddr = 0x1000
        bytes[12] = 0x10; bytes[13] = 0x40 // playAddr = 0x1040
        bytes[15] = 1                   // songs
        bytes[17] = 0x01                // startSong

        // C64-Binary ab $1000 (eingebettete Ladeadresse unten im Datenblock):
        var binary = [UInt8](repeating: 0x60 /* RTS als Fuellung */, count: 0x60)
        // init ($1000): Volume auf, Zaehler $02 = 0, Stimme 1 Dreieck + Gate an.
        let initCode: [UInt8] = [
            0xA9, 0x0F, 0x8D, 0x18, 0xD4,   // LDA #$0F / STA $D418 (Volume max)
            0xA9, 0x00, 0x85, 0x02,          // LDA #$00 / STA $02   (Frame-Zaehler)
            0xA9, 0x25, 0x8D, 0x01, 0xD4,   // LDA #$25 / STA $D401 (Frequenz hi)
            0xA9, 0xF0, 0x8D, 0x06, 0xD4,   // LDA #$F0 / STA $D406 (Sustain max)
            0xA9, 0x11, 0x8D, 0x04, 0xD4,   // LDA #$11 / STA $D404 (Dreieck+Gate)
            0x60                             // RTS
        ]
        // play ($1040): nach 25 Frames (~0,5 s bei 50 Hz) Volume 0 + Gate aus.
        let playCode: [UInt8] = [
            0xE6, 0x02,                      // INC $02
            0xA5, 0x02,                      // LDA $02
            0xC9, 0x19,                      // CMP #25
            0x90, 0x08,                      // BCC -> RTS (8 Bytes ueberspringen)
            0xA9, 0x00,                      // LDA #$00
            0x8D, 0x18, 0xD4,                // STA $D418 (Volume 0 -> Stille)
            0x8D, 0x04, 0xD4,                // STA $D404 (Gate aus)
            0x60                             // RTS
        ]
        for (i, b) in initCode.enumerated() { binary[i] = b }
        for (i, b) in playCode.enumerated() { binary[0x40 + i] = b }
        bytes += [0x00, 0x10] + binary       // eingebettete Ladeadresse $1000

        let sid = try SidParser.parse(data: Data(bytes))
        let length = try SongLengthEstimator.estimate(sidFile: sid, subtune: 0, maxSeconds: 10.0)
        let unwrapped = try XCTUnwrap(length, "Endender Tune muss eine Laenge liefern")
        // ~0,5 s Musik + 0,5 s Ausklang-Puffer, mit Toleranz fuer Envelope-Release.
        XCTAssertGreaterThan(unwrapped, 0.4)
        XCTAssertLessThan(unwrapped, 3.0)

        // Komplett stiller Tune (nur RTS): kein Ende erkennbar -> nil.
        var silentBytes = [UInt8](repeating: 0, count: 0x7C)
        silentBytes[0] = 0x50; silentBytes[1] = 0x53; silentBytes[2] = 0x49; silentBytes[3] = 0x44
        silentBytes[5] = 0x02
        silentBytes[7] = 0x7C
        silentBytes[10] = 0x10
        silentBytes[12] = 0x10
        silentBytes[15] = 1
        silentBytes[17] = 0x01
        silentBytes += [0x00, 0x10, 0x60]    // Ladeadresse + RTS
        let silent = try SidParser.parse(data: Data(silentBytes))
        XCTAssertNil(try SongLengthEstimator.estimate(sidFile: silent, subtune: 0, maxSeconds: 5.0))

        // Regression: Nach mehr als drei Sekunden Pause setzt die Musik wieder
        // ein. Die alte Heuristik brach in der Pause ab und cachete ~0,5 s als
        // vermeintliches Ende; nur terminale Stille am Analyseende darf zaehlen.
        var pauseBinary = [UInt8](repeating: 0x60, count: 0x60)
        for (i, b) in initCode.enumerated() { pauseBinary[i] = b }
        let pauseThenResume: [UInt8] = [
            0xE6, 0x02,                         // INC $02
            0xA5, 0x02, 0xC9, 0x19, 0xD0, 0x05, // bei Frame 25 ...
            0xA9, 0x00, 0x8D, 0x18, 0xD4,       // ... Volume aus
            0xA5, 0x02, 0xC9, 0xE1, 0xD0, 0x05, // bei Frame 225 (~4,5 s) ...
            0xA9, 0x0F, 0x8D, 0x18, 0xD4,       // ... Volume wieder an
            0x60
        ]
        for (i, b) in pauseThenResume.enumerated() { pauseBinary[0x40 + i] = b }
        var pauseBytes = Array(bytes.prefix(0x7C))
        pauseBytes += [0x00, 0x10] + pauseBinary
        let pauseSID = try SidParser.parse(data: Data(pauseBytes))
        XCTAssertNil(
            try SongLengthEstimator.estimate(sidFile: pauseSID, subtune: 0, maxSeconds: 6.0),
            "Musik nach einer langen Zwischenpause darf nicht als beendeter Tune gelten"
        )
    }

    func testSongLengthEstimatorHonorsTaskCancellation() async throws {
        let sid = try makeSilentSID()
        let task = Task.detached {
            try SongLengthEstimator.estimate(sidFile: sid, subtune: 0, maxSeconds: 360.0)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Abgebrochene Schaetzung muss CancellationError liefern")
        } catch is CancellationError {
            // Erwartet: abgebrochene Jobs duerfen insbesondere kein -1 cachen.
        }
    }

    func testWavRendererStreamsAndValidatesBounds() throws {
        let sid = try makeSilentSID()
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("vicious-wav-\(UUID().uuidString)")
        let destination = directory.appendingPathComponent("out.wav")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        // Vorhandenes Ziel wird erst nach komplettem Render ersetzt.
        try Data("alt".utf8).write(to: destination)
        let seconds = 0.1
        try WavRenderer.render(sidFile: sid, seconds: seconds, to: destination)
        let rendered = try Data(contentsOf: destination)
        let frames = try WavRenderer.frameCount(seconds: seconds, sampleRate: 44100)
        XCTAssertEqual(rendered.count, 44 + frames * 2)
        XCTAssertEqual(String(data: rendered.prefix(4), encoding: .ascii), "RIFF")

        // Unvertretbar grosse bzw. nicht in Frames darstellbare Werte werden vor
        // jeder Ausgabe abgelehnt und lassen eine bestehende Datei unveraendert.
        let sentinel = Data("behalten".utf8)
        try sentinel.write(to: destination)
        XCTAssertThrowsError(
            try WavRenderer.render(
                sidFile: sid,
                seconds: WavRenderer.maximumDurationSeconds + 1,
                to: destination
            )
        )
        XCTAssertThrowsError(try WavRenderer.frameCount(seconds: 1e300, sampleRate: 44100))
        XCTAssertThrowsError(
            try WavRenderer.render(
                sidFile: sid,
                seconds: 0.000000001,
                sampleRate: Double(UInt32.max),
                to: destination
            )
        )
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }

    // Seek-Geschwindigkeit (UX-Smoke-Test): der Sprung ans Ende eines langen
    // Tunes (300 s) muss deutlich unter einer Sekunde bleiben — der Seek-Pfad
    // emuliert nur CPU-Frames (runFrameCPU), ohne Sample-Synthese. Grosszuegige
    // Schranke, damit der Test auf langsamen Maschinen nicht flackert.
    func testSeekIsFast() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sidURL = home.appendingPathComponent("Music/Vicious SID Player/Cybernoid.sid")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: sidURL.path),
            "Test-SID nicht gefunden — Seek-Benchmark uebersprungen."
        )
        let sid = try SidParser.parse(data: try Data(contentsOf: sidURL))
        let processor = ViciousProcessor(sampleRate: 44100.0)
        _ = processor.loadSID(sidFile: sid)
        processor.initSubtune(sub: 0)

        let start = Date()
        processor.seek(seconds: 300.0)
        let elapsed = Date().timeIntervalSince(start)
        print("Seek auf 300 s dauerte \(String(format: "%.3f", elapsed)) s")
        XCTAssertLessThan(elapsed, 3.0, "Seek muss quasi-sofort sein")
        // Nach dem Seek muss die Wiedergabe hoerbar weiterlaufen.
        var audible = 0
        for _ in 0..<22050 where abs(processor.play()) > 0.000001 { audible += 1 }
        XCTAssertGreaterThan(audible, 1000)
    }

    // 2SID (PSID v3): Parser liest Zweit-Chip-Adresse + eigenes Modell; die
    // Stereo-Wiedergabe pannt Chip 1 nach links und Chip 2 nach rechts —
    // gemessen an den tatsaechlich synthetisierten Samples.
    func testSecondSidStereo() throws {
        // PSID-v3-Header: init $1000, play = RTS, 2. SID bei $D420 (0x7A = 0x42),
        // Modell-Flags: Chip 1 = 8580 (Bits 4-5 = 10), Chip 2 = 6581 (Bits 6-7 = 01).
        var bytes = [UInt8](repeating: 0, count: 0x7C)
        bytes[0] = 0x50; bytes[1] = 0x53; bytes[2] = 0x49; bytes[3] = 0x44 // "PSID"
        bytes[5] = 0x03                 // Version 3 (2SID faehig)
        bytes[7] = 0x7C                 // dataOffset
        bytes[10] = 0x10                // initAddr = 0x1000
        bytes[12] = 0x10                // playAddr = 0x1000 + 0x2F (RTS am Ende des Init)
        bytes[13] = 0x2F
        bytes[15] = 1                   // songs
        bytes[17] = 0x01                // startSong
        bytes[0x77] = 0x60              // Chip 1: 8580, Chip 2: 6581
        bytes[0x7A] = 0x42              // 2. SID bei $D000 + $42*16 = $D420

        // init ($1000): beide Master-Volumes auf, je Chip Stimme 1 mit
        // unterschiedlicher Tonhoehe (Dreieck + Gate + Sustain).
        var binary: [UInt8] = [
            0xA9, 0x0F, 0x8D, 0x18, 0xD4, 0x8D, 0x38, 0xD4, // Volumes $D418/$D438
            0xA9, 0x25, 0x8D, 0x01, 0xD4,                   // SID1 Freq hi
            0xA9, 0xF0, 0x8D, 0x06, 0xD4,                   // SID1 Sustain
            0xA9, 0x11, 0x8D, 0x04, 0xD4,                   // SID1 Dreieck+Gate
            0xA9, 0x50, 0x8D, 0x21, 0xD4,                   // SID2 Freq hi (hoeher)
            0xA9, 0xF0, 0x8D, 0x26, 0xD4,                   // SID2 Sustain
            0xA9, 0x11, 0x8D, 0x24, 0xD4,                   // SID2 Dreieck+Gate
            0x60                                            // RTS (Offset 0x2F)
        ]
        while binary.count < 0x30 { binary.append(0x60) }
        bytes += [0x00, 0x10] + binary

        let sid = try SidParser.parse(data: Data(bytes))
        XCTAssertEqual(sid.secondSidAddress, 0xD420)
        XCTAssertEqual(sid.prefModel, 8580)
        XCTAssertEqual(sid.prefModel2, 6581)
        XCTAssertEqual(sid.thirdSidAddress, 0)   // v3 hat kein drittes SID-Feld

        let processor = ViciousProcessor(sampleRate: 44100.0)
        _ = processor.loadSID(sidFile: sid)
        processor.initSubtune(sub: 0)
        processor.setVolume(vol: 1.0)

        // 0,5 s stereo rendern: beide Kanaele hoerbar, aber deutlich verschieden
        // (unterschiedliche Chips links/rechts gepannt).
        var sumL = 0.0, sumR = 0.0, sumDiff = 0.0
        for _ in 0..<22050 {
            let s = processor.playStereo()
            sumL += abs(s.left)
            sumR += abs(s.right)
            sumDiff += abs(s.left - s.right)
        }
        XCTAssertGreaterThan(sumL, 10.0, "Linker Kanal muss hoerbar sein")
        XCTAssertGreaterThan(sumR, 10.0, "Rechter Kanal muss hoerbar sein")
        XCTAssertGreaterThan(sumDiff, sumL * 0.2, "Kanaele muessen sich deutlich unterscheiden (Panning)")

        // Mono-Pfad (play) mischt weiterhin beide Chips hoerbar.
        processor.initSubtune(sub: 0)
        var monoAudible = 0
        for _ in 0..<22050 where abs(processor.play()) > 0.000001 { monoAudible += 1 }
        XCTAssertGreaterThan(monoAudible, 1000)
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

    private func makeSilentSID() throws -> SidFileData {
        var bytes = [UInt8](repeating: 0, count: 0x7C)
        bytes[0] = 0x50; bytes[1] = 0x53; bytes[2] = 0x49; bytes[3] = 0x44
        bytes[5] = 0x02
        bytes[7] = 0x7C
        bytes[10] = 0x10
        bytes[12] = 0x10
        bytes[15] = 1
        bytes[17] = 0x01
        bytes += [0x00, 0x10, 0x60]
        return try SidParser.parse(data: Data(bytes))
    }
}
