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

    // Rendert den Subtune headless (ohne Audio-Ausgabe) und sucht das Ende:
    // haelt die Stille laenger als `silenceSeconds` an, gilt der letzte hoerbare
    // Moment (+ kurzer Ausklang-Puffer) als Songende.
    //
    // Rueckgabe nil = kein Ende innerhalb `maxSeconds` gefunden (Tune loopt oder
    // ist komplett still) -> Aufrufer behaelt sein Fallback-Limit.
    public static func estimate(sidFile: SidFileData,
                                subtune: Int,
                                maxSeconds: Double = 360.0,
                                sampleRate: Double = 44100.0,
                                silenceThreshold: Double = 0.00001,
                                silenceSeconds: Double = 3.0) -> Double? {
        let processor = ViciousProcessor(sampleRate: sampleRate)
        _ = processor.loadSID(sidFile: sidFile)
        let sub = max(0, min(subtune, sidFile.metadata.subtunesCount - 1))
        processor.initSubtune(sub: sub)
        processor.setVolume(vol: 1.0)

        let totalSamples = Int(maxSeconds * sampleRate)
        let silenceSamples = Int(silenceSeconds * sampleRate)
        var lastAudible = -1          // Sample-Index des letzten hoerbaren Samples
        var samplesSinceAudible = 0

        for i in 0..<totalSamples {
            if abs(processor.play()) > silenceThreshold {
                lastAudible = i
                samplesSinceAudible = 0
            } else {
                samplesSinceAudible += 1
                // Genug Stille am Stueck: Ende gefunden (sofern je etwas zu
                // hoeren war — ein komplett stiller Tune liefert nil).
                if samplesSinceAudible >= silenceSamples {
                    guard lastAudible >= 0 else { return nil }
                    // + 0,5 s Ausklang-Puffer, damit Auto-Next nicht ins letzte
                    // Release-Ende hineinschneidet.
                    return Double(lastAudible) / sampleRate + 0.5
                }
            }
        }
        return nil
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
