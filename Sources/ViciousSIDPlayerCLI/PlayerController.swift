import Foundation
import ViciousSIDPlayerCore

// ============================================================================
// PlayerController — Wiedergabe und Zustand an einer Stelle.
//
// WARUM ES DAS GIBT
// -----------------
// Es gibt mehr als ein Bedienfeld fuer denselben Player: die Tastatur am
// Terminal ist eines, MPRIS2 ueber D-Bus (Medientasten, Sound-Applet des
// Desktops) ein zweites — und ein HTTP-Remote waere ein drittes. Ohne eine
// gemeinsame Mitte muesste jedes davon dieselbe Logik nachbauen: „pausieren
// heisst sink.pause() UND Zustand merken", „Subtune wechseln heisst
// initSubtune() UND Nummer fortschreiben". Solche Doppelungen laufen
// unweigerlich auseinander, sobald sich eine Kleinigkeit aendert.
//
// Diese Klasse ist deshalb die einzige Stelle, die den Sink und den Processor
// anfasst. Die Bedienfelder rufen nur noch play(), pause(), next() und so
// weiter — und erfahren ueber `onStateChanged`, wenn sich etwas geaendert hat.
//
// Threads
// -------
// Der Controller wird von mehreren Threads benutzt: die Tastaturschleife laeuft
// im Haupt-Thread, der D-Bus-Dienst auf einem eigenen. Deshalb liegt der
// veraenderliche Zustand vollstaendig hinter `lock` — das ist zugleich die
// Deckung fuer das `@unchecked Sendable`.
// ============================================================================

/// Zaehlt die schon gerenderten Frames und deckelt sie auf die per `--seconds`
/// gewuenschte Dauer.
///
/// `@unchecked Sendable` ist hier ehrlich: Nach dem Start fasst ausschliesslich
/// der Audio-Thread dieses Objekt an. Es gibt keinen zweiten Zugriff, also auch
/// kein Datenrennen — und ein Lock im Renderpfad waere sogar schaedlich (siehe
/// den Echtzeit-Hinweis am `PCMRenderBlock`).
final class FrameBudget: @unchecked Sendable {
    private let limit: Int?
    private var rendered = 0

    /// - Parameter limit: Maximale Frame-Anzahl; `nil` = unbegrenzt.
    init(limit: Int?) {
        self.limit = limit
    }

    /// Gibt zurueck, wie viele der `requested` Frames noch erlaubt sind.
    /// Ein Wert kleiner als angefordert bedeutet fuer den Sink „Quelle erschoepft".
    func take(_ requested: Int) -> Int {
        guard let limit else { return requested }
        let remaining = max(0, limit - rendered)
        let granted = min(requested, remaining)
        rendered += granted
        return granted
    }
}

final class PlayerController: @unchecked Sendable {

    /// Die Zustaende, die ein Bedienfeld sehen kann.
    ///
    /// Die Rohwerte sind absichtlich genau die Woerter, die MPRIS2 fuer
    /// `PlaybackStatus` vorschreibt — so muss der D-Bus-Dienst nichts uebersetzen.
    enum PlaybackState: String {
        case playing = "Playing"
        case paused = "Paused"
        case stopped = "Stopped"
    }

    // Unveraenderlich, deshalb ohne Lock lesbar.
    let metadata: SidMetadata
    let subtunesCount: Int

    private let sink: PCMSink
    private let processor: ViciousProcessor
    private let budget: FrameBudget

