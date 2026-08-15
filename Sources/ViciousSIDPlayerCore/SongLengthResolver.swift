import Foundation

// Songlaengen-Aufloesung, Teil C: die Reihenfolge und die Buchfuehrung darueber.
//
// Teil A ist die HVSC-Datenbank (`SonglengthDB`), Teil B sind Berechnung und
// Cache (`SongLengthEstimator`, `SongLengthCache`). Was bis hierher fehlte, war
// die Regel, die beide verbindet — und die stand doppelt in den Oberflaechen:
// einmal in der Mac-App und ein zweites Mal in der iPhone-App, jeweils mit
// eigenem Generationszaehler und eigenem Schluessel fuer die laufende Rechnung.
// Zwei Fassungen derselben Regel driften auseinander; getestet war keine von
// beiden, weil `MainView` in einem `executableTarget` liegt und aus XCTest gar
// nicht erreichbar ist. Deshalb steht die Regel jetzt hier.
//
// Die Reihenfolge ist ein Architekturvertrag (siehe CLAUDE.md) und darf sich
// nicht aendern:
//
//   1. HVSC-`Songlengths.md5` — von Menschen kuratiert, hat immer Vorrang.
//   2. Berechneter Cache — Ergebnis einer frueheren Analyse dieser Datei.
//   3. Hintergrund-Berechnung — der Emulator laeuft schneller als Echtzeit und
//      sucht das Ende. Als Ende gilt erst, wenn mindestens drei Sekunden Stille
//      am Stueck folgen (steckt im `SongLengthEstimator`).
//   4. Sonst bleibt es beim Fallback-Limit der App (360 Sekunden).
//
// Diese Reihenfolge steuert Scrubber, Auto-Next, Now Playing und den WAV-Export.

/// Auftrag fuer eine Hintergrund-Berechnung.
///
/// Der Aufruf startet den `Task` selbst — der Core kennt weder SwiftUI noch die
/// Task-Verwaltung der jeweiligen App. Die `generation` ist bewusst nicht
/// oeffentlich: Sie ist die Buchfuehrung des Resolvers und niemand sonst soll
/// sie lesen oder erfinden koennen.
public struct SongLengthEstimateTicket: Equatable, Sendable {
    public let md5: String
    public let subtune: Int
    public let fileURL: URL
    let generation: Int
}

/// Was ohne Rechnen bereits feststeht — das Ergebnis von `plan(...)`.
public enum SongLengthPlan: Equatable, Sendable {
    /// Die HVSC-Datenbank kennt die Laenge. Es gibt nichts zu berechnen; eine
    /// eventuell laufende Berechnung wurde abgebrochen.
    case databaseProvidesLength
    /// Frueher berechnete Laenge aus dem Cache, sofort verwendbar.
    case cached(Double)
    /// Der Cache weiss bereits, dass dieser Tune kein erkennbares Ende hat
    /// (Loop). Es gilt das Fallback-Limit der App; eine laufende Berechnung
    /// wurde abgebrochen.
    case noLengthKnown
    /// Es fehlt noch die Grundlage — kein MD5 oder keine erreichbare Datei.
    ///
    /// Anders als bei allen uebrigen Faellen darf der Aufrufer hier **nichts**
    /// abbrechen: Dieser Zustand tritt waehrend eines Titelwechsels kurz auf,
    /// und eine bereits laufende Berechnung soll ihn ueberleben.
    case trackNotReady
    /// Der Aufrufer soll `runEstimate(ticket:)` im Hintergrund starten.
    case estimate(SongLengthEstimateTicket)
    /// Genau diese Berechnung laeuft bereits — nicht doppelt starten.
    case alreadyRunning
}

/// Haelt die Reihenfolge der Laengenquellen und die Buchfuehrung ueber die
/// laufende Berechnung.
///
/// Die Buchfuehrung ist mit einer Sperre geschuetzt statt an den Hauptthread
/// gebunden — dasselbe Muster wie beim `SongLengthCache` nebenan. Ein
/// `@MainActor` waere hier falsch: Beide Apps bedienen den Resolver zwar aus der
/// Oberflaeche, aber die Berechnung laeuft ausdruecklich daneben, und ein
/// Core-Typ soll seinen Aufrufern keine Isolation vorschreiben. Praktisch fiel
/// das beim Linux-Lauf auf: Unter Linux ist `XCTestCase` nicht
/// MainActor-isoliert, und die dort erzeugte Testliste kann eine
/// MainActor-gebundene Testmethode gar nicht aufrufen.
public final class SongLengthResolver: @unchecked Sendable {

