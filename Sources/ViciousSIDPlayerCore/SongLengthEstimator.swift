import Foundation

// Songlaengen-Aufloesung, Teil B: Berechnung + Cache fuer Dateien OHNE Eintrag
// in der HVSC-DB.
//
// Warum "berechnen" nicht trivial ist: ein SID ist Maschinencode ohne Ende-
// Marker; ob und wann er "fertig" ist, weiss nur die Musik selbst. Was sich
// zuverlaessig erkennen laesst: ein Tune, der in STILLE endet (Emulation
// schneller als Echtzeit laufen lassen und den letzten hoerbaren Sample merken).
// Endlos loopende Tunes (die HVSC-Mehrheit) haben dagegen kein erkennbares Ende —
// dort bleibt es beim Fallback-Limit des Aufrufers. Ergebnisse werden vom
// Aufrufer gecacht (SongLengthCache), damit die Berechnung pro Datei/Subtune
// nur einmal anfaellt.
public enum SongLengthEstimator {

    public enum EstimateError: Error {
        case invalidConfiguration
    }

    // Rendert den Subtune headless (ohne Audio-Ausgabe) und sucht das Ende:
    // am ENDE des gesamten Analysefensters haelt die Stille laenger als
    // `silenceSeconds` an, gilt der letzte hoerbare Moment (+ kurzer
    // Ausklang-Puffer) als Songende. Eine lange Pause in der Mitte reicht nicht:
    // spaeter wieder einsetzende Musik muss noch gesehen werden.
    //
    // Rueckgabe nil = kein Ende innerhalb `maxSeconds` gefunden (Tune loopt oder
    // ist komplett still) -> Aufrufer behaelt sein Fallback-Limit.
    public static func estimate(sidFile: SidFileData,
                                subtune: Int,
                                maxSeconds: Double = 360.0,
                                sampleRate: Double = 44100.0,
                                silenceThreshold: Double = 0.00001,
                                silenceSeconds: Double = 3.0) throws -> Double? {
        guard maxSeconds.isFinite,
              sampleRate.isFinite,
              silenceThreshold.isFinite,
              silenceThreshold >= 0,
              silenceSeconds.isFinite,
              silenceSeconds > 0 else {
            throw EstimateError.invalidConfiguration
        }
        let totalSamples: Int
        do {
            totalSamples = try WavRenderer.frameCount(seconds: maxSeconds, sampleRate: sampleRate)
        } catch {
            throw EstimateError.invalidConfiguration
        }
        let silenceValue = silenceSeconds * sampleRate
        guard silenceValue.isFinite,
              silenceValue >= 1,
              silenceValue <= Double(Int.max) else {
            throw EstimateError.invalidConfiguration
        }
        let silenceSamples = Int(silenceValue.rounded(.down))

        let processor = ViciousProcessor(sampleRate: sampleRate)
        _ = processor.loadSID(sidFile: sidFile)
        let sub = max(0, min(subtune, sidFile.metadata.subtunesCount - 1))
        processor.initSubtune(sub: sub)
        processor.setVolume(vol: 1.0)

        var lastAudible = -1          // Sample-Index des letzten hoerbaren Samples

        for i in 0..<totalSamples {
            // Nicht bei jedem Sample den Task-Status abfragen; ein Block bleibt
            // dennoch klein genug, damit ein Trackwechsel die CPU-Arbeit binnen
            // weniger Millisekunden beendet.
            if i.isMultiple(of: 4096) {
                try Task.checkCancellation()
            }
            if abs(processor.play()) > silenceThreshold {
                lastAudible = i
            }
        }

        try Task.checkCancellation()
        guard lastAudible >= 0,
              totalSamples - lastAudible - 1 >= silenceSamples else {
            return nil
        }
        // + 0,5 s Ausklang-Puffer, damit Auto-Next nicht ins letzte Release-Ende
        // hineinschneidet.
        return Double(lastAudible) / sampleRate + 0.5
    }
}

// Persistenter Cache der berechneten Laengen (JSON-Datei, Key "md5:subtune").
// Bewusst simpel: kleine Datenmenge (ein Eintrag pro tatsaechlich gespieltem
// Tune ohne DB-Eintrag), Schreiben sofort bei jedem Store.
public final class SongLengthCache: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private var entries: [String: Double]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let parsed = try? JSONDecoder().decode([String: Double].self, from: data) {
            self.entries = parsed
        } else {
            self.entries = [:]
        }
    }

    // Standard-Ablageort: ~/Library/Application Support/Vicious SID Player/
    public static func defaultCache(fm: FileManager = .default) -> SongLengthCache {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Vicious SID Player", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return SongLengthCache(fileURL: dir.appendingPathComponent("computed-songlengths.json"))
    }

    private func key(md5: String, subtune: Int) -> String {
        return "\(md5.lowercased()):\(subtune)"
    }

    public func length(md5: String, subtune: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key(md5: md5, subtune: subtune)]
    }

    public func store(md5: String, subtune: Int, seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        entries[key(md5: md5, subtune: subtune)] = seconds
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
