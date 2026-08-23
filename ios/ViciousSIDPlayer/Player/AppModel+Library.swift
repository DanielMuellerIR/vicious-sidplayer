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
        loadSTIL()
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
        // Waehrend "Bibliothek zuruecksetzen" laeuft, keinen Abgleich starten:
        // der Scan liefe mitten durch das Loeschen und schriebe einen Index
        // aus halb geloeschten Dateien zurueck. Der Reset ruft nach seinem
        // Abschluss selbst `reloadLibrary` — dann ist `resetTask` schon `nil`.
        guard services.resetTask == nil else { return }
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
            // Hat ein zwischenzeitlich gestarteter Reset diesen Abgleich
            // abgebrochen, ist das Ergebnis veraltet: die Ansicht ist bereits
            // geleert und darf nicht mit dem alten Stand wiederbefuellt werden.
            guard !Task.isCancelled else { return }
            applyLibrary(tracks: snapshot.tracks, folderTree: snapshot.folderTree)

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
    /// - Returns: `false`, wenn der Auftrag gar nicht angenommen wurde (keine
    ///   Bibliothek, oder ein Zuruecksetzen laeuft). Die Oberflaeche ignoriert
    ///   das Ergebnis; `handleIncomingFile` braucht es.
    @discardableResult
    func importFolder(at url: URL) -> Bool {
        startImport(.folder(url))
    }

    /// Mehrfach-Dateiauswahl, „Oeffnen mit" und AirDrop. Diese Dateien landen
    /// flach in der Wurzel — es gibt keine Ordnerstruktur, die zu erhalten waere.
    @discardableResult
    func importFiles(at urls: [URL]) -> Bool {
        startImport(.files(urls))
    }

    /// Eine von aussen an die App uebergebene Datei („Oeffnen mit", AirDrop,
    /// Dateien-App). Kommt ueber `.onOpenURL` am App-Einstieg herein.
    ///
    /// Drei Herkuenfte:
    ///  - Bereits in der Bibliothek: der Nutzer hat in der Dateien-App einen
    ///    eigenen Titel geoeffnet. Dann wird NICHT importiert, sonst entstuende
    ///    eine flache zweite Kopie in der Wurzel.
    ///  - „Open in place" (Info.plist erlaubt es): die URL zeigt auf das
    ///    Original beim Absender; der Importer oeffnet den Sicherheits-Scope
    ///    und KOPIERT — das Original bleibt unangetastet.
    ///  - System-Inbox: manche Uebergaben (z.B. AirDrop) legt iOS vorher als
    ///    Kopie in `Documents/Inbox/` ab. Weil `Documents/` zugleich die
    ///    Bibliothekswurzel ist, wuerde diese Kopie beim naechsten Abgleich
    ///    als eigener „Inbox/…"-Titel doppelt auftauchen. Solche Quellen
    ///    werden deshalb nach erfolgreichem Import aufgeraeumt
    ///    (`cleanupImportedInboxFiles`).
    func handleIncomingFile(at url: URL) {
        guard SidFileType.matches(url) else {
            // Sollte nicht vorkommen — die App registriert nur den SID-Typ.
            // Trotzdem sauber melden statt still zu schlucken.
            errorMessage = "\(url.lastPathComponent) ist keine SID-Datei."
            return
        }
        let inbox = services.library?.root
            .appendingPathComponent(MusicLibraryLocation.inboxFolderName, isDirectory: true)
        let isInboxCopy = inbox.map { LibraryReset.isContained(url, in: $0) } ?? false

        // Liegt die Datei bereits IN der Bibliothek (der Nutzer hat in der
        // Dateien-App einen eigenen Titel geoeffnet), waere ein Import falsch:
        // `importFiles` legt jede Datei FLACH in der Wurzel ab, aus
        // "Documents/Komponist/tune.sid" wuerde also eine zweite Kopie
        // "Documents/tune.sid" samt Doppeleintrag. Stattdessen den vorhandenen
        // Titel unter seinem relativen Pfad bereitstellen.
        if !isInboxCopy, let relative = services.library?.relativePath(for: url) {
            // Nicht von selbst losspielen — dieselbe Zurueckhaltung wie bei der
            // Sitzungswiederherstellung.
            loadTrack(id: relative, autoplay: false)
            // Von aussen abgelegte Dateien stehen vielleicht noch nicht im
            // Index; der Abgleich holt sie nach.
            refreshLibrary()
            return
        }

        // Zum Aufraeumen erst vormerken, wenn der Import wirklich angenommen
        // ist. Sonst bliebe die Vormerkung nach einem abgelehnten Auftrag
        // liegen und ein spaeterer, ganz anderer Import loeschte die Datei,
        // ohne sie je importiert zu haben.
        guard importFiles(at: [url]) else { return }
        if isInboxCopy { services.pendingInboxCleanup.append(url) }
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

    /// - Returns: `true`, wenn der Auftrag laeuft oder in der Warteschlange
    ///   steht; `false`, wenn er abgelehnt wurde.
    @discardableResult
    private func startImport(_ job: PendingImportJob) -> Bool {
        guard let library = services.library else {
            errorMessage = "Der Musikordner der App ist nicht erreichbar."
            return false
        }
        // Fail-closed: waehrend "Bibliothek zuruecksetzen" laeuft, startet kein
        // Import. Sonst kopierte er in einen Ordner, den der Reset gerade
        // leert — die frisch importierten Dateien waeren sofort wieder weg.
        guard services.resetTask == nil else {
            errorMessage = "Die Bibliothek wird gerade zurückgesetzt. Bitte danach erneut importieren."
            return false
        }
        // Zwei Importe gleichzeitig waeren nicht falsch, aber unuebersichtlich:
        // ein Fortschrittsbalken, zwei Quellen. Ein zweiter Auftrag wird deshalb
        // nicht verworfen, sondern angestellt — das ist genau der Fall
        // „mehrere Ordner auf einmal ausgewaehlt", bei dem die Oberflaeche
        // `importFolder(at:)` mehrfach hintereinander ruft. Wuerde hier nur der
        // erste durchgehen, verschwaende der Rest kommentarlos.
        guard importTask == nil else {
            services.pendingImportJobs.append(job)
            return true
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
        return true
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
        cleanupImportedInboxFiles()
        if services.importTally.hasResult {
            lastImportReport = services.importTally.report
        }
        services.importTally = ImportTally()

        // Der Importer hat den Index bereits abgeglichen; hier wird nur noch die
        // Ansicht daraus neu aufgebaut.
        reloadLibrary(restoreSession: false)
    }

    /// Raeumt System-Inbox-Kopien auf, deren Import durch ist (siehe
    /// `handleIncomingFile`). Fehlgeschlagene oder abgebrochene bleiben
    /// liegen — sonst waere die Datei komplett verloren. Uebersprungene
    /// (Duplikat) duerfen weg: ihr Inhalt liegt bereits in der Bibliothek.
    private func cleanupImportedInboxFiles() {
        let candidates = services.pendingInboxCleanup
        services.pendingInboxCleanup = []
        guard !candidates.isEmpty, let library = services.library else { return }

        let tally = services.importTally
        // Nach einem HARTEN Fehler bleibt alles liegen. Ein solcher Fehler
        // betrifft einen ganzen Auftrag, taucht also in keiner dateibezogenen
        // Fehlerliste auf — und die Warteschlange der noch gar nicht
        // ausgefuehrten Auftraege wurde eben verworfen. Ohne diese Bremse
        // loeschte der Aufraeumer deren Inbox-Originale, obwohl sie nie
        // importiert wurden (Review-Fund 2026-08-07).
        guard !tally.hadFailure else { return }

        let inbox = library.root
            .appendingPathComponent(MusicLibraryLocation.inboxFolderName, isDirectory: true)
        for url in candidates {
            if tally.wasCancelled { continue }
            // Die Fehlerliste traegt pro Datei "Quellpfad: Meldung"; bei
            // Einzeldateien ist der Quellpfad der blosse Dateiname.
            if tally.failed.contains(where: { $0.hasPrefix(url.lastPathComponent + ":") }) { continue }
            // `LibraryReset.remove` prueft noch einmal, dass wirklich nur
            // unterhalb von Inbox geloescht wird, und ist idempotent.
            try? LibraryReset.remove(url, under: inbox, fm: fileManager)
        }
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
        // Zuruecksetzen ist eine exklusive Operation und darf sich nicht selbst
        // ueberholen. Ein zweiter Aufruf wuerde `services.resetTask`
        // ueberschreiben: der zuerst gestartete Task setzt den Griff am Ende auf
        // `nil` und startet einen Abgleich, waehrend der zweite noch loescht —
        // die Sperren in `startImport` und `reloadLibrary` saehen dann keinen
        // laufenden Reset mehr (Review-Fund 2026-08-07).
        guard services.resetTask == nil else {
            errorMessage = "Die Bibliothek wird bereits zurückgesetzt."
            return
        }

        // Erst alles anhalten, was noch auf die alten Dateien zugreift.
        // `cancel()` ist dabei nur das Signal — WARTEN muss der Hintergrund-
        // Task unten, sonst schreibt ein noch laufender Kopierauftrag nach dem
        // Loeschen eine Datei zurueck oder ein laufender Scan speichert den
        // alten Index wieder ab. Deshalb werden die Tasks hier eingesammelt.
        //
        // Die Griffe werden VOR dem Abbrechen gesichert: `cancelLengthEstimate()`
        // setzt `lengthEstimateTask` selbst auf `nil`, danach gaebe es nichts
        // mehr abzuwarten — und der Schaetzer koennte sein Ergebnis noch nach
        // dem `cache.clear()` weiter unten in den Cache schreiben.
        let runningImport = importTask
        let runningReload = services.libraryReloadTask
        let runningEstimate = lengthEstimateTask
        cancelImport()
        cancelLengthEstimate()
        services.libraryReloadTask?.cancel()
        stopPlaybackLoop()
        coordinator.stop()
        services.nowPlaying.clear()

        // Zustand des laufenden Titels aufloesen.
        setCurrentTrackID(nil)
        currentMD5 = nil
        currentTrackLengths = nil
        computedLength = nil
        clearSessionState()
        // Die Favoriten werden bewusst NICHT hier geleert, sondern erst nach
        // einem erfolgreichen Core-Reset (siehe unten): scheitert der, bleiben
        // Musikdateien und Index stehen — geloeschte Favoriten waeren dann
        // dauerhafter Datenverlust ohne Gegenwert (Review-Fund 2026-08-07).

        // Die Ansicht sofort leeren, damit nicht sekundenlang Titel dastehen,
        // deren Dateien gerade geloescht werden.
        applyLibrary(tracks: [], folderTree: AppModel.emptyFolderTree)

        // Das eigentliche Loeschen laeuft im Hintergrund — bei einer grossen
        // Sammlung dauert es spuerbar. Der Task wird festgehalten, damit
        // ueberhaupt jemand erkennen kann, wann er fertig ist; ohne diesen
        // Griff waere „Zuruecksetzen" ein Vorgang ohne beobachtbares Ende.
        // Solange er laeuft, blocken `startImport` und `reloadLibrary` neue
        // Bibliotheksoperationen — Reset ist eine exklusive Operation.
        let cache = lengthCache
        services.resetTask = Task.detached(priority: .utility) { [self] in
            // Die oben abgebrochenen Tasks WIRKLICH zu Ende gehen lassen,
            // bevor geloescht wird. `value` ist hier reines Warten — alle drei
            // sind `Task<Void, Never>` und raeumen selbst hinter sich auf.
            await runningImport?.value
            await runningReload?.value
            await runningEstimate?.value

            // `clearFavorites: nil` — die Favoriten liegen in den
            // Benutzereinstellungen und werden unten auf dem MainActor
            // behandelt. Der Core soll sie nicht ein zweites Mal anfassen.
            let message: String?
            do {
                _ = try LibraryReset.run(library: library, clearFavorites: nil)
                message = nil
            } catch {
                message = error.localizedDescription
            }
            // Auch die langlebige Cache-INSTANZ leeren: `LibraryReset` loescht
            // nur die Datei; das Dictionary im Speicher wuerde die alten
            // Laengen beim naechsten `store` komplett wieder hinschreiben.
            cache.clear()

            await MainActor.run {
                self.services.resetTask = nil
                if let message {
                    self.errorMessage = "Zurücksetzen fehlgeschlagen: \(message)"
                } else if !keepFavorites {
                    // Erst jetzt: der Core-Reset ist durch, die Titel sind weg.
                    self.setFavorites([])
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
    let folderTree: MusicLibraryFolder

    init(entries: [MusicLibraryEntry]) {
        tracks = entries.map {
            LibraryTrack(id: $0.relativePath, name: $0.displayName, folderPath: $0.folderPath)
        }
        folderTree = MusicLibrary.folderTree(for: entries)
    }
}