    private let cache: SongLengthCache

    /// Schuetzt `activeKey` und `generation`. Beide sind winzig und werden nur
    /// kurz angefasst — eine einfache Sperre genuegt.
    private let lock = NSLock()

    /// Schluessel der gerade laufenden Berechnung, `nil` = keine laeuft.
    /// Verhindert, dass zwei kurz aufeinanderfolgende Ereignisse aus der
    /// Oberflaeche dieselbe Analyse zweimal starten.
    private var activeKey: String?

    /// Zaehlt hoch, sobald eine Berechnung abgebrochen oder ersetzt wird. Ein
    /// spaet eintreffendes Ergebnis einer aelteren Generation wird verworfen,
    /// statt den inzwischen gewaehlten Titel zu ueberschreiben.
    private var generation = 0

    public init(cache: SongLengthCache) {
        self.cache = cache
    }

    public convenience init(fm: FileManager = .default) {
        self.init(cache: SongLengthCache.defaultCache(fm: fm))
    }

    /// Nur fuer Tests und Diagnose: laeuft gerade eine Berechnung?
    public var isEstimating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeKey != nil
    }

    // MARK: - Schritt 1: entscheiden

    /// Bestimmt, was fuer den laufenden Subtune zu tun ist.
    ///
    /// - Parameters:
    ///   - md5: MD5 der laufenden Datei, `nil` wenn noch keine geladen ist.
    ///   - subtune: laufender Subtune (0-basiert).
    ///   - databaseLengths: Laengen dieser Datei aus der HVSC-Datenbank, `nil`
    ///     wenn die Datei dort nicht steht.
    ///   - fileURL: Datei fuer eine moegliche Berechnung, `nil` wenn nicht
    ///     erreichbar.
    public func plan(md5: String?,
                     subtune: Int,
                     databaseLengths: [Double]?,
                     fileURL: URL?) -> SongLengthPlan {
        lock.lock()
        defer { lock.unlock() }

        // 1. Die Datenbank kennt die Laenge? Dann ist nichts zu rechnen — und
        //    eine noch laufende Rechnung fuer den vorigen Titel ist gegenstandslos.
        if let lengths = databaseLengths, subtune >= 0, subtune < lengths.count {
            cancelLocked()
            return .databaseProvidesLength
        }

        // Ohne MD5 oder ohne erreichbare Datei laesst sich nichts berechnen.
        // Eine laufende Rechnung wird hier bewusst NICHT abgebrochen: dieser
        // Zustand tritt waehrend eines Titelwechsels kurz auf, und der naechste
        // Aufruf mit vollstaendigen Angaben raeumt ohnehin auf.
        guard let md5, let fileURL else { return .trackNotReady }

        let key = Self.key(md5: md5, subtune: subtune)
        if activeKey == key { return .alreadyRunning }

        // Ab hier ist klar: eine andere (oder gar keine) Rechnung lief bisher.
        // Das Hochzaehlen der Generation entwertet ein noch unterwegs
        // befindliches Ergebnis der vorigen Rechnung — `accept` weist es ab.
        cancelLocked()

        if let cached = cache.length(md5: md5, subtune: subtune) {
            // Ein gecachtes -1 heisst „schon einmal gerechnet, kein Ende
            // gefunden" (Loop-Tune). Ohne dieses negative Ergebnis wuerde die
            // HVSC-Mehrheit bei jedem Abspielen erneut sechs Minuten lang
            // durchgerechnet.
            return cached > 0 ? .cached(cached) : .noLengthKnown
        }

        // Die Generation stammt aus dem `cancel()` oben; ein zweites Hochzaehlen
        // waere nur Rauschen. Genau diese Nummer traegt das Ticket.
        activeKey = key
        return .estimate(SongLengthEstimateTicket(md5: md5,
                                                  subtune: subtune,
                                                  fileURL: fileURL,
                                                  generation: generation))
    }

    // MARK: - Schritt 2: rechnen (neben dem Hauptthread)

    /// Liest die Datei, laesst den Emulator schneller als Echtzeit laufen und
    /// legt das Ergebnis im Cache ab — auch ein „kein Ende gefunden" als -1.
    ///
    /// Rechnet minutenlang und gehoert deshalb in einen Hintergrund-Task, nicht
    /// auf den Hauptthread. Bricht der Aufrufer den Task ab, fliegt
    /// `CancellationError` und es wird **nichts** gecacht: ein absichtlich
    /// abgebrochener Lauf ist keine Aussage ueber die Laenge des Tunes.
    public func runEstimate(ticket: SongLengthEstimateTicket) throws -> Double? {
        try Task.checkCancellation()
        let data = try Data(contentsOf: ticket.fileURL)
        let sidFile = try SidParser.parse(data: data)
        let result = try SongLengthEstimator.estimate(sidFile: sidFile, subtune: ticket.subtune)
        try Task.checkCancellation()
        cache.store(md5: ticket.md5, subtune: ticket.subtune, seconds: result ?? -1)
        return result
    }

    // MARK: - Schritt 3: Ergebnis annehmen oder verwerfen

    /// Nimmt das Ergebnis einer Berechnung entgegen.
    ///
    /// - Returns: die anzuzeigende Laenge, oder `nil` wenn nichts zu uebernehmen
    ///   ist — weil inzwischen ein anderer Titel laeuft, weil die Rechnung einer
    ///   aelteren Generation angehoert oder weil kein Ende gefunden wurde.
    @discardableResult
    public func accept(_ seconds: Double?,
                       ticket: SongLengthEstimateTicket,
                       currentMD5: String?,
                       currentSubtune: Int) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentLocked(ticket) else { return nil }
        activeKey = nil
        // Nur uebernehmen, wenn immer noch derselbe Titel und Subtune laeuft.
        guard currentMD5 == ticket.md5, currentSubtune == ticket.subtune else { return nil }
        return seconds
    }

    /// Meldet eine fehlgeschlagene Berechnung (Datei unlesbar, Parser-Fehler).
    /// Raeumt die Buchfuehrung auf, damit ein spaeterer Anlauf nicht faelschlich
    /// als „laeuft schon" abgewiesen wird.
    public func fail(ticket: SongLengthEstimateTicket) {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrentLocked(ticket) else { return }
        activeKey = nil
    }

    /// Bricht die Buchfuehrung ab: die naechste Generation beginnt, ein noch
    /// laufendes Ergebnis wird nicht mehr angenommen. Den `Task` selbst bricht
    /// der Aufrufer ab — nur er haelt ihn.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelLocked()
    }

    // Die beiden Helfer setzen voraus, dass die Sperre bereits gehalten wird —
    // `NSLock` ist nicht wiedereintrittsfaehig, ein erneutes `lock()` von
    // derselben Stelle aus wuerde stehen bleiben.
    private func cancelLocked() {
        activeKey = nil
        generation &+= 1
    }

    private func isCurrentLocked(_ ticket: SongLengthEstimateTicket) -> Bool {
        return generation == ticket.generation
            && activeKey == Self.key(md5: ticket.md5, subtune: ticket.subtune)
    }

    /// Derselbe Schluessel wie im `SongLengthCache`: klein geschrieben, damit
    /// zwei Schreibweisen desselben MD5 nicht zwei Rechnungen ausloesen.
    private static func key(md5: String, subtune: Int) -> String {
        return "\(md5.lowercased()):\(subtune)"
    }
}

// MARK: - Die effektive Dauer

/// Die Leiter aus den drei Quellen zu genau einer Dauer.
///
/// Stand ebenfalls doppelt in beiden Apps (`currentDuration`). Sie bestimmt
/// Scrubber-Laenge, Auto-Next-Schwelle, die Restzeit auf dem Sperrbildschirm
/// und die Dauer des WAV-Exports.
public enum SongLengthSelection {

    /// Fallback-Limit, wenn weder Datenbank noch Berechnung etwas liefern.
    /// Sechs Minuten sind laenger als die meisten SID-Tunes und kurz genug,
    /// dass ein Loop-Tune nicht ewig stehen bleibt.
    public static let fallbackSeconds = 360.0

    public static func duration(databaseLengths: [Double]?,
                                subtune: Int,
                                computed: Double?,
                                fallback: Double = fallbackSeconds) -> Double {
        if let lengths = databaseLengths, subtune >= 0, subtune < lengths.count {
            return lengths[subtune]
        }
        if let computed { return computed }
        return fallback
    }
}
