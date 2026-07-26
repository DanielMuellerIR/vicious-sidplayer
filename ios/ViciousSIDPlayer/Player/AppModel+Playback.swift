import Foundation
import ViciousSIDPlayerCore

// Die Wiedergabehaelfte des AppModels: Transport, Songlaengen, Sperrbildschirm,
// Sitzung und WAV-Export.
//
// Der eigentliche Emulator und die Audio-Engine stecken im `ViciousCoordinator`
// (Core). Diese Datei entscheidet, WANN etwas gespielt wird, WIE lange ein
// Stueck dauert und WAS auf dem Sperrbildschirm steht.
//
// Der wichtigste Unterschied zur Mac-App steht weiter unten beim
// `playbackLoop`: auf dem iPhone ist der Bildschirm meistens aus, und dann gibt
// es keine Oberflaeche, die irgendetwas nachhaelt. Alles, was auch im
// Hintergrund passieren muss, haengt deshalb an einem eigenen, sparsamen Lauf.
extension AppModel {

    // MARK: - Titel laden

    /// Laedt einen Titel und spielt ihn ab.
    func play(trackID: String) {
        loadTrack(id: trackID, autoplay: true)
    }

    /// Gemeinsamer Ladeweg. Entspricht `loadTrack(index:autoplay:)` der Mac-App.
    ///
    /// Die Reihenfolge ist mit Absicht so: erst lesen und parsen, DANN den
    /// laufenden Zustand ersetzen. Eine defekte Datei hinterlaesst so keinen
    /// halb aktualisierten Player, in dem der alte Titel weiterlaeuft, aber der
    /// neue Name dransteht.
    @discardableResult
    func loadTrack(id: String, autoplay: Bool) -> Bool {
        guard let fileURL = trackURL(for: id) else {
            errorMessage = "Der Titel ist nicht mehr vorhanden."
            return false
        }

        // Die Datei liegt im eigenen App-Container, dort braucht es keinen
        // Sicherheits-Scope. Der Aufruf kostet nichts und deckt zusaetzlich den
        // Fall ab, dass ein Titel spaeter einmal von aussen geoeffnet wird.
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            // Synchrones Lesen ist hier vertretbar: eine SID-Datei passt in den
            // 64-KB-Speicher eines C64, ist also winzig.
            let data = try Data(contentsOf: fileURL)
            let sidFile = try SidParser.parse(data: data)

            cancelLengthEstimate()
            coordinator.stop()
            setCurrentTrackID(id)
            coordinator.setSid(sidFile)
            coordinator.setVolume(volume)

            // Songlaenge aufloesen. Der MD5 der ganzen Datei ist der Schluessel
            // sowohl der HVSC-Datenbank als auch des berechneten Caches.
            let md5 = SonglengthDB.md5Hex(of: data)
            currentMD5 = md5
            currentTrackLengths = songlengthDB?.lengths(forMD5: md5)
            resolveComputedLengthIfNeeded()

            errorMessage = nil
            if autoplay { startPlayback() }

            services.lastSessionBucket = -1
            saveSessionState()
            syncPlaybackLoop()
            updateNowPlaying(force: true)
            return true
        } catch {
            errorMessage = "Datei konnte nicht gelesen werden: \(error.localizedDescription)"
            return false
        }
    }

    /// Absolute URL eines Titels, oder `nil`, wenn die Datei verschwunden ist
    /// (der Nutzer kann sie ueber die Dateifreigabe jederzeit loeschen).
    func trackURL(for id: String) -> URL? {
        guard let library = services.library else { return nil }
        let url = library.url(forRelativePath: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Transport

    func togglePlayPause() {
        if coordinator.isPlaying {
            coordinator.pause()
        } else if currentTrackID != nil {
            startPlayback()
        } else if let first = visibleTracks.first {
            // Noch nichts geladen: mit dem ersten sichtbaren Titel anfangen.
            loadTrack(id: first.id, autoplay: true)
            return
        } else {
            return
        }
        syncPlaybackLoop()
        updateNowPlaying(force: true)
        saveSessionState()
    }

    /// Naechster Titel in der sichtbaren Liste — also nach Suche und
    /// Favoritenfilter, genau in der Reihenfolge, die der Nutzer gerade sieht.
    /// Bei aktiver Zufallswiedergabe stattdessen ein zufaelliger anderer.
    func playNext() {
        guard let id = neighbourTrackID(offset: 1, shuffled: shuffle) else { return }
        loadTrack(id: id, autoplay: coordinator.isPlaying)
    }

    /// Vorheriger Titel. Bewusst IMMER der Reihenfolge nach, auch bei aktiver
    /// Zufallswiedergabe — „zurueck" soll dorthin fuehren, wo man herkommt, und
    /// nicht wieder irgendwohin. Genauso macht es die Mac-App.
    func playPrevious() {
        guard let id = neighbourTrackID(offset: -1, shuffled: false) else { return }
        loadTrack(id: id, autoplay: coordinator.isPlaying)
    }

    /// Nachbar in der sichtbaren Liste.
    /// - Parameters:
    ///   - offset: +1 fuer vorwaerts, -1 fuer rueckwaerts (mit Umlauf).
    ///   - shuffled: `true` waehlt stattdessen einen zufaelligen anderen Titel.
    private func neighbourTrackID(offset: Int, shuffled: Bool) -> String? {
        let list = visibleTracks
        guard !list.isEmpty else { return nil }

        if shuffled && list.count > 1 {
            var index = Int.random(in: 0..<list.count)
            // Denselben Titel noch einmal zu ziehen faende der Nutzer kaputt.
            if list[index].id == currentTrackID {
                index = (index + 1) % list.count
            }
            return list[index].id
        }

        guard let current = currentTrackID,
              let index = list.firstIndex(where: { $0.id == current }) else {
            // Der laufende Titel ist gar nicht sichtbar (Suche, Favoritenfilter):
            // dann faengt die Liste von vorn an.
            return list.first?.id
        }
        let target = (index + offset + list.count) % list.count
        return list[target].id
    }

    /// Springt an eine absolute Position, begrenzt auf [0, Songdauer].
    func seek(to seconds: Double) {
        let target = min(max(0, seconds), currentDuration)
        coordinator.seek(seconds: target)
        services.lastSessionBucket = -1
        saveSessionState()
        updateNowPlaying(force: true)
    }

    /// Relatives Springen, z.B. `-10` oder `+30`. Funktioniert auch im
    /// pausierten und im gestoppten Zustand — der Coordinator puffert die
    /// Zielposition dann bis zum naechsten Start.
    func skip(by delta: Double) {
        seek(to: coordinator.elapsedSeconds + delta)
    }

    /// Waehlt einen Subtune derselben Datei.
    func setSubtune(_ index: Int) {
        guard index >= 0, index < coordinator.subtunesCount else { return }
        coordinator.setSubtune(sub: index)
        // Die Laenge gilt je Subtune: der DB-Eintrag wird neu indiziert, eine
        // berechnete Laenge muss komplett neu ermittelt werden.
        computedLength = nil
        resolveComputedLengthIfNeeded()
        services.lastSessionBucket = -1
        saveSessionState()
        updateNowPlaying(force: true)
    }

    /// SID-Modell erzwingen: `nil` = Auto (Vorgabe der Datei), 6581 oder 8580.
    ///
    /// Bewusst NICHT gespeichert — genau wie auf dem Mac gilt die Wahl nur fuer
    /// die laufende Sitzung. Sie ist ein Analysewerkzeug, keine Einstellung.
    func setModelOverride(_ model: Int?) {
        coordinator.setModelOverride(model)
    }

    /// Startet die Wiedergabe.
    ///
    /// Der Umweg ueber `activate()` ist wichtig: nach einem Anruf hat das System
    /// unsere Audio-Sitzung deaktiviert. Der Coordinator aktiviert sie nur, wenn
    /// er die Engine komplett neu aufbaut — beim Fortsetzen aus der Pause tut er
    /// es nicht, und der Start der Engine wuerde dann still scheitern.
    private func startPlayback() {
        services.audioSession.activate()
        coordinator.play()
    }

    // MARK: - Hintergrund-Lauf (Auto-Next und Sperrbildschirm)

    /// Startet den 1-Hz-Lauf, der die Wiedergabe auch bei ausgeschaltetem
    /// Bildschirm begleitet.
    ///
    /// Warum ein eigener Lauf und nicht der Timer der Oberflaeche: Alles
    /// Zeichnende haengt an `isSceneActive` und steht im Hintergrund still —
    /// das ist der groesste Batteriehebel der App. Auto-Next und die Anzeige auf
    /// dem Sperrbildschirm muessen aber gerade DANN funktionieren. Einmal pro
    /// Sekunde reicht dafuer voellig: die Fortschrittsanzeige des
    /// Sperrbildschirms laeuft anhand der gemeldeten Abspielrate von allein
    /// weiter, und eine Sekunde Ungenauigkeit beim Songwechsel hoert niemand.
    ///
    /// Umgesetzt als `Task` mit `Task.sleep` statt als `Timer`: kein RunLoop-
    /// Modus, den man vergessen kann, und ein sauberer Abbruch.
    func startPlaybackLoop() {
        guard services.playbackLoop == nil else { return }
        services.playbackLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                self.playbackTick()
            }
        }
    }

    func stopPlaybackLoop() {
        services.playbackLoop?.cancel()
        services.playbackLoop = nil
    }

    /// Laeuft Wiedergabe, laeuft der Lauf; sonst nicht.
    func syncPlaybackLoop() {
        if coordinator.isPlaying {
            startPlaybackLoop()
        } else {
            stopPlaybackLoop()
        }
    }

    private func playbackTick() {
        guard coordinator.isPlaying else {
            stopPlaybackLoop()
            return
        }
        let elapsed = coordinator.elapsedSeconds
        // Der NowPlayingController drosselt selbst; hier ist ohnehin nur 1 Hz.
        updateNowPlaying()
        saveSessionStateThrottled(elapsed: elapsed)

        guard autoNext, elapsed >= currentDuration else { return }
        advanceAtEndOfTrack()
    }

    /// Songende erreicht. Reihenfolge wie auf dem Mac: erst die restlichen
    /// Subtunes DIESER Datei, dann der naechste Titel, sonst anhalten.
    private func advanceAtEndOfTrack() {
        if coordinator.currentSubtune + 1 < coordinator.subtunesCount {
            setSubtune(coordinator.currentSubtune + 1)
            return
        }
        if visibleTracks.count > 1,
           let nextID = neighbourTrackID(offset: 1, shuffled: shuffle) {
            loadTrack(id: nextID, autoplay: true)
            return
        }
        coordinator.stop()
        syncPlaybackLoop()
        updateNowPlaying(force: true)
    }

    // MARK: - Sperrbildschirm und Audio-Sitzung

    /// Verdrahtet Audio-Sitzung und Sperrbildschirm mit der Wiedergabe.
    /// Wird genau einmal aus `start()` gerufen.
    func configureSystemPlayback() {
        let session = services.audioSession

        session.isPlayingProvider = { [weak self] in
            self?.coordinator.isPlaying ?? false
        }
        session.pauseHandler = { [weak self] in
            guard let self, self.coordinator.isPlaying else { return }
            self.coordinator.pause()
            self.syncPlaybackLoop()
            self.saveSessionState()
            self.updateNowPlaying(force: true)
        }
        session.resumeHandler = { [weak self] in
            guard let self, self.currentTrackID != nil, !self.coordinator.isPlaying else { return }
            self.startPlayback()
            self.syncPlaybackLoop()
            self.updateNowPlaying(force: true)
        }
        session.mediaServicesResetHandler = { [weak self] in
            self?.rebuildAfterMediaServicesReset()
        }
        session.configure()

        let nowPlaying = services.nowPlaying
        nowPlaying.playHandler = { [weak self] in
            guard let self, !self.coordinator.isPlaying else { return }
            self.togglePlayPause()
        }
        nowPlaying.pauseHandler = { [weak self] in
            guard let self, self.coordinator.isPlaying else { return }
            self.togglePlayPause()
        }
        nowPlaying.toggleHandler = { [weak self] in self?.togglePlayPause() }
        nowPlaying.nextHandler = { [weak self] in self?.playNext() }
        nowPlaying.previousHandler = { [weak self] in self?.playPrevious() }
        nowPlaying.seekHandler = { [weak self] seconds in self?.seek(to: seconds) }
        nowPlaying.configureCommands()
    }

    /// Der Audio-Dienst des Systems ist neu gestartet: Engine und Emulator sind
    /// weg. Denselben Titel an derselben Stelle neu aufbauen, damit der Nutzer
    /// hoechstens eine Luecke hoert statt dauerhafter Stille.
    private func rebuildAfterMediaServicesReset() {
        guard let id = currentTrackID else { return }
        let subtune = coordinator.currentSubtune
        let position = coordinator.elapsedSeconds
        let wasPlaying = coordinator.isPlaying

        coordinator.stop()
        guard loadTrack(id: id, autoplay: false) else { return }
        if subtune > 0 { coordinator.setSubtune(sub: subtune) }
        coordinator.seek(seconds: position)
        if wasPlaying { startPlayback() }
        syncPlaybackLoop()
        updateNowPlaying(force: true)
    }

    /// Schiebt den aktuellen Stand an den Sperrbildschirm.
    /// - Parameter force: bei echten Zustandswechseln setzen (Titel, Play/Pause,
    ///   Sprung). Ohne `force` gilt die Drosselung im `NowPlayingController`.
    func updateNowPlaying(force: Bool = false) {
        // Auch ohne ausgewaehlten Titel kann noch Ton laufen (die Datei wurde
        // z.B. gerade von aussen geloescht) — dann bleibt die Anzeige stehen.
        guard currentTrackID != nil || coordinator.isPlaying || coordinator.isPaused else {
            services.nowPlaying.clear()
            return
        }
        let snapshot = NowPlayingController.Snapshot(
            title: coordinator.trackName,
            artist: coordinator.composer,
            album: nowPlayingSubtitle,
            duration: currentDuration,
            elapsed: coordinator.elapsedSeconds,
            isPlaying: coordinator.isPlaying,
            isPaused: coordinator.isPaused
        )
        services.nowPlaying.update(snapshot, force: force)
    }

    /// Zusatzzeile: Copyright-Feld der Datei, bei mehreren Subtunes zusaetzlich
    /// die Nummer des laufenden Subtunes.
    private var nowPlayingSubtitle: String {
        var parts: [String] = []
        let info = coordinator.info.trimmingCharacters(in: .whitespacesAndNewlines)
        if !info.isEmpty { parts.append(info) }
        if coordinator.subtunesCount > 1 {
            parts.append("Subtune \(coordinator.currentSubtune + 1)/\(coordinator.subtunesCount)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Songlaengen

    /// Text ohne importierte Datenbank.
    static var missingSonglengthsStatus: String { "Keine Songlängen-Datenbank importiert" }

    /// Ablageort der importierten HVSC-Datenbank.
    ///
    /// Bewusst im internen Support-Ordner und nicht in `Documents/`: dort saehe
    /// der Nutzer sie in der Finder-Dateifreigabe zwischen seiner Musik liegen.
    /// Und bewusst als KOPIE: die vom Dateiauswahl-Dialog gelieferte URL zeigt
    /// irgendwohin ausserhalb der App und ist beim naechsten Start wertlos.
    var songlengthsFileURL: URL? {
        services.library?.supportDirectory.appendingPathComponent("songlengths.md5")
    }

    /// Uebernimmt eine vom Nutzer gewaehlte `Songlengths.md5` in die App.
    func importSonglengths(from url: URL) {
        guard let destination = songlengthsFileURL else {
            errorMessage = "Der interne Ordner der App ist nicht erreichbar."
            return
        }
        services.songlengthLoadTask?.cancel()
        services.songlengthLoadTask = nil
        setSonglengthsStatus("Datenbank wird übernommen …")

        Task.detached(priority: .utility) { [self] in
            // Der Sicherheits-Scope gilt prozessweit, nicht pro Thread — er darf
            // deshalb hier geoeffnet und geschlossen werden.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                try data.write(to: destination, options: .atomic)
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.setSonglengthsStatus(AppModel.missingSonglengthsStatus)
                    self.errorMessage = "Songlängen-Datenbank konnte nicht übernommen werden: \(message)"
                }
                return
            }
            await MainActor.run { self.loadSonglengthDB() }
        }
    }

    /// Laedt die zuvor importierte Datenbank im Hintergrund und zieht die
    /// Laengen des laufenden Titels nach.
    func loadSonglengthDB() {
        services.songlengthLoadTask?.cancel()
        services.songlengthLoadTask = nil

        guard let fileURL = songlengthsFileURL,
              fileManager.fileExists(atPath: fileURL.path) else {
            songlengthDB = nil
            setSonglengthsStatus(AppModel.missingSonglengthsStatus)
            return
        }

        services.songlengthLoadTask = Task { [self] in
            // Die HVSC-Datei hat mehrere Megabyte und zehntausende Zeilen —
            // Parsen gehoert nicht auf den Hauptthread.
            let database = await Task.detached(priority: .utility) { () -> SonglengthDB? in
                try? SonglengthDB.loadCancellable(url: fileURL)
            }.value

            guard !Task.isCancelled else { return }
            services.songlengthLoadTask = nil
            songlengthDB = database

            guard let database else {
                setSonglengthsStatus("Datenbank konnte nicht gelesen werden")
                return
            }
            setSonglengthsStatus("\(database.count) Einträge")
            if let md5 = currentMD5 {
                currentTrackLengths = database.lengths(forMD5: md5)
                resolveComputedLengthIfNeeded()
                updateNowPlaying(force: true)
            }
        }
    }

    /// Loest die Laenge des laufenden Subtunes auf, wenn die HVSC-Datenbank
    /// nichts liefert.
    ///
    /// Die Reihenfolge ist ein Architekturvertrag und darf sich nicht aendern:
    ///
    ///   1. HVSC-`Songlengths.md5` — von Menschen kuratiert, immer der Vorrang.
    ///   2. Berechneter Cache — Ergebnis einer frueheren Analyse dieser Datei.
    ///   3. Hintergrund-Berechnung — der Emulator laeuft schneller als Echtzeit
    ///      und sucht das Ende. Als Ende gilt erst, wenn mindestens drei
    ///      Sekunden Stille am Stueck folgen (steckt im `SongLengthEstimator`).
    ///   4. Sonst bleibt es beim 360-Sekunden-Fallback aus `AppModel`.
    ///
    /// Auch ein „kein Ende gefunden" wird gecacht (als -1). Sonst wuerde jeder
    /// endlos loopende Tune — und das ist die HVSC-Mehrheit — bei jedem Abspielen
    /// erneut sechs Minuten lang durchgerechnet.
    func resolveComputedLengthIfNeeded() {
        computedLength = nil

        // Die Datenbank kennt die Laenge? Dann gibt es nichts zu rechnen.
        if let lengths = currentTrackLengths, coordinator.currentSubtune < lengths.count {
            cancelLengthEstimate()
            return
        }
        guard let md5 = currentMD5,
              let id = currentTrackID,
              let fileURL = trackURL(for: id) else { return }

        let subtune = coordinator.currentSubtune
        let estimateKey = "\(md5.lowercased()):\(subtune)"

        // Genau diese Berechnung laeuft schon (z.B. zwei kurz aufeinander
        // folgende Ereignisse aus der Oberflaeche): nicht doppelt starten.
        if services.lengthEstimateKey == estimateKey, lengthEstimateTask != nil { return }
        cancelLengthEstimate()

        if let cached = lengthCache.length(md5: md5, subtune: subtune) {
            // -1 = frueher berechnet, kein Ende gefunden -> Fallback behalten.
            if cached > 0 { computedLength = cached }
            return
        }

        let cache = lengthCache
        // Der Generationszaehler schuetzt vor veralteten Ergebnissen: wechselt
        // der Nutzer waehrend der Berechnung den Titel, darf das spaet
        // eintreffende Ergebnis den neuen Titel nicht ueberschreiben.
        lengthEstimateGeneration &+= 1
        let generation = lengthEstimateGeneration
        services.lengthEstimateKey = estimateKey

        lengthEstimateTask = Task.detached(priority: .utility) { [self] in
            do {
                try Task.checkCancellation()
                let data = try Data(contentsOf: fileURL)
                let sidFile = try SidParser.parse(data: data)
                let result = try SongLengthEstimator.estimate(sidFile: sidFile, subtune: subtune)
                try Task.checkCancellation()
                cache.store(md5: md5, subtune: subtune, seconds: result ?? -1)

                await MainActor.run {
                    guard self.lengthEstimateGeneration == generation,
                          self.services.lengthEstimateKey == estimateKey else { return }
                    self.lengthEstimateTask = nil
                    self.services.lengthEstimateKey = nil
                    if self.currentMD5 == md5,
                       self.coordinator.currentSubtune == subtune,
                       let result {
                        self.computedLength = result
                        self.updateNowPlaying(force: true)
                    }
                }
            } catch is CancellationError {
                // Titel gewechselt: fuer eine absichtlich abgebrochene Analyse
                // darf KEIN negatives Ergebnis in den Cache.
            } catch {
                await MainActor.run {
                    if self.lengthEstimateGeneration == generation {
                        self.lengthEstimateTask = nil
                        self.services.lengthEstimateKey = nil
                    }
                }
            }
        }
    }

    func cancelLengthEstimate() {
        lengthEstimateTask?.cancel()
        lengthEstimateTask = nil
        services.lengthEstimateKey = nil
        lengthEstimateGeneration &+= 1
    }

    // MARK: - Sitzung

    /// Sichert Titel, Subtune und Position fuer den naechsten App-Start.
    ///
    /// Die gespeicherte ID ist der RELATIVE Pfad. Absolute Pfade waeren wertlos:
    /// der App-Container bekommt bei jeder Neuinstallation eine neue UUID.
    func saveSessionState() {
        guard sessionRestoreEnabled, let id = currentTrackID else { return }
        defaults.set(id, forKey: Keys.lastTrackID)
        defaults.set(coordinator.currentSubtune, forKey: Keys.lastSubtune)
        defaults.set(coordinator.elapsedSeconds, forKey: Keys.lastPosition)
        services.lastSessionBucket = Int(coordinator.elapsedSeconds / 5.0)
    }

    /// Wie oben, aber hoechstens alle fuenf Sekunden. Der Hintergrund-Lauf ruft
    /// diese Variante — im Sekundentakt in die Benutzereinstellungen zu
    /// schreiben waere Verschwendung.
    private func saveSessionStateThrottled(elapsed: Double) {
        let bucket = Int(elapsed / 5.0)
        guard bucket != services.lastSessionBucket else { return }
        saveSessionState()
    }

    func clearSessionState() {
        defaults.removeObject(forKey: Keys.lastTrackID)
        defaults.removeObject(forKey: Keys.lastSubtune)
        defaults.removeObject(forKey: Keys.lastPosition)
        services.lastSessionBucket = -1
    }

    /// Stellt die letzte Sitzung wieder her. Wird genau einmal gerufen, nachdem
    /// die Bibliothek zum ersten Mal geladen ist.
    ///
    /// Zwei bewusste Entscheidungen:
    ///
    ///  - BEI ZUFALLSWIEDERGABE WIRD NICHT WIEDERHERGESTELLT. Wer Shuffle
    ///    eingeschaltet laesst, will bei jedem Start etwas anderes hoeren; das
    ///    steht so in den Projektregeln. Stattdessen wird ein zufaelliger Titel
    ///    vorbereitet.
    ///  - ES WIRD NICHTS VON ALLEIN ABGESPIELT. Anders als auf dem Mac: ein
    ///    iPhone startet die App oft in der Hosentasche oder im Zug, und Musik
    ///    ohne Zutun waere dort ein Schreck. Der Titel steht bereit, den Start
    ///    macht der Nutzer.
    func restoreSessionIfPossible() {
        guard currentTrackID == nil, !tracks.isEmpty else { return }

        if shuffle {
            if let random = tracks.randomElement() {
                loadTrack(id: random.id, autoplay: false)
            }
            return
        }

        guard sessionRestoreEnabled,
              let id = defaults.string(forKey: Keys.lastTrackID),
              tracks.contains(where: { $0.id == id }) else { return }

        let subtune = defaults.integer(forKey: Keys.lastSubtune)
        let position = defaults.double(forKey: Keys.lastPosition)
        guard loadTrack(id: id, autoplay: false) else { return }

        // Direkt am Coordinator und nicht ueber `setSubtune`/`seek`: die beiden
        // wuerden den gerade gelesenen Sitzungsstand sofort wieder ueberschreiben.
        if subtune > 0 { coordinator.setSubtune(sub: subtune) }
        if position > 1.0 { coordinator.seek(seconds: position) }
        resolveComputedLengthIfNeeded()
        updateNowPlaying(force: true)
    }

    // MARK: - WAV-Export

    /// Rendert den laufenden Titel als WAV-Datei und liefert sie zurueck, damit
    /// die Oberflaeche sie ins Teilen-Menue geben kann.
    ///
    /// Kanaele bestimmt der Renderer aus der Datei: 2SID/3SID werden stereo
    /// ausgegeben (die Chips sind links und rechts verteilt), einfache Dateien
    /// mono. Die Dauer ist die aufgeloeste Songlaenge — dieselbe, die auch der
    /// Fortschrittsbalken zeigt.
    func exportCurrentTrackAsWAV() async -> URL? {
        guard let id = currentTrackID, let sourceURL = trackURL(for: id) else {
            errorMessage = "Kein Titel für den WAV-Export ausgewählt."
            return nil
        }
        guard let destination = prepareWAVDestination(for: sourceURL) else {
            errorMessage = "Temporärer Ordner für den Export ist nicht erreichbar."
            return nil
        }

        let subtune = coordinator.currentSubtune
        let model = coordinator.modelOverride
        // Der Renderer hat eine eigene Obergrenze; alles darueber lehnt er ab.
        let seconds = min(currentDuration, WavRenderer.maximumDurationSeconds)

        // Rendern laeuft schneller als Echtzeit, dauert bei sechs Minuten Musik
        // aber trotzdem einige Sekunden — also abseits des Hauptthreads.
        let outcome = await Task.detached(priority: .userInitiated) { () -> WAVExportOutcome in
            do {
                let data = try Data(contentsOf: sourceURL)
                let sidFile = try SidParser.parse(data: data)
                try WavRenderer.render(sidFile: sidFile,
                                       subtune: subtune,
                                       seconds: seconds,
                                       modelOverride: model,
                                       to: destination)
                return .finished(destination)
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value

        switch outcome {
        case .finished(let url):
            return url
        case .failed(let message):
            errorMessage = "WAV-Export fehlgeschlagen: \(message)"
            return nil
        }
    }

    /// Legt den Zielpfad im temporaeren Ordner an.
    ///
    /// Der Export-Unterordner wird vor jedem Lauf geleert, damit sich dort nicht
    /// mit der Zeit ein Haufen alter WAV-Dateien ansammelt — die sind um ein
    /// Vielfaches groesser als die SID-Dateien selbst.
    private func prepareWAVDestination(for sourceURL: URL) -> URL? {
        let folder = fileManager.temporaryDirectory.appendingPathComponent("WAV-Export", isDirectory: true)
        try? fileManager.removeItem(at: folder)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        var name = sourceURL.deletingPathExtension().lastPathComponent
        if coordinator.subtunesCount > 1 {
            name += " (Subtune \(coordinator.currentSubtune + 1))"
        }
        return folder.appendingPathComponent(name).appendingPathExtension("wav")
    }
}

/// Ergebnis des WAV-Exports. Steht ausserhalb der `@MainActor`-Erweiterung,
/// weil der Wert aus einem Hintergrund-Task zurueckkommt.
enum WAVExportOutcome: Sendable {
    case finished(URL)
    case failed(String)
}