    private let lock = NSLock()
    /// Serialisiert ganze BEDIENOPERATIONEN (Start, Play, Pause, Stop,
    /// Subtune-Wechsel).
    ///
    /// `lock` schuetzt nur einzelne Feldzugriffe und wird vor jedem Sink- bzw.
    /// Processor-Aufruf freigegeben. Zwei Bedienbefehle von Tastatur- und
    /// MPRIS-Thread konnten sich dadurch ueberholen: Ein dazwischen laufendes
    /// `stop` wurde danach von `play`/`pause` wieder auf .playing/.paused
    /// ueberschrieben, und zwei parallele Subtune-Wechsel riefen den Processor
    /// in anderer Reihenfolge auf, als das gespeicherte `subtune` sagt
    /// (Review-Fund 2026-08-17). Benachrichtigt wird erst NACH der
    /// vollstaendigen Operation und ausserhalb dieser Sperre — ein Beobachter
    /// darf zurueckrufen, ohne sich selbst auszusperren.
    private let operationLock = NSLock()
    private var currentState: PlaybackState = .stopped
    private var subtune: Int
    private var observer: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - sid: die geparste Datei (fuer Metadaten und Subtune-Anzahl).
    ///   - sink: die schon gebaute, aber noch nicht gestartete Ausgabe.
    ///   - format: das Format, mit dem der Processor gebaut wurde.
    ///   - startSubtune: 0-basiert, vom Aufrufer bereits geprueft.
    ///   - seconds: Spieldauer, `nil` = endlos.
    init(sid: SidFileData, sink: PCMSink, format: PCMFormat, startSubtune: Int, seconds: Double?) throws {
        // Der Renderblock in `start()` schreibt fest ZWEI Werte je Frame, weil er
        // die Samples mit `playStereo()` holt. Der Zielpuffer ist aber nach
        // `format.channels` bemessen. Bei einem Mono-Format waere er nur halb so
        // gross wie das, was der Block hineinschreibt — ein Schreibzugriff hinter
        // das Pufferende, den im Release-Build nichts abfaengt. Heute gibt es
        // keinen Weg, hier etwas anderes als Stereo hereinzureichen; damit das
        // beim naechsten Ausgabeformat nicht still zur Speicherverletzung wird,
        // steht die Erwartung hier ausdruecklich.
        guard format.channels == 2 else {
            throw PCMSinkError.unsupportedFormat(format)
        }
        self.metadata = sid.metadata
        self.subtunesCount = max(1, sid.metadata.subtunesCount)
        self.sink = sink
        self.subtune = startSubtune

        let processor = ViciousProcessor(sampleRate: format.sampleRate)
        _ = processor.loadSID(sidFile: sid)
        processor.initSubtune(sub: startSubtune)
        // Volle Lautstaerke: die Skalierung ist Sache der Quelle, nicht des Sinks
        // (siehe Vertragskommentar in PCMSink.swift). Ein CLI hat keinen Mixer davor.
        processor.setVolume(vol: 1.0)
        self.processor = processor

        self.budget = FrameBudget(
            limit: try seconds.map { try WavRenderer.frameCount(seconds: $0, sampleRate: format.sampleRate) }
        )
    }

    // MARK: - Beobachtung

    /// Hinterlegt einen Beobachter, der nach jeder Zustandsaenderung gerufen wird.
    /// MPRIS2 haengt hier sein `PropertiesChanged`-Signal ein.
    ///
    /// Der Beobachter wird NIE gerufen, waehrend das Lock gehalten wird — sonst
    /// koennte er beim Zurueckfragen („in welchem Zustand sind wir?") auf sich
    /// selbst warten und alles blockieren.
    func setStateObserver(_ block: (@Sendable () -> Void)?) {
        lock.lock()
        observer = block
        lock.unlock()
    }

    private func notifyObserver() {
        lock.lock()
        let block = observer
        lock.unlock()
        block?()
    }

    // MARK: - Zustand lesen

    var state: PlaybackState {
        lock.lock()
        defer { lock.unlock() }
        return currentState
    }

    /// Aktueller Subtune, 0-basiert.
    var currentSubtune: Int {
        lock.lock()
        defer { lock.unlock() }
        return subtune
    }

    // MARK: - Bedienung

    /// Startet die Wiedergabe. Darf nur einmal gerufen werden (ein Sink ist Einweg).
    func start() throws {
        // Der Renderblock laeuft auf dem Audio-Thread: nichts allozieren, nichts
        // loggen, nicht blockieren. Er faengt bewusst nur `processor` und `budget`
        // ein — nicht `self`, damit er nicht am Lock des Controllers haengt.
        let processor = self.processor
        let budget = self.budget
        let render: PCMRenderBlock = { buffer, frames in
            let granted = budget.take(frames)
            for frame in 0..<granted {
                // Immer stereo ziehen: bei 1 SID sind beide Kanaele identisch, bei
                // 2SID/3SID pannt der Processor die Chips selbst (playStereo).
                let sample = processor.playStereo()
                buffer[frame * 2] = Float(sample.left)
                buffer[frame * 2 + 1] = Float(sample.right)
            }
            return granted
        }

        operationLock.lock()
        do {
            try sink.start(render: render)
        } catch {
            operationLock.unlock()
            throw error
        }
        lock.lock()
        currentState = .playing
        lock.unlock()
        operationLock.unlock()
        notifyObserver()
    }

    /// Setzt fort. Auf einem nicht pausierten Player wirkungslos.
    func play() {
        operationLock.lock()
        let changed = playLocked()
        operationLock.unlock()
        if changed { notifyObserver() }
    }

