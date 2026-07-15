import XCTest
@testable import ViciousSIDPlayerCore

// ============================================================================
// Determinismus der Emulation — der Test, der den Linux-Port absichert.
//
// WORUM ES GEHT
// -------------
// Die zentrale Behauptung des Ports lautet: Die 6502-CPU- und SID-DSP-Emulation
// rechnet auf jeder Plattform und jeder Architektur exakt dasselbe — Bit fuer Bit,
// Fliesskomma eingeschlossen. Genau das wurde beim Port von Hand geprueft (gleiche
// WAV-Bytes auf macOS-arm64 und Linux-x86_64). Von Hand heisst: einmal. Nichts
// wuerde es merken, wenn eine spaetere Aenderung diese Eigenschaft zerstoert.
// Dieser Test haelt sie fest.
//
// WARUM EINE SELBSTGEBAUTE SID-DATEI
// ----------------------------------
// Ein Determinismus-Test braucht IMMER dieselbe Eingabe. Echte SID-Dateien sind
// urheberrechtlich geschuetzt und duerfen im Repo nicht liegen — die uebrigen Tests
// ueberspringen sich deshalb, wenn lokal keine Sammlung vorhanden ist. Also baut
// dieser Test seine Eingabe selbst: einen minimalen PSID-Header plus eine
// handgeschriebene 6502-Routine. Die gehoert uns, ist winzig, liegt nie als Datei
// vor und ist auf jedem Rechner identisch.
//
// WAS DIE ROUTINE TUT (und was bewusst nicht)
// -------------------------------------------
// init() setzt Lautstaerke, Huellkurve und einen Dreieck-Ton mit Gate. play() wird
// pro Frame gerufen, zaehlt eine Zero-Page-Zelle hoch und schreibt sie ins
// Frequenz-Hi-Byte — der Ton steigt also stetig. Damit laufen Rechenwerk,
// Zero-Page-Zugriffe, Read-Modify-Write und der komplette DSP-Pfad mit.
//
// Bewusst NICHT benutzt: Lesen von schreibgeschuetzten SID-Registern und der
// ENV3-Readback. Beides ist heikles Emulationsverhalten mit eigenen Referenztests;
// ein Determinismus-Test soll die Emulation abbilden, nicht ihre Graubereiche
// ausloten.
// ============================================================================
final class DeterminismTests: XCTestCase {

    // MARK: - Die synthetische SID-Datei

    /// Ladeadresse des kleinen C64-Programms. $1000 ist frei nutzbarer RAM.
    private static let loadAddress: UInt16 = 0x1000

    /// Baut das C64-Maschinenprogramm (6502-Opcodes von Hand).
    ///
    /// Die Adressen sind unten hart ausgerechnet und in `initAddress`/`playAddress`
    /// gespiegelt — wer hier Bytes einfuegt, muss beide Konstanten nachziehen. Der
    /// Test `testSyntheticProgramLayoutIsConsistent` faengt genau diesen Fehler ab.
    private static func machineCode() -> [UInt8] {
        var code: [UInt8] = []

        // --- init bei $1000 ------------------------------------------------
        // LDA #$0F / STA $D418 — Master-Lautstaerke auf Maximum (15).
        code += [0xA9, 0x0F, 0x8D, 0x18, 0xD4]
        // LDA #$21 / STA $D405 — Attack/Decay der Huellkurve von Stimme 1.
        code += [0xA9, 0x21, 0x8D, 0x05, 0xD4]
        // LDA #$F0 / STA $D406 — Sustain 15, Release 0: der Ton haelt dauerhaft.
        code += [0xA9, 0xF0, 0x8D, 0x06, 0xD4]
        // LDA #$00 / STA $D400 — Frequenz, unteres Byte.
        code += [0xA9, 0x00, 0x8D, 0x00, 0xD4]
        // LDA #$20 / STA $D401 — Frequenz, oberes Byte (Startton).
        code += [0xA9, 0x20, 0x8D, 0x01, 0xD4]
        // LDA #$11 / STA $D404 — Waveform Dreieck ($10) + Gate ($01): Ton an.
        code += [0xA9, 0x11, 0x8D, 0x04, 0xD4]
        // RTS
        code += [0x60]

        // --- play bei $101F ------------------------------------------------
        // INC $FB — Zaehler in der Zero Page hochzaehlen (Read-Modify-Write).
        code += [0xE6, 0xFB]
        // LDA $FB / STA $D401 — Zaehler ins Frequenz-Hi-Byte: der Ton steigt.
        code += [0xA5, 0xFB, 0x8D, 0x01, 0xD4]
        // RTS
        code += [0x60]

        return code
    }

