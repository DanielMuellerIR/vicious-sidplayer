import Foundation
import ViciousSIDPlayerCore

// Die Bibliothekshaelfte des AppModels: Start, Abgleich, Import, Zuruecksetzen.
//
// Die eigentliche Arbeit (Scannen, Kopieren, Loeschen, Pfadsicherheit) steckt im
// Core unter `Sources/ViciousSIDPlayerCore/Library/`. Diese Datei ist die
// Bruecke: sie startet die Core-Vorgaenge abseits des Hauptthreads und bringt
// die Ergebnisse als sichtbaren Zustand zurueck.
//
// Warum ueberhaupt „abgleichen"? Weil die Bibliothek auf iOS in `Documents/`
// liegt und damit ueber die Finder-Dateifreigabe und die Dateien-App von aussen
// erreichbar ist. Der Nutzer kann dort Ordner hineinziehen oder loeschen,
// waehrend die App gar nicht laeuft. Der gespeicherte Index ist deshalb nur eine
// Zwischenablage — die Wahrheit steht im Dateisystem.
extension AppModel {

    // MARK: - Start

    /// Einmaliger Start beim ersten Erscheinen der App.
    ///
    /// Reihenfolge mit Bedacht: erst die Systemdienste (Audio-Sitzung,
    /// Sperrbildschirm), dann die Songlaengen-Datenbank, dann die Bibliothek.
    /// Die Sitzungswiederherstellung braucht die geladene Bibliothek und haengt
    /// deshalb hinten am Bibliotheksladen.
    ///
    /// Idempotent: SwiftUI kann `onAppear`/`task` mehrfach ausloesen, ein
    /// zweiter Aufruf darf nichts anfassen.
    func start() {
        guard !services.didStart else { return }
        services.didStart = true

        configureSystemPlayback()
        // Die Lautstaerke aus den Einstellungen an die Audio-Engine geben; der
        // `didSet` in AppModel greift nur bei spaeteren Aenderungen.
        coordinator.setVolume(volume)

        loadSonglengthDB()
        reloadLibrary(restoreSession: true)
    }

    // MARK: - Abgleich mit dem Dateisystem

    /// Gleicht den Index gegen das Dateisystem ab und aktualisiert die Ansicht.
    ///
    /// Laeuft komplett abseits des Hauptthreads: ein Scan ueber eine grosse
    /// Sammlung (die HVSC hat mehr als 50.000 Dateien) dauert Sekunden, und in
    /// dieser Zeit darf die Oberflaeche nicht stehen.
    func refreshLibrary() {
        reloadLibrary(restoreSession: false)
    }

    /// Gemeinsamer Kern von `start()` und `refreshLibrary()`.
    ///
    /// - Parameter restoreSession: nur beim allerersten Laden `true`. Danach
    ///   waere ein Wiederherstellen falsch — der Nutzer hoert ja gerade etwas.
    func reloadLibrary(restoreSession: Bool) {
        guard let library = services.library else {
            errorMessage = "Der Musikordner der App ist nicht erreichbar."
            return
        }
        // Laeuft schon ein Abgleich, nicht noch einen danebenstellen. Das kommt
        // in der Praxis vor: App startet und wechselt sofort in den Vordergrund.
        guard services.libraryReloadTask == nil else { return }

        services.libraryReloadTask = Task { [self] in
            // `Task.detached` haelt die Dateiarbeit sicher vom Hauptthread fern;
            // `MusicLibrary` ist dafuer ausgelegt (interne Sperre um den Index).
            let snapshot = await Task.detached(priority: .utility) { () -> LibrarySnapshot in
                // Ein Fehler beim Abgleich ist kein Grund aufzugeben: dann bleibt
                // eben der zuletzt bekannte Index stehen.
                _ = try? library.refresh()
                return LibrarySnapshot(entries: library.entries)
            }.value

            services.libraryReloadTask = nil
            applyLibrary(tracks: snapshot.tracks, folderTree: snapshot.folderTree)
            services.didLoadLibraryOnce = true

            if restoreSession {
                restoreSessionIfPossible()
            }
        }
    }

    // MARK: - Import

    /// Rekursiver Ordner-Import. Die Unterordnerstruktur bleibt erhalten.
    ///
    /// Der Sicherheits-Scope der vom Dateiauswahl-Dialog gelieferten URL wird im
    /// Core geoeffnet und geschlossen (`LibraryImporter.importFolder`), damit er
    /// genau so lange offen ist wie das Kopieren dauert. Hier nichts doppelt tun:
    /// die Zaehler des Systems muessen paarweise aufgehen.
    func importFolder(at url: URL) {
        startImport(.folder(url))
    }

    /// Mehrfach-Dateiauswahl, „Oeffnen mit" und AirDrop. Diese Dateien landen
    /// flach in der Wurzel — es gibt keine Ordnerstruktur, die zu erhalten waere.
    func importFiles(at urls: [URL]) {
        startImport(.files(urls))
    }

