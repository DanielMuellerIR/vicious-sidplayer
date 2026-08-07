import Foundation

// Import ganzer Ordner in die Bibliothek.
//
// Der Nutzer waehlt EINEN Ordner (Nextcloud, iCloud Drive, "Auf meinem iPhone"),
// und der Importer laeuft rekursiv hindurch, kopiert alles Spielbare in die
// Bibliothek und behaelt dabei die Unterordnerstruktur bei. Das ist der
// Gegenentwurf zum Teilen-Menue, das Dateien nur einzeln herausrueckt.
//
// Vier Dinge, die diesen Code ausmachen und die man beim Umbauen nicht
// wegoptimieren darf:
//
//  1. FEHLER PRO DATEI. Eine kaputte oder gesperrte Datei bricht NICHT den
//     ganzen Import ab. Sie landet im Bericht, der Rest laeuft weiter.
//  2. DEDUPE. Gleicher Zielpfad und gleicher Inhalt = ueberspringen. Gleicher
//     Zielpfad, anderer Inhalt = neuer, eindeutiger Name. Nie ueberschreiben.
//  3. PLATZHALTER. File Provider (iCloud, Nextcloud) liefern Eintraege, die im
//     Dateisystem sichtbar, aber lokal noch gar nicht vorhanden sind. Wer die
//     einfach kopiert, bekommt leere Dateien. Deshalb erst materialisieren,
//     dann koordiniert lesen.
//  4. ABBRECHBAR. Der Nutzer darf jederzeit abbrechen; was bis dahin kopiert
//     wurde, bleibt vollstaendig und ist danach im Index.

/// Fortschrittsmeldung waehrend des Imports.
public struct LibraryImportProgress: Sendable, Equatable {
    /// Wieviele Dateien sind fertig bearbeitet (importiert, uebersprungen oder
    /// fehlgeschlagen)?
    public let completed: Int
    /// Wieviele sind es insgesamt?
    public let total: Int
    /// Datei, die gerade an der Reihe ist (Dateiname ohne Pfad).
    public let currentFileName: String

    /// 0…1 fuer Fortschrittsbalken; bei leerem Import 1.
    public var fraction: Double {
        guard total > 0 else { return 1 }
        return min(1, Double(completed) / Double(total))
    }

    public init(completed: Int, total: Int, currentFileName: String) {
        self.completed = completed
        self.total = total
        self.currentFileName = currentFileName
    }
}

/// Warum eine Datei nicht importiert wurde, obwohl nichts kaputt war.
public enum LibraryImportSkipReason: String, Sendable, Codable {
    /// Inhaltsgleiche Datei liegt bereits am Zielort.
    case duplicate
}

/// Eine uebersprungene Datei.
public struct LibraryImportSkip: Sendable, Equatable {
    /// Pfad relativ zum gewaehlten Quellordner.
    public let sourceRelativePath: String
    public let reason: LibraryImportSkipReason

    public init(sourceRelativePath: String, reason: LibraryImportSkipReason) {
        self.sourceRelativePath = sourceRelativePath
        self.reason = reason
    }
}

/// Eine Datei, die nicht importiert werden konnte.
///
/// Der zugrundeliegende Fehler wird als Text mitgefuehrt statt als `Error`:
/// `any Error` ist nicht `Sendable`, der Bericht muss aber ueber
/// Task-Grenzen hinweg an die UI wandern.
public struct LibraryImportFailure: Sendable, Equatable {
    public enum Reason: String, Sendable, Codable {
        /// Quelle nicht lesbar (Rechte, defekter Datentraeger, …).
        case unreadable
        /// File-Provider-Platzhalter, den der Anbieter nicht heruntergeladen hat.
        case notMaterialized
        /// Lesen ging, Schreiben ins Ziel nicht (Platte voll, Rechte, …).
        case copyFailed
    }

    /// Pfad relativ zum gewaehlten Quellordner.
    public let sourceRelativePath: String
    public let reason: Reason
    /// Klartext des urspruenglichen Fehlers, fuer die Fehlerliste in der UI.
    public let message: String

    public init(sourceRelativePath: String, reason: Reason, message: String) {
        self.sourceRelativePath = sourceRelativePath
        self.reason = reason
        self.message = message
    }
}