    /// Einsprung von init: gleich am Anfang des Programms.
    private static let initAddress: UInt16 = 0x1000
    /// Einsprung von play: direkt hinter dem RTS von init (31 Bytes weiter).
    private static let playAddress: UInt16 = 0x101F

    /// Setzt eine vollstaendige PSID-v2-Datei im Speicher zusammen.
    ///
    /// Aufbau laut SID-Dateiformat: 0x7C Bytes Header (alle Mehrbyte-Felder
    /// BIG-endian — anders als beim C64 selbst!), danach das C64-Binary.
    private static func syntheticSidData() -> Data {
        var header = [UInt8](repeating: 0, count: 0x7C)

        func putUInt16BE(_ value: UInt16, at offset: Int) {
            header[offset] = UInt8(value >> 8)
            header[offset + 1] = UInt8(value & 0xFF)
        }

        /// Schreibt einen Text als Latin-1 in ein Feld fester Laenge (nullterminiert).
        func putString(_ text: String, at offset: Int, maxLength: Int) {
            let bytes = Array(text.utf8.prefix(maxLength - 1))
            for (i, byte) in bytes.enumerated() { header[offset + i] = byte }
        }

        header[0] = UInt8(ascii: "P")
        header[1] = UInt8(ascii: "S")
        header[2] = UInt8(ascii: "I")
        header[3] = UInt8(ascii: "D")
        putUInt16BE(2, at: 4)             // Version 2
        putUInt16BE(0x7C, at: 6)          // dataOffset: Binary beginnt bei 0x7C
        putUInt16BE(loadAddress, at: 8)   // Ladeadresse explizit im Header …
        putUInt16BE(initAddress, at: 10)
        putUInt16BE(playAddress, at: 12)
        putUInt16BE(1, at: 14)            // ein Subtune
        putUInt16BE(1, at: 16)            // Startsong (1-basiert im Header)
        // Speed-Bits bei 18..21 bleiben 0 = VBI (50 Hz), kein CIA-Timer.

        putString("Determinism Probe", at: 0x16, maxLength: 32)
        putString("Vicious SID Player Tests", at: 0x36, maxLength: 32)
        putString("2026 Synthetic", at: 0x56, maxLength: 32)

        // Flags bei 0x76/0x77. Bits 4-5 von 0x77 waehlen das Modell: 0x20 = 8580.
        header[0x77] = 0x20

        // … deshalb faengt der Datenblock DIREKT mit dem Binary an; die sonst
        // ueblichen zwei Little-Endian-Bytes der Ladeadresse entfallen.
        return Data(header) + Data(machineCode())
    }

    // MARK: - Tests

    /// Stellt sicher, dass die hart notierten Einsprungadressen zum Code passen.
    /// Ohne diesen Test wuerde ein eingefuegter Opcode `playAddress` still
    /// verschieben — der Determinismus-Test unten wuerde dann fehlschlagen, ohne
    /// dass der Grund erkennbar waere.
    func testSyntheticProgramLayoutIsConsistent() {
        let code = Self.machineCode()
        // init endet nach 31 Bytes mit RTS, play beginnt unmittelbar danach.
        XCTAssertEqual(code.count, 31 + 8, "Programmlaenge passt nicht zum Layout")
        XCTAssertEqual(code[30], 0x60, "Byte 30 muss das RTS von init sein")
        XCTAssertEqual(Self.playAddress, Self.loadAddress + 31,
                       "playAddress zeigt nicht auf das erste Byte von play")
        XCTAssertEqual(code[38], 0x60, "Letztes Byte muss das RTS von play sein")
    }