    /// Bricht einen laufenden Import ab. Was bis dahin kopiert wurde, bleibt
    /// vollstaendig und ist danach im Index — dafuer sorgt der Core.
    func cancelImport() {
        // Auch die noch nicht begonnenen Auftraege wegwerfen — „Abbrechen"
        // heisst fuer den Nutzer die ganze Aktion, nicht nur den gerade
        // laufenden Ordner.
        services.pendingImportJobs.removeAll()
        importTask?.cancel()
    }

    private func startImport(_ job: PendingImportJob) {
        guard let library = services.library else {
            errorMessage = "Der Musikordner der App ist nicht erreichbar."
            return
        }
        // Zwei Importe gleichzeitig waeren nicht falsch, aber unuebersichtlich:
        // ein Fortschrittsbalken, zwei Quellen. Ein zweiter Auftrag wird deshalb
        // nicht verworfen, sondern angestellt — das ist genau der Fall
        // „mehrere Ordner auf einmal ausgewaehlt", bei dem die Oberflaeche
        // `importFolder(at:)` mehrfach hintereinander ruft. Wuerde hier nur der
        // erste durchgehen, verschwaende der Rest kommentarlos.
        guard importTask == nil else {
            services.pendingImportJobs.append(job)
            return
        }

        lastImportReport = nil
        services.importTally = ImportTally()
        // Fortschritt sofort setzen, damit die Oberflaeche schon waehrend des
        // Zaehlens der Dateien etwas anzeigt (`total == 0` heisst „zaehlt noch").
        setImportProgress(ImportProgress(current: 0, total: 0, currentFile: ""))

        importTask = Task.detached(priority: .utility) { [self] in
            let importer = LibraryImporter(library: library)

            // Der Fortschritts-Block laeuft im Hintergrund-Task des Importers.
            // Jede Meldung wuerde einen eigenen Sprung auf den MainActor kosten;
            // bei tausenden Dateien ist das viel Aufwand fuer eine Anzeige, die
            // niemand in dieser Aufloesung liest. Deshalb nur jede achte Datei —
            // und die letzte, damit der Balken sauber ausläuft.
            let handler: LibraryImporter.ProgressHandler = { progress in
                guard progress.completed.isMultiple(of: 8) || progress.completed == progress.total else {
                    return
                }
                let snapshot = ImportProgress(current: progress.completed,
                                              total: progress.total,
                                              currentFile: progress.currentFileName)
                Task { @MainActor in self.setImportProgress(snapshot) }
            }

            let outcome: PendingImportOutcome
            do {
                switch job {
                case .folder(let url):
                    outcome = .finished(try await importer.importFolder(at: url, progress: handler))
                case .files(let urls):
                    outcome = .finished(try await importer.importFiles(urls, progress: handler))
                }
            } catch {
                outcome = .failed(error.localizedDescription)
            }

            await MainActor.run { self.finishImport(outcome) }
        }
    }

    private func finishImport(_ outcome: PendingImportOutcome) {
        importTask = nil

        switch outcome {
        case .finished(let report):
            services.importTally.add(report)
        case .failed(let message):
            errorMessage = "Import fehlgeschlagen: \(message)"
            services.importTally.hadFailure = true
        }

        // Steht noch ein Auftrag an (Mehrfachauswahl von Ordnern), gleich den
        // naechsten starten — ohne Zwischenbericht, sonst blitzt fuer jeden
        // Ordner ein eigenes Ergebnis auf. Nach einem Abbruch oder einem harten
        // Fehler wird die Warteschlange verworfen.
        let mayContinue = !services.importTally.wasCancelled && !services.importTally.hadFailure
        if mayContinue, !services.pendingImportJobs.isEmpty {
            let next = services.pendingImportJobs.removeFirst()
            continueImport(next)
            return
        }
        services.pendingImportJobs.removeAll()

        setImportProgress(nil)
        if services.importTally.hasResult {
            lastImportReport = services.importTally.report
        }
        services.importTally = ImportTally()

        // Der Importer hat den Index bereits abgeglichen; hier wird nur noch die
        // Ansicht daraus neu aufgebaut.
        reloadLibrary(restoreSession: false)
    }

    /// Naechsten angestellten Auftrag starten, ohne die bisher gesammelten
    /// Zahlen zu verwerfen. `startImport` wuerde sie zuruecksetzen.
    private func continueImport(_ job: PendingImportJob) {
        let tally = services.importTally
        startImport(job)
        services.importTally = tally
    }

    // MARK: - Zuruecksetzen

