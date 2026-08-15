import XCTest
@testable import ViciousSIDPlayerCore

// Tests fuer den PCMSink-Vertrag.
//
// WARUM AUSGERECHNET UEBER StdoutPCMSink
// --------------------------------------
// Das Projekt hat drei Ausgaben, die denselben Vertrag erfuellen sollen:
// AVAudioEnginePCMSink (Apple), ALSAPCMSink (Linux) und StdoutPCMSink (ueberall).
// Die ersten beiden brauchen echte Audio-Hardware und einen Echtzeit-Thread; in
// einem Testlauf ohne Soundkarte — also auch im CI — sind sie nicht pruefbar.
//
// StdoutPCMSink ist die Ausnahme: Er schreibt in ein `FileHandle`, und das nimmt
// sein Konstruktor von aussen entgegen. Genau dafuer wurde diese Naht gebaut
// (siehe Kommentar dort), bislang aber nie benutzt. Hier wird sie benutzt: eine
// temporaere Datei bzw. eine Pipe statt stdout, und schon ist der komplette
// Zustandsautomat ohne Hardware pruefbar.
//
// Was das mit abdeckt: Der Zustandsautomat (Einwegnutzung, Pause/Fortsetzen,
// Endgruende, „der erste Grund gewinnt") ist im Protokoll beschrieben und in
// allen drei Ausgaben gleich umgesetzt. Was hier festgehalten wird, ist deshalb
// nicht nur das Verhalten einer Ausgabe, sondern die gemeinsame Erwartung an
// alle drei.
final class PCMSinkTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vicious-sink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Hilfsmittel

    /// Zaehler, den der Renderblock ueber Threadgrenzen hinweg fuehren darf.
    /// Der Block ist `@Sendable` und laeuft auf dem Pump-Thread, der Test liest
    /// vom Haupt-Thread — also gehoert beides hinter dasselbe Lock.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Erzeugt eine Ausgabedatei und das zugehoerige Schreib-Handle.
    private func makeOutputFile(_ name: String) throws -> (url: URL, handle: FileHandle) {
        let url = directory.appendingPathComponent(name)
        // Rueckgabewert bewusst verworfen: Schlaegt das Anlegen fehl, faellt genau
        // das eine Zeile weiter beim Oeffnen des Handles auf, und zwar mit dem
        // aussagekraeftigeren Fehler. Das `_ =` ist noetig, weil Apples Foundation
        // die Methode als @discardableResult fuehrt, die Linux-Foundation aber
        // nicht — ohne die Zuweisung warnt nur der Linux-Build.
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        return (url, try FileHandle(forWritingTo: url))
    }

    /// Liest die geschriebene Datei als Int16-Werte (s16le, so schreibt der Sink).
    private func readSamples(at url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        return stride(from: 0, to: data.count - data.count % 2, by: 2).map {
            Int16(littleEndian: Int16(data[$0]) | (Int16(bitPattern: UInt16(data[$0 + 1]) << 8)))
        }
    }

    // MARK: - Regulaeres Ende

    /// Der Grundfall: Die Quelle liefert zwei volle Bloecke und dann nichts mehr.
    /// Das ist laut Vertrag „Quelle erschoepft" und muss als `.sourceFinished`
    /// herauskommen — nicht als Fehler und nicht als `.stopped`.
    func testSourceExhaustionEndsPlaybackAndWritesSamples() throws {
        let (url, handle) = try makeOutputFile("run.pcm")
        let sink = StdoutPCMSink(format: PCMFormat(sampleRate: 44100, channels: 1),
                                 blockFrames: 64,
                                 output: handle)
        let rounds = Counter()

        try sink.start { buffer, frames in
            // Zwei volle Bloecke, danach 0 Frames = Quelle zu Ende.
            guard rounds.increment() <= 2 else { return 0 }
            for i in 0..<frames { buffer[i] = 1.0 }
            return frames
        }

        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished)
        try handle.close()

        let samples = try readSamples(at: url)
        XCTAssertEqual(samples.count, 128, "Zwei Bloecke zu 64 Frames, mono")
        XCTAssertTrue(samples.allSatisfy { $0 == 32767 }, "1.0 muss zum Vollausschlag werden")
    }

    /// Stereo ist interleaved (L, R, L, R …) — der Sink sortiert nichts um.
    /// Wenn er es doch taete, stuenden hier abwechselnd falsche Kanaele.
    func testStereoStaysInterleaved() throws {
        let (url, handle) = try makeOutputFile("stereo.pcm")
        let sink = StdoutPCMSink(format: PCMFormat(sampleRate: 44100, channels: 2),
                                 blockFrames: 4,
                                 output: handle)
        let rounds = Counter()

        try sink.start { buffer, frames in
            guard rounds.increment() <= 1 else { return 0 }
            for frame in 0..<frames {
                buffer[frame * 2] = 1.0       // links: Vollausschlag
                buffer[frame * 2 + 1] = -1.0  // rechts: Gegenausschlag
            }
            return frames
        }
        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished)
        try handle.close()

        let samples = try readSamples(at: url)
        XCTAssertEqual(samples.count, 8, "4 Frames à 2 Kanaele")
        for frame in 0..<4 {
            XCTAssertEqual(samples[frame * 2], 32767, "Frame \(frame): linker Kanal")
            XCTAssertEqual(samples[frame * 2 + 1], -32767, "Frame \(frame): rechter Kanal")
        }
    }

    /// Werte ausserhalb -1…1 werden geklemmt, nicht umgebrochen — ein Ueberlauf
    /// klaenge als lautes Knacken, und der Int16-Konstruktor stuerzte dabei ab.
    /// NaN muss ebenfalls durchgehen, ohne den Pump-Thread zu zerlegen.
    func testOutOfRangeAndNaNSamplesAreClampedInsteadOfCrashing() throws {
        let (url, handle) = try makeOutputFile("clip.pcm")
        let sink = StdoutPCMSink(format: PCMFormat(sampleRate: 44100, channels: 1),
                                 blockFrames: 4,
                                 output: handle)
        let rounds = Counter()

        try sink.start { buffer, frames in
            guard rounds.increment() <= 1 else { return 0 }
            buffer[0] = 5.0             // weit ueber dem Vollausschlag
            buffer[1] = -5.0            // weit darunter
            buffer[2] = Float.nan       // gar keine Zahl
            buffer[3] = 0.0
            return frames
        }
        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished)
        try handle.close()

        let samples = try readSamples(at: url)
        XCTAssertEqual(samples, [32767, -32767, 32767, 0],
                       "NaN landet auf dem oberen Rand — siehe Klemm-Kommentar im Sink")
    }

    // MARK: - Zustandsautomat

    /// Ein Sink ist Einweg. Ein zweiter `start()` ist ein Programmierfehler und
    /// muss als solcher gemeldet werden, statt still nichts zu tun.
    func testSecondStartIsRejected() throws {
        let (_, handle) = try makeOutputFile("twice.pcm")
        let sink = StdoutPCMSink(format: PCMFormat(sampleRate: 44100, channels: 1),
                                 blockFrames: 8,
                                 output: handle)
        try sink.start { _, _ in 0 }
        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished)

        XCTAssertThrowsError(try sink.start { _, _ in 0 }) { error in
            guard case PCMSinkError.invalidState = error else {
                return XCTFail("Erwartet wurde .invalidState, kam: \(error)")
            }
        }
        try handle.close()
    }

    /// `stop()` auf einem nie gestarteten Sink darf nicht dazu fuehren, dass
    /// `waitUntilFinished()` ewig haengt — es gab nichts zu spielen.
    func testStopWithoutStartReportsNotStarted() throws {
        let (_, handle) = try makeOutputFile("never.pcm")
        let sink = StdoutPCMSink(output: handle)
        sink.stop()
        XCTAssertEqual(sink.waitUntilFinished(), .notStarted)
        try handle.close()
    }

    /// Auch ohne vorheriges `stop()` gilt: nie gestartet = nichts zu warten.
    func testWaitWithoutStartReturnsImmediately() throws {
        let (_, handle) = try makeOutputFile("idle.pcm")
        let sink = StdoutPCMSink(output: handle)
        XCTAssertEqual(sink.waitUntilFinished(), .notStarted)
        try handle.close()
    }

    /// `stop()` waehrend laufender Wiedergabe beendet mit `.stopped`. Die Quelle
    /// hier ist unendlich — nur `stop()` kann dieses Stueck also beenden, damit
    /// der Test nicht zufaellig ueber das Quellenende gewinnt.
    func testStopDuringPlaybackReportsStopped() throws {
        let (_, handle) = try makeOutputFile("stopped.pcm")
        let sink = StdoutPCMSink(format: PCMFormat(sampleRate: 44100, channels: 1),
                                 blockFrames: 16,
                                 output: handle)
        let started = DispatchSemaphore(value: 0)
        let rounds = Counter()

        try sink.start { buffer, frames in
            if rounds.increment() == 1 { started.signal() }
            for i in 0..<frames { buffer[i] = 0.25 }
            return frames   // nie erschoepft
        }

        XCTAssertEqual(started.wait(timeout: .now() + 5), .success,
                       "Der Pump-Thread ist nicht angelaufen")
        sink.stop()
        XCTAssertEqual(sink.waitUntilFinished(), .stopped)
        XCTAssertFalse(sink.isRunning)
        try handle.close()
    }

    /// Mehrfaches `waitUntilFinished()` liefert denselben Grund erneut, statt
    /// beim zweiten Mal zu blockieren. Das CLI fragt aus zwei Threads.
    func testWaitIsRepeatable() throws {
        let (_, handle) = try makeOutputFile("repeat.pcm")
        let sink = StdoutPCMSink(blockFrames: 8, output: handle)
        try sink.start { _, _ in 0 }
        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished)
        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished)
        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished)
        try handle.close()
    }

    /// Der erste Grund gewinnt: Ist die Quelle schon durch, macht ein spaeteres
    /// `stop()` daraus kein `.stopped` mehr.
    func testFirstFinishReasonWins() throws {
        let (_, handle) = try makeOutputFile("first.pcm")
        let sink = StdoutPCMSink(blockFrames: 8, output: handle)
        try sink.start { _, _ in 0 }
        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished)
        sink.stop()
        XCTAssertEqual(sink.waitUntilFinished(), .sourceFinished,
                       "Ein nachtraegliches stop() darf den Grund nicht ueberschreiben")
        try handle.close()
    }

    /// Pause haelt an und Fortsetzen macht weiter — ohne dass dazwischen
    /// geschrieben wird. Gepruefte Groesse ist die Zahl der Renderaufrufe: sie
    /// steht waehrend der Pause still und laeuft danach weiter.
    func testPauseHaltsRenderingAndResumeContinues() throws {
        let (_, handle) = try makeOutputFile("pause.pcm")
        let sink = StdoutPCMSink(format: PCMFormat(sampleRate: 44100, channels: 1),
                                 blockFrames: 16,
                                 output: handle)
        let rounds = Counter()
        let started = DispatchSemaphore(value: 0)

        try sink.start { buffer, frames in
            if rounds.increment() == 1 { started.signal() }
            for i in 0..<frames { buffer[i] = 0.1 }
            return frames   // unendliche Quelle
        }

        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        try sink.pause()
        XCTAssertFalse(sink.isRunning, "Nach pause() laeuft der Sink nicht mehr")

        // Kurz warten und dann festhalten, wo der Zaehler steht. Der Pump-Thread
        // kann den gerade begonnenen Block noch fertig schreiben, danach parkt er.
        Thread.sleep(forTimeInterval: 0.2)
        let duringPause = rounds.current
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(rounds.current, duringPause,
                       "Waehrend der Pause darf kein weiterer Renderaufruf passieren")

        try sink.resume()
        XCTAssertTrue(sink.isRunning)
        let deadline = Date().addingTimeInterval(5)
        while rounds.current == duringPause && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertGreaterThan(rounds.current, duringPause,
                             "Nach resume() muss wieder gerendert werden")

        sink.stop()
        XCTAssertEqual(sink.waitUntilFinished(), .stopped)
        try handle.close()
    }

    // MARK: - Gegenstelle weg

    /// Schliesst der Empfaenger die Pipe (`… | head`, aplay beendet), ist das der
    /// Normalfall eines Programms, das nach stdout schreibt — und ausdruecklich
    /// KEIN Fehler. Der Vertrag verlangt dafuer `.outputClosed`, damit ein CLI
    /// daraus keinen Fehler-Exit-Code macht.
    func testClosedPipeEndsAsOutputClosedRatherThanFailure() throws {
        let pipe = Pipe()
        // Lesende Seite sofort zumachen: der erste Schreibversuch bekommt EPIPE.
        try pipe.fileHandleForReading.close()

        let sink = StdoutPCMSink(format: PCMFormat(sampleRate: 44100, channels: 1),
                                 blockFrames: 16,
                                 output: pipe.fileHandleForWriting)
        try sink.start { buffer, frames in
            for i in 0..<frames { buffer[i] = 0.5 }
            return frames   // unendliche Quelle: nur die kaputte Pipe beendet das
        }

        let reason = sink.waitUntilFinished()
        XCTAssertEqual(reason, .outputClosed,
                       "Eine geschlossene Gegenstelle ist ein regulaeres Ende, kein Fehler")
    }
}