    /// Rumpf von play(); der Aufrufer haelt die Operationssperre.
    /// Rueckgabe: Hat sich der Zustand wirklich geaendert?
    @discardableResult
    private func playLocked() -> Bool {
        lock.lock()
        guard currentState == .paused else { lock.unlock(); return false }
        lock.unlock()

        // Ausserhalb des Feld-Locks: sink.resume() kann werfen und ruft fremden
        // Code. Die Operationssperre haelt derweil jeden anderen Befehl auf.
        do {
            try sink.resume()
            lock.lock()
            currentState = .playing
            lock.unlock()
            return true
        } catch {
            // Laesst sich die Ausgabe nicht fortsetzen, bleibt der Zustand
            // ehrlich auf „pausiert" stehen, statt etwas zu behaupten.
            return false
        }
    }

    /// Haelt an, ohne den Emulationsstand zu verlieren.
    func pause() {
        operationLock.lock()
        let changed = pauseLocked()
        operationLock.unlock()
        if changed { notifyObserver() }
    }

    /// Rumpf von pause(); der Aufrufer haelt die Operationssperre.
    @discardableResult
    private func pauseLocked() -> Bool {
        lock.lock()
        guard currentState == .playing else { lock.unlock(); return false }
        lock.unlock()

        do {
            try sink.pause()
            lock.lock()
            currentState = .paused
            lock.unlock()
            return true
        } catch {
            // Siehe play(): im Zweifel lieber nichts behaupten.
            return false
        }
    }

    /// Schaltet zwischen Pause und Wiedergabe um.
    ///
    /// Lesen des Zustands und Umschalten gehoeren in DIESELBE Operation — sonst
    /// entscheidet der Umschalter auf einem Stand, den ein anderer Thread
    /// inzwischen geaendert hat.
    func playPause() {
        operationLock.lock()
        lock.lock()
        let current = currentState
        lock.unlock()
        var changed = false
        switch current {
        case .playing: changed = pauseLocked()
        case .paused: changed = playLocked()
        case .stopped: break
        }
        operationLock.unlock()
        if changed { notifyObserver() }
    }

    /// Naechster Subtune (rotiert am Ende zurueck auf den ersten).
    func next() {
        switchSubtune { ($0 + 1) % $1 }
    }

    /// Vorheriger Subtune (rotiert am Anfang auf den letzten).
    func previous() {
        switchSubtune { ($0 - 1 + $1) % $1 }
    }

    /// Gemeinsame Mitte von next()/previous().
    ///
    /// Der Zugriff auf den laufenden Processor ist sicher, weil `initSubtune`
    /// dieselbe Sperre nimmt wie `playStereo()` im Audio-Thread — die beiden
    /// koennen sich also nicht in die Quere kommen.
    private func switchSubtune(_ pick: (Int, Int) -> Int) {
        guard subtunesCount > 1 else { return }

        // Die GANZE Operation unter der Operationssperre: Auswahl, Speichern und
        // der Processor-Aufruf gehoeren zusammen. Sonst konnten zwei parallele
        // Wechsel ihre `initSubtune`-Aufrufe in anderer Reihenfolge ausfuehren
        // als das gespeicherte `subtune` (Review-Fund 2026-08-17).
        operationLock.lock()
        lock.lock()
        guard currentState != .stopped else {
            lock.unlock()
            operationLock.unlock()
            return
        }
        subtune = pick(subtune, subtunesCount)
        let target = subtune
        lock.unlock()

        processor.initSubtune(sub: target)
        operationLock.unlock()
        notifyObserver()
    }

    /// Beendet endgueltig. Mehrfacher Aufruf ist harmlos.
    func stop() {
        operationLock.lock()
        sink.stop()
        lock.lock()
        currentState = .stopped
        lock.unlock()
        operationLock.unlock()
        notifyObserver()
    }

    /// Blockiert, bis die Wiedergabe endet, und liefert den Grund.
    ///
    /// Auch der natuerliche Abschluss ist eine ganze BEDIENOPERATION und braucht
    /// deshalb dieselbe Sperre wie play/pause/stop. Ohne sie konnte ein
    /// gleichzeitiger Befehl von der Tastatur oder ueber MPRIS den gerade
    /// gesetzten Zustand wieder ueberschreiben: Endete der Sink zwischen der
    /// Zustandspruefung in `pauseLocked()` und dessen `currentState = .paused`,
    /// meldete der Player nach tatsaechlich beendeter Ausgabe weiter „Paused"
    /// statt „Stopped" (Review-Fund 2026-08-20).
    ///
    /// Gewartet wird VOR der Sperre — sonst bliebe jeder andere Befehl so lange
    /// haengen, wie die Wiedergabe noch dauert.
    func waitUntilFinished() -> PCMSinkFinishReason {
        let reason = sink.waitUntilFinished()
        operationLock.lock()
        lock.lock()
        currentState = .stopped
        lock.unlock()
        operationLock.unlock()
        notifyObserver()
        return reason
    }
}