    /// „Alles wegwerfen und neu vom Mac holen."
    ///
    /// Geloescht werden Bibliotheksinhalt, Index und die berechneten
    /// Songlaengen; die Favoriten nur auf Wunsch. Der `Documents`-Ordner selbst
    /// bleibt bestehen — ohne ihn funktionierte weder die Finder-Dateifreigabe
    /// noch der naechste Import.
    func resetLibrary(keepFavorites: Bool) {
        guard let library = services.library else {
            errorMessage = "Der Musikordner der App ist nicht erreichbar."
            return
        }

        // Erst alles anhalten, was noch auf die alten Dateien zugreift.
        cancelImport()
        cancelLengthEstimate()
        stopPlaybackLoop()
        coordinator.stop()
        services.nowPlaying.clear()

        // Zustand des laufenden Titels aufloesen.
        setCurrentTrackID(nil)
        currentMD5 = nil
        currentTrackLengths = nil
        computedLength = nil
        clearSessionState()
        if !keepFavorites { setFavorites([]) }

        // Die Ansicht sofort leeren, damit nicht sekundenlang Titel dastehen,
        // deren Dateien gerade geloescht werden.
        applyLibrary(tracks: [], folderTree: .empty)

        // Das eigentliche Loeschen laeuft im Hintergrund — bei einer grossen
        // Sammlung dauert es spuerbar. Der Task wird festgehalten, damit
        // ueberhaupt jemand erkennen kann, wann er fertig ist; ohne diesen
        // Griff waere „Zuruecksetzen" ein Vorgang ohne beobachtbares Ende.
        services.resetTask = Task.detached(priority: .utility) { [self] in
            // `clearFavorites: nil` — die Favoriten liegen in den
            // Benutzereinstellungen und wurden oben schon auf dem MainActor
            // behandelt. Der Core soll sie nicht ein zweites Mal anfassen.
            let message: String?
            do {
                _ = try LibraryReset.run(library: library, clearFavorites: nil)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            await MainActor.run {
                self.services.resetTask = nil
                if let message {
                    self.errorMessage = "Zurücksetzen fehlgeschlagen: \(message)"
                }
                self.reloadLibrary(restoreSession: false)
            }
        }
    }
}

// MARK: - Auftrag und Ergebnis eines Imports

// Beide Typen stehen bewusst AUSSERHALB der `AppModel`-Erweiterung. `AppModel`
// ist `@MainActor`; in Swift uebertraegt sich diese Isolation auf verschachtelte
// Typen. Sie wandern hier aber gerade ueber die Grenze zu einem
// Hintergrund-Task — dafuer muessen sie frei von Aktor-Isolation sein.

/// Woher kommen die zu importierenden Dateien?
enum PendingImportJob: Sendable {
    case folder(URL)
    case files([URL])
}

/// Ergebnis eines Imports in einer Form, die ueber Task-Grenzen darf.
/// Der urspruengliche `Error` bleibt bewusst zurueck: `any Error` ist nicht
/// `Sendable`, sein Klartext schon.
enum PendingImportOutcome: Sendable {
    case finished(LibraryImportReport)
    case failed(String)
}

/// Sammelt die Zahlen mehrerer nacheinander abgearbeiteter Import-Auftraege.
///
/// Warum das noetig ist: waehlt der Nutzer im Ordner-Dialog drei Ordner aus,
/// ruft die Oberflaeche `importFolder(at:)` dreimal. Ohne Sammler bekaeme er
/// drei kurz aufblitzende Berichte hintereinander statt einer Zahl, die die
/// ganze Aktion beschreibt.
struct ImportTally {
    private(set) var imported = 0
    private(set) var skipped = 0
    private(set) var failed: [String] = []
    private(set) var wasCancelled = false
    /// Ein Auftrag ist gar nicht erst gelaufen (Quelle unlesbar o.ae.).
    var hadFailure = false

    /// Gibt es ueberhaupt etwas zu berichten?
    var hasResult: Bool {
        imported > 0 || skipped > 0 || !failed.isEmpty || wasCancelled
    }

    mutating func add(_ report: LibraryImportReport) {
        imported += report.importedCount
        skipped += report.skippedCount
        // Pro Datei eine lesbare Zeile: erst der Pfad in der Quelle, dann der
        // Klartext des Fehlers.
        failed.append(contentsOf: report.failed.map { "\($0.sourceRelativePath): \($0.message)" })
        if report.wasCancelled { wasCancelled = true }
    }

    var report: ImportReport {
        ImportReport(imported: imported, skipped: skipped, failed: failed, wasCancelled: wasCancelled)
    }
}

// MARK: - Umbau der Core-Daten in Ansichtsdaten

/// Momentaufnahme der Bibliothek in genau der Form, die die Oberflaeche braucht.
///
/// Wird komplett im Hintergrund gebaut — auch der Ordnerbaum, denn bei einer
/// grossen Sammlung ist schon das Gruppieren spuerbar. Alle Bestandteile sind
/// `Sendable`, damit das Ergebnis anschliessend auf den MainActor darf.
struct LibrarySnapshot: Sendable {
    let tracks: [LibraryTrack]
    let folderTree: LibraryFolder

    init(entries: [MusicLibraryEntry]) {
        tracks = entries.map {
            LibraryTrack(id: $0.relativePath, name: $0.displayName, folderPath: $0.folderPath)
        }
        folderTree = LibrarySnapshot.convert(MusicLibrary.folderTree(for: entries))
    }

    /// Der Core-Ordnerbaum traegt die vollstaendigen Eintraege; die Ansicht
    /// braucht davon nur die stabilen IDs und schlaegt den Rest in `tracks` nach.
    private static func convert(_ folder: MusicLibraryFolder) -> LibraryFolder {
        LibraryFolder(
            id: folder.path,
            name: folder.name,
            subfolders: folder.subfolders.map(convert),
            trackIDs: folder.entries.map(\.relativePath)
        )
    }
}