    /// Die synthetische Datei muss den Parser sauber durchlaufen.
    func testSyntheticSidParses() throws {
        let sid = try SidParser.parse(data: Self.syntheticSidData())

        XCTAssertEqual(sid.metadata.title, "Determinism Probe")
        XCTAssertEqual(sid.metadata.subtunesCount, 1)
        XCTAssertEqual(sid.loadAddr, Self.loadAddress)
        XCTAssertEqual(sid.initAddr, Self.initAddress)
        XCTAssertEqual(sid.playAddr, Self.playAddress)
        XCTAssertEqual(sid.prefModel, 8580, "Modell-Flag im Header nicht erkannt")
        XCTAssertEqual(sid.secondSidAddress, 0, "Single-SID erwartet")
        XCTAssertEqual(sid.binaryData.count, Self.machineCode().count,
                       "Bei expliziter Ladeadresse darf kein Byte uebersprungen werden")
    }

    /// Rendert eine Sekunde und prueft, dass ueberhaupt Ton entsteht.
    ///
    /// Dieser Test steht bewusst VOR dem Hash-Test: Waere die Emulation komplett
    /// stumm, schluege unten nur „Hash passt nicht" fehl — hier steht stattdessen
    /// direkt, dass gar kein Signal ankam.
    func testSyntheticSidProducesSound() throws {
        let samples = try Self.render(seconds: 1.0)
        let peak = samples.map { abs($0) }.max() ?? 0
        // play() liefert Doubles im Bereich -1…1, nicht 16-Bit-Ganzzahlen. Die
        // Schwelle liegt bewusst weit unter dem tatsaechlichen Pegel (~0,16): Sie
        // soll „gar kein Signal" von „Signal" trennen, nicht die Lautstaerke
        // festschreiben — das ist Aufgabe des Hash-Tests unten.
        XCTAssertGreaterThan(peak, 0.01, "Die synthetische SID ist stumm geblieben")
    }

    /// **Der eigentliche Determinismus-Test.**
    ///
    /// Rendert eine Sekunde, wandelt sie exakt wie der WAV-Export nach 16-Bit-PCM
    /// und nagelt den MD5 der Bytes fest. Dieser Wert MUSS auf jeder Plattform und
    /// jeder Architektur derselbe sein.
    ///
    /// Schlaegt der Test fehl, ist genau eine von zwei Aussagen wahr:
    ///  1. Die Emulation wurde geaendert (dann ist der Hash bewusst neu zu setzen —
    ///     aber nur nach Abgleich mit den bekannten SID-Referenzfaellen!), oder
    ///  2. die Plattform-Unabhaengigkeit ist kaputt (dann NICHT den Hash anpassen,
    ///     sondern die Ursache suchen).
    ///
    /// Den Hash bitte NIEMALS einfach aus dem Fehlertext uebernehmen, um den Test
    /// gruen zu bekommen — damit waere sein einziger Zweck erledigt.
    func testRenderIsBitIdenticalAcrossPlatforms() throws {
        let samples = try Self.render(seconds: 1.0)

        // Wandlung wie in WavRenderer: hart geclippt, 16 Bit, little-endian.
        var pcm = [UInt8]()
        pcm.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clipped = max(-1.0, min(1.0, sample))
            let value = Int16(clipped * 32767.0).littleEndian
            withUnsafeBytes(of: value) { pcm.append(contentsOf: $0) }
        }

        XCTAssertEqual(pcm.count, 44100 * 2, "Unerwartete Anzahl gerenderter Bytes")
        // Ermittelt am 2026-07-16 auf macOS-arm64 und unabhaengig auf Linux-x86_64
        // bestaetigt (Swift 6.0.3, Container swift:6.0).
        XCTAssertEqual(MD5.hexString(of: Data(pcm)),
                       "b36b7fdcd5a854b00f1e039ccf20d484",
                       "Die Emulation rendert nicht mehr bitgenau dasselbe — siehe Kommentar über diesem Test")
    }

    // MARK: - Hilfsmittel

    /// Rendert die synthetische SID zu Mono-Samples (wie `ViciousProcessor.play()`).
    private static func render(seconds: Double, sampleRate: Double = 44100.0) throws -> [Double] {
        let sid = try SidParser.parse(data: syntheticSidData())
        let processor = ViciousProcessor(sampleRate: sampleRate)
        _ = processor.loadSID(sidFile: sid)
        processor.initSubtune(sub: 0)
        processor.setVolume(vol: 1.0)

        let count = Int(seconds * sampleRate)
        var samples = [Double]()
        samples.reserveCapacity(count)
        for _ in 0..<count { samples.append(processor.play()) }
        return samples
    }
}