/// Abschlussbericht eines Imports.
public struct LibraryImportReport: Sendable, Equatable {
    /// Zielpfade relativ zur Bibliothekswurzel — die stabilen IDs der neuen Eintraege.
    public let imported: [String]
    public let skipped: [LibraryImportSkip]
    public let failed: [LibraryImportFailure]
    /// Wurde der Import vorzeitig abgebrochen? Dann sind `imported` und Co.
    /// nur der bis dahin erreichte Stand — und der ist vollstaendig gueltig.
    public let wasCancelled: Bool

    public var importedCount: Int { imported.count }
    public var skippedCount: Int { skipped.count }
    public var failedCount: Int { failed.count }

    public init(imported: [String] = [],
                skipped: [LibraryImportSkip] = [],
                failed: [LibraryImportFailure] = [],
                wasCancelled: Bool = false) {
        self.imported = imported
        self.skipped = skipped
        self.failed = failed
        self.wasCancelled = wasCancelled
    }
}

/// Fehler, die den GESAMTEN Import unmoeglich machen (im Gegensatz zu
/// `LibraryImportFailure`, das einzelne Dateien betrifft).
public enum LibraryImportError: Error, Sendable, Equatable {
    /// Der gewaehlte Quellordner laesst sich nicht durchlaufen.
    case sourceUnreadable(String)
    /// Die Bibliothekswurzel existiert nicht und laesst sich nicht anlegen.
    case destinationUnavailable(String)
}

// Ohne `LocalizedError` liefert `error.localizedDescription` fuer einen eigenen
// Swift-Fehlertyp nur die generische Bruecken-Meldung von NSError ("The
// operation couldn't be completed."). Genau die zeigt die Oberflaeche aber an —
// der mitgefuehrte Ordnername beziehungsweise der Klartext des Systemfehlers
// ginge also verloren.
extension LibraryImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let name):
            return "Der Ordner „\(name)“ lässt sich nicht durchsuchen."
        case .destinationUnavailable(let message):
            return "Der Musikordner der App lässt sich nicht anlegen: \(message)"
        }
    }
}

/// Kopiert SID-Dateien in die Bibliothek.
public struct LibraryImporter: Sendable {

    /// Fortschritts-Callback.
    ///
    /// WICHTIG: laeuft auf dem Hintergrund-Task des Imports, NICHT auf dem
    /// Main-Actor. Wer damit UI aktualisiert, muss selbst auf den Main-Actor
    /// wechseln (`await MainActor.run { … }` oder `@MainActor`-Methode).
    public typealias ProgressHandler = @Sendable (LibraryImportProgress) -> Void

    /// Ein einzelner Kopierauftrag.
    private struct Job {
        let source: URL
        /// Pfad relativ zum Quellordner — dient zugleich als Zielpfad relativ
        /// zur Bibliothekswurzel und erhaelt so die Ordnerstruktur.
        let relativePath: String
        var fileName: String { source.lastPathComponent }
    }

    private let library: MusicLibrary

    public init(library: MusicLibrary) {
        self.library = library
    }

    // MARK: - Oeffentliche Einstiegspunkte

    /// Importiert einen Ordner rekursiv und behaelt die Unterordner bei.
    ///
    /// - Parameters:
    ///   - sourceFolder: vom Nutzer gewaehlter Ordner (darf security-scoped sein).
    ///   - progress: optionaler Fortschritt; siehe `ProgressHandler`.
    /// - Returns: Bericht ueber importiert / uebersprungen / fehlgeschlagen.
    /// - Throws: nur `LibraryImportError`, wenn gar nichts geht. Ein Abbruch
    ///   wirft NICHT, sondern liefert einen Bericht mit `wasCancelled == true` —
    ///   sonst wuesste die UI nicht, was bereits kopiert wurde.
    @discardableResult
    public func importFolder(at sourceFolder: URL,
                             progress: ProgressHandler? = nil) async throws -> LibraryImportReport {
        let scoped = beginSecurityScope(sourceFolder)
        defer { endSecurityScope(sourceFolder, scoped) }

        // Ein Abbruch schon waehrend des Zaehlens ist kein Fehler, sondern der
        // normale abgebrochene Bericht — genau wie ein Abbruch beim Kopieren.
        let collected: (jobs: [Job], failures: [LibraryImportFailure])
        do {
            collected = try collectJobs(in: sourceFolder)
        } catch is CancellationError {
            return LibraryImportReport(wasCancelled: true)
        }
        return try await run(jobs: collected.jobs,
                             traversalFailures: collected.failures,
                             progress: progress)
    }

    /// Importiert einzelne Dateien (Mehrfachauswahl, "Oeffnen mit", AirDrop).
    /// Sie landen flach in der Wurzel — es gibt keine Ordnerstruktur, die man
    /// erhalten koennte.
    @discardableResult
    public func importFiles(_ urls: [URL],
                            progress: ProgressHandler? = nil) async throws -> LibraryImportReport {
        let jobs = urls
            .filter { SidFileType.matches($0) }
            .map { Job(source: $0, relativePath: $0.lastPathComponent) }
        return try await run(jobs: jobs, traversalFailures: [], progress: progress)
    }

    // MARK: - Ablauf

    /// Sammelt alle SID-Dateien unterhalb des Quellordners.
    /// Sortiert, damit ein Import reproduzierbar in derselben Reihenfolge laeuft.
    ///
    /// Neben den Auftraegen kommen auch die Traversierungsfehler zurueck: ein
    /// Unterordner, den der Enumerator nicht betreten kann (Rechte, Provider
    /// kurz weg), darf nicht stillschweigend aus der Jobliste fehlen — sonst
    /// saehe ein Import erfolgreich aus, dem ein ganzer Teilbaum fehlt.
    ///
    /// - Throws: `CancellationError` bei Task-Abbruch waehrend des Zaehlens
    ///   (grosse File-Provider-Baeume koennen hier lange haengen), sonst
    ///   `LibraryImportError.sourceUnreadable`, wenn gar nichts geht.
    private func collectJobs(in folder: URL) throws -> (jobs: [Job], failures: [LibraryImportFailure]) {
        let fm = library.fileManager
        let rootComponents = LibraryPath.normalizedComponents(folder)

        // Fehler beim Betreten eines Unterordners landen hier statt im Nichts.
        // Das Closure wird vom Enumerator synchron waehrend der Schleife unten
        // gerufen; `true` heisst "weitermachen" — ein gesperrter Ast bricht
        // nicht den ganzen Import ab (Grundsatz 1 oben).
        var failures: [LibraryImportFailure] = []
        // Betrifft der Fehler die QUELLWURZEL selbst, ist nicht nur ein Ast
        // gesperrt, sondern der ganze Import unmoeglich. Das wird hier gemerkt
        // und nach der Schleife als Gesamtfehler geworfen.
        var rootUnreadable = false
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                guard let relative = LibraryPath.relativePath(of: url, underRootComponents: rootComponents) else {
                    // Nur die Quellwurzel liegt nicht UNTERHALB der Quellwurzel —
                    // daran erkennt man sie. `false` beendet die Enumeration.
                    rootUnreadable = true
                    return false
                }
                failures.append(LibraryImportFailure(
                    sourceRelativePath: relative,
                    reason: .unreadable,
                    message: error.localizedDescription))
                return true
            }
        ) else {
            throw LibraryImportError.sourceUnreadable(folder.lastPathComponent)
        }

        var jobs: [Job] = []
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            // Wie beim Bibliotheks-Scan: nicht bei jeder Datei den Task-Status
            // abfragen — alle 256 Eintraege reicht und kostet nichts. Ohne die
            // Pruefung reagierte "Abbrechen" waehrend der Zaehlphase erst nach
            // der kompletten Enumeration.
            if seen.isMultiple(of: 256) { try Task.checkCancellation() }

            guard SidFileType.matches(url) else { continue }
            // Ordner, die zufaellig auf ".sid" enden, sind keine Dateien.
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == false { continue }
            guard let relative = LibraryPath.relativePath(of: url, underRootComponents: rootComponents) else {
                continue
            }
            jobs.append(Job(source: url, relativePath: relative))
        }
        // Konnte gar nichts enumeriert werden, ist der dokumentierte
        // Gesamtfehler faellig. Ihn als einzelnen Dateifehler zu melden saehe
        // wie ein abgeschlossener Import aus und liesse in einer
        // Mehrfachauswahl die naechsten Auftraege weiterlaufen.
        if rootUnreadable {
            throw LibraryImportError.sourceUnreadable(folder.lastPathComponent)
        }
        jobs.sort { $0.relativePath < $1.relativePath }
        return (jobs, failures)
    }

    /// - Throws: nur `LibraryImportError.destinationUnavailable`, wenn die
    ///   Bibliothekswurzel fehlt und sich nicht anlegen laesst. Ein Task-Abbruch
    ///   wirft nicht, sondern liefert den Bericht mit `wasCancelled == true`.
    private func run(jobs: [Job],
                     traversalFailures: [LibraryImportFailure],
                     progress: ProgressHandler?) async throws -> LibraryImportReport {
        let fm = library.fileManager
        // Die Wurzel kann zwischen zwei Importen verschwunden sein (Reset,
        // Nutzer hat sie im Finder geloescht) — deshalb hier noch einmal anlegen.
        // Schlaegt das fehl UND die Wurzel fehlt wirklich, kann kein einziger
        // Auftrag gelingen: dann ist der dokumentierte Gesamtfehler faellig,
        // statt jede Datei einzeln mit "copyFailed" scheitern zu lassen.
        do {
            try fm.createDirectory(at: library.root, withIntermediateDirectories: true)
        } catch {
            var isDirectory: ObjCBool = false
            let rootExists = fm.fileExists(atPath: library.root.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            if !rootExists {
                throw LibraryImportError.destinationUnavailable(error.localizedDescription)
            }
        }

        var imported: [String] = []
        var skipped: [LibraryImportSkip] = []
        // Die beim Zaehlen eingesammelten Traversierungsfehler stehen mit im
        // Bericht — der Nutzer sieht so, dass (und wo) ein Teilbaum fehlt.
        var failed: [LibraryImportFailure] = traversalFailures
        var cancelled = false

        for (index, job) in jobs.enumerated() {
            do {
                try Task.checkCancellation()
            } catch {
                cancelled = true
                break
            }

            progress?(LibraryImportProgress(completed: index,
                                            total: jobs.count,
                                            currentFileName: job.fileName))

            let outcome: Outcome
            do {
                outcome = try await process(job)
            } catch {
                // `process` wirft ausschliesslich `CancellationError` weiter:
                // ein mitten im Materialisieren abgebrochener Auftrag ist kein
                // Dateifehler, sondern derselbe Abbruch wie oben.
                cancelled = true
                break
            }
            switch outcome {
            case .imported(let destination):
                imported.append(destination)
            case .skipped(let reason):
                skipped.append(LibraryImportSkip(sourceRelativePath: job.relativePath, reason: reason))
            case .failed(let reason, let message):
                failed.append(LibraryImportFailure(sourceRelativePath: job.relativePath,
                                                   reason: reason,
                                                   message: message))
            }
        }

        // Nur tatsaechlich bearbeitete Auftraege zaehlen. `failed` enthaelt auch
        // die Traversierungsfehler aus der Zaehlphase; die gehoeren zu keinem
        // Auftrag und ergaeben sonst Meldungen wie "8/7".
        let processed = imported.count + skipped.count + failed.count - traversalFailures.count
        progress?(LibraryImportProgress(completed: processed, total: jobs.count, currentFileName: ""))

        // Index angleichen — auch nach einem Abbruch. Genau das macht den
        // abgebrochenen Zustand konsistent: was kopiert wurde, ist danach
        // vollstaendig indiziert, nichts haengt halb in der Luft.
        //
        // Warum `Task.detached`: nach einem Abbruch ist DIESER Task als
        // "cancelled" markiert, und der Scan in `refresh()` bricht dann sofort
        // wieder ab — die eben kopierten Dateien landeten nie im Index. Ein
        // abgekoppelter Task erbt den Abbruchzustand nicht und laeuft durch.
        let library = self.library
        await Task.detached { _ = try? library.refresh() }.value

        return LibraryImportReport(imported: imported,
                                   skipped: skipped,
                                   failed: failed,
                                   wasCancelled: cancelled)
    }

    private enum Outcome {
        case imported(String)
        case skipped(LibraryImportSkipReason)
        case failed(LibraryImportFailure.Reason, String)
    }

    /// - Throws: nur `CancellationError` — jeder andere Fehler wird zum
    ///   per-Datei-Ergebnis `.failed` (Grundsatz 1: Fehler pro Datei).
    private func process(_ job: Job) async throws -> Outcome {
        let fm = library.fileManager

        // Einzeln gewaehlte Dateien bringen ihren eigenen Sicherheits-Scope mit.
        // Bei Kindern eines bereits geoeffneten Ordner-Scopes liefert das `false`
        // und ist damit ein Nichts-Tun — der Ordner-Scope deckt sie schon ab.
        let scoped = beginSecurityScope(job.source)
        defer { endSecurityScope(job.source, scoped) }

        // 1. Quelle lesen — inklusive Materialisieren von Platzhaltern.
        let data: Data
        do {
            data = try await materializedData(at: job.source)
        } catch is CancellationError {
            throw CancellationError()
        } catch is PlaceholderNotMaterializedError {
            return .failed(.notMaterialized,
                           "Der File Provider hat die Datei nicht innerhalb der Wartezeit bereitgestellt.")
        } catch let error as LibraryImportError {
            // Erreichbar ueber `coordinatedRead`: liefert `NSFileCoordinator`
            // weder Inhalt noch Fehler, wirft es `sourceUnreadable`. Das ist ein
            // LESEfehler dieser einen Datei — nicht ein nicht materialisierter
            // Platzhalter, wie hier frueher eingeordnet wurde.
            return .failed(.unreadable, error.localizedDescription)
        } catch {
            return .failed(.unreadable, error.localizedDescription)
        }

        // 2. Zielpfad bestimmen und dabei entscheiden: schon da, oder Kollision?
        let destination = library.url(forRelativePath: job.relativePath)
        switch resolveDestination(destination, sourceData: data) {
        case .duplicate:
            return .skipped(.duplicate)
        case .use(let target):
            // 3. Zielordner anlegen und atomar schreiben. Atomar heisst: erst in
            //    eine temporaere Datei, dann umbenennen. Ein Abbruch oder Absturz
            //    hinterlaesst so nie eine halb kopierte Datei in der Bibliothek.
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            } catch {
                return .failed(.copyFailed, error.localizedDescription)
            }
            let rootComponents = LibraryPath.normalizedComponents(library.root)
            let relative = LibraryPath.relativePath(of: target, underRootComponents: rootComponents)
            return .imported(relative ?? job.relativePath)
        }
    }

    // MARK: - Dedupe

    private enum Destination {
        /// Inhaltsgleiche Datei liegt schon da.
        case duplicate
        /// Diese URL benutzen (entweder frei oder mit angehaengter Nummer).
        case use(URL)
    }

    /// Entscheidet, wohin die Datei geschrieben wird.
    ///
    /// Geprueft werden der Wunschname und seine Varianten "Name-2.sid",
    /// "Name-3.sid" … Findet sich darunter eine Datei mit identischem Inhalt,
    /// ist die Datei schon da (auch wenn sie beim letzten Import umbenannt
    /// werden musste) und wird uebersprungen. Sonst gewinnt der erste freie Name.
    ///
    /// Der Inhaltsvergleich laeuft ueber die Dateigroesse als billigen Vorfilter
    /// und erst danach ueber MD5 — verschieden grosse Dateien koennen gar nicht
    /// gleich sein, und dann muss man sie auch nicht einlesen.
    private func resolveDestination(_ preferred: URL, sourceData: Data) -> Destination {
        let fm = library.fileManager
        guard fm.fileExists(atPath: preferred.path) else { return .use(preferred) }

        let sourceHash = MD5.hexString(of: sourceData)
        if isSameContent(preferred, size: sourceData.count, hash: sourceHash) { return .duplicate }

        let directory = preferred.deletingLastPathComponent()
        let base = preferred.deletingPathExtension().lastPathComponent
        let ext = preferred.pathExtension

        var suffix = 2
        while suffix < 10_000 {
            let candidate = directory
                .appendingPathComponent("\(base)-\(suffix)")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return .use(candidate) }
            if isSameContent(candidate, size: sourceData.count, hash: sourceHash) { return .duplicate }
            suffix += 1
        }

        // Praktisch unerreichbar; lieber ein garantiert freier Name als eine
        // Endlosschleife oder ein Ueberschreiben.
        return .use(directory
            .appendingPathComponent("\(base)-\(UUID().uuidString)")
            .appendingPathExtension(ext))
    }

    private func isSameContent(_ url: URL, size: Int, hash: String) -> Bool {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard values?.fileSize == size else { return false }
        guard let existing = try? Data(contentsOf: url) else { return false }
        return MD5.hexString(of: existing) == hash
    }

    // MARK: - File-Provider-Platzhalter

    /// Liest den Inhalt der Quelldatei und sorgt vorher dafuer, dass er
    /// ueberhaupt lokal vorliegt.
    ///
    /// Hintergrund: iCloud Drive und File Provider wie Nextcloud zeigen Dateien
    /// an, deren Inhalt noch auf dem Server liegt ("Platzhalter"). Ein einfaches
    /// `Data(contentsOf:)` liefert dann je nach Anbieter einen Fehler oder eine
    /// leere Datei. Deshalb: Downloadstatus pruefen, notfalls Download anstossen,
    /// warten — und anschliessend ueber `NSFileCoordinator` lesen, damit der
    /// Anbieter die Datei bereitstellt, statt sie unter uns wegzuziehen.
    ///
    /// Auf normalen lokalen Dateien (macOS-Tests, "Auf meinem iPhone") faellt
    /// der ganze Block einfach durch: `isUbiquitousItem` ist dort `false`.
    ///
    /// - Throws: `CancellationError` bei Task-Abbruch waehrend des Wartens,
    ///   `PlaceholderNotMaterializedError` nach Ablauf der Wartezeit. In beiden
    ///   Faellen wird bewusst NICHT mehr gelesen: der synchrone
    ///   `coordinatedRead` koennte an einem Provider ohne Inhalt haengen oder
    ///   eine leere Platzhalterdatei liefern.
    private func materializedData(at url: URL) async throws -> Data {
        #if canImport(Darwin)
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        if let values = try? url.resourceValues(forKeys: keys),
           values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            try? library.fileManager.startDownloadingUbiquitousItem(at: url)
            guard try await waitForDownload(url) else {
                throw PlaceholderNotMaterializedError()
            }
        }
        #endif
        return try coordinatedRead(url)
    }

    /// Der File Provider hat einen Platzhalter nicht rechtzeitig
    /// heruntergeladen. Interner Marker; `process` uebersetzt ihn in das
    /// per-Datei-Ergebnis `.failed(.notMaterialized, …)`.
    private struct PlaceholderNotMaterializedError: Error {}

    #if canImport(Darwin)
    /// Wartet, bis der File Provider die Datei lokal bereitgestellt hat.
    ///
    /// - Returns: `true`, sobald der Downloadstatus `.current` meldet;
    ///   `false` nach Ablauf von `timeout` Sekunden. Die drei Ausgaenge
    ///   (bereit / Timeout / Abbruch) sind bewusst unterscheidbar — frueher
    ///   kehrte die Funktion in allen drei Faellen gleich zurueck, und der
    ///   anschliessende Lesevorgang lief auch gegen nie gelieferte Inhalte.
    /// - Throws: `CancellationError` bei Task-Abbruch.
    private func waitForDownload(_ url: URL, timeout: TimeInterval = 15) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               values.ubiquitousItemDownloadingStatus == .current {
                return true
            }
            // 100 ms Pause: haeufig genug fuer fluessige Fortschrittsanzeige,
            // selten genug, um nicht sinnlos CPU zu verbrennen.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
    #endif

    /// Liest die Datei koordiniert (auf Apple-Plattformen) bzw. direkt (Linux,
    /// wo es weder File Provider noch `NSFileCoordinator` gibt).
    private func coordinatedRead(_ url: URL) throws -> Data {
        #if canImport(Darwin)
        var coordinatorError: NSError?
        var readResult: Result<Data, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [.withoutChanges],
            error: &coordinatorError
        ) { readableURL in
            readResult = Result { try Data(contentsOf: readableURL) }
        }
        if let coordinatorError { throw coordinatorError }
        switch readResult {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        case nil:
            throw LibraryImportError.sourceUnreadable(url.lastPathComponent)
        }
        #else
        return try Data(contentsOf: url)
        #endif
    }

    // MARK: - Security-Scoped Zugriff

    /// Oeffnet den Sicherheits-Scope einer vom Dokumenten-Picker gelieferten URL.
    ///
    /// Bei gewoehnlichen lokalen Datei-URLs (also in allen Tests auf dem Mac)
    /// liefert das `false` — dann gibt es auch nichts zu schliessen. Genau
    /// deshalb wird der Rueckgabewert mitgefuehrt und `stopAccessing…` nur bei
    /// `true` gerufen: unbalancierte Aufrufe zerschiessen sonst den Zaehler des
    /// Systems.
    private func beginSecurityScope(_ url: URL) -> Bool {
        #if canImport(Darwin)
        return url.startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }

    private func endSecurityScope(_ url: URL, _ started: Bool) {
        #if canImport(Darwin)
        if started { url.stopAccessingSecurityScopedResource() }
        #endif
    }
}
