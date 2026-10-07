import Foundation

// AVFoundation und Combine sind Apple-Frameworks und existieren unter Linux nicht.
// Alles, was direkt darauf aufbaut (der ViciousCoordinator mit AVAudioEngine und
// ObservableObject), wird deshalb weiter unten plattform-geguardet. Der Guard prueft
// AVFoundation stellvertretend fuer beide Frameworks: Wo es AVFoundation gibt (macOS,
// iOS), gibt es auch Combine.
#if canImport(AVFoundation)
import AVFoundation
import Combine
#endif

// Bewusst AUSSERHALB des Guards: Der Puffer braucht nur Foundation (NSLock) und ist
// damit plattformneutral. So kann ihn spaeterer Linux-Code (z. B. ein CLI-Player) mit
// einem eigenen Audio-Backend weiterverwenden.
public final class RealtimeVisualsBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var _envelopes: (Float, Float, Float) = (0.0, 0.0, 0.0)
    private var _frequencies: (Int, Int, Int) = (0, 0, 0)
    private var _gates: (Int, Int, Int) = (0, 0, 0)
    private var _waveforms: (Int, Int, Int) = (0, 0, 0)
    private var _pulsewidths: (Float, Float, Float) = (0.5, 0.5, 0.5)
    private var _playtime: Double = 0.0
    
    public var visualizerTicker: Int = 0
    public init() {}
    
    public func write(envelopes: (Float, Float, Float),
                      frequencies: (Int, Int, Int),
                      gates: (Int, Int, Int),
                      waveforms: (Int, Int, Int),
                      pulsewidths: (Float, Float, Float),
                      playtime: Double) {
        lock.lock()
        _envelopes = envelopes
        _frequencies = frequencies
        _gates = gates
        _waveforms = waveforms
        _pulsewidths = pulsewidths
        _playtime = playtime
        lock.unlock()
    }
    
    public func updatePlaytime(_ playtime: Double) {
        lock.lock()
        _playtime = playtime
        lock.unlock()
    }
    
    public func read() -> (envelopes: (Float, Float, Float),
                           frequencies: (Int, Int, Int),
                           gates: (Int, Int, Int),
                           waveforms: (Int, Int, Int),
                           pulsewidths: (Float, Float, Float),
                           playtime: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (_envelopes, _frequencies, _gates, _waveforms, _pulsewidths, _playtime)
    }
}

/// Der Anzeigestand der drei SID-Stimmen fuer die Oszilloskope.
///
/// Ein Wert und kein Strom von Benachrichtigungen: Wer ihn braucht, holt ihn
/// sich beim Zeichnen ab (`ViciousCoordinator.currentVisuals()`).
public struct VoiceVisuals: Sendable, Equatable {
    /// Huellkurve je Stimme, 0…1.
    public let envelopes: [Float]
    /// Roher SID-Frequenzwert je Stimme.
    public let frequencies: [Int]
    /// Gate-Bit je Stimme (0 oder 1).
    public let gates: [Int]
    /// Wellenform-Bits je Stimme.
    public let waveforms: [Int]
    /// Pulsbreite je Stimme, 0…1.
    public let pulsewidths: [Float]

    public init(envelopes: [Float], frequencies: [Int], gates: [Int],
                waveforms: [Int], pulsewidths: [Float]) {
        self.envelopes = envelopes
        self.frequencies = frequencies
        self.gates = gates
        self.waveforms = waveforms
        self.pulsewidths = pulsewidths
    }

    /// Alles still — der Stand im Stop-Zustand.
    public static let silent = VoiceVisuals(envelopes: [0, 0, 0],
                                            frequencies: [0, 0, 0],
                                            gates: [0, 0, 0],
                                            waveforms: [0, 0, 0],
                                            pulsewidths: [0.5, 0.5, 0.5])
}

// Der Coordinator selbst ist Apple-only: Er haengt an AVAudioEngine (Audioausgabe) und
// an Combine/ObservableObject (@Published fuer die SwiftUI-Bindung). Beides gibt es unter
// Linux nicht, deshalb faellt die ganze Klasse dort aus der Uebersetzung heraus.
#if canImport(AVFoundation)
private final class ProcessorSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var processor: ViciousProcessor
    init(_ processor: ViciousProcessor) { self.processor = processor }
    func current() -> ViciousProcessor {
        lock.lock()
        defer { lock.unlock() }
        return processor
    }
    func replace(with processor: ViciousProcessor) {
        lock.lock()
        self.processor = processor
        lock.unlock()
    }
}

@MainActor
public final class ViciousCoordinator: ObservableObject {
    @Published public var isPlaying = false
    // Pausiert (im Gegensatz zu gestoppt): Wiedergabe haelt an, Emulations-Stand
    // bleibt erhalten. Das Oszilloskop friert dann das letzte Bild ein, statt auf
    // die Null-Linie zu springen.
    @Published public var isPaused = false
    @Published public var trackName = "Kein Song geladen"
    @Published public var composer = "Unbekannter Komponist"
    @Published public var info = "Vicious SID Player"
    @Published public var currentSubtune = 0
    @Published public var subtunesCount = 1
    @Published public var elapsedSeconds: Double = 0.0
    @Published public var prefModel: Int = 8580
    // Nutzer-Override des SID-Modells: nil = Auto (Datei-Praeferenz), 6581 oder 8580.
    @Published public var modelOverride: Int? = nil
    // Analyse-Features (nicht persistent — gelten pro Sitzung): Stimmen 1-3 einzeln
    // stumm und SID-Filter an/aus. Wirken live und ueberleben den Processor-
    // Neuaufbau in play() (werden dort erneut angewandt).
    @Published public var voiceMuted: [Bool] = [false, false, false]
    @Published public var filterEnabled = true

    // Die Anzeigewerte der drei Stimmen (Huellkurve, Frequenz, Gate, Wellenform,
    // Pulsbreite) sind BEWUSST nicht `@Published`.
    //
    // Sie aendern sich 50-mal je Sekunde — einmal je C64-Bild. Als
    // `@Published` warf jede dieser Aenderungen den kompletten Rumpf der
    // Oberflaeche neu auf, und das kostete rund die Haelfte der gesamten
    // Prozessorlast der App (gemessen am 2026-08-23: 48 % gegen 25 % bei
    // gedrosseltem Takt). Gelesen werden sie ohnehin nur von den beiden
    // Oszilloskopen, und die zeichnen in ihrem eigenen Takt — sie holen sich
    // den Stand jetzt direkt ueber `currentVisuals()`.

    // Veraenderbar, nicht `let`: Nach einem Neustart des System-Audiodienstes
    // (`AVAudioSession.mediaServicesWereReset` auf iOS) sind die Engine und
    // alles, was an ihr haengt, laut Apple ungueltig. Wer sie dann
    // weiterbenutzt, bekommt dauerhafte Stille — obwohl Titel, Position und
    // Status in der Oberflaeche richtig aussehen. Siehe `rebuildAudioEngine`.
    private var audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // codereview-ok: activeSid ist die Quelle, aus der play() den Processor neu erzeugt (2026-07-01)
    private var activeSid: SidFileData?
    private var engineProcessor: ViciousProcessor?
    private var processorSlot: ProcessorSlot?
    private var seekTask: Task<Void, Never>?
    private var seekGeneration = 0
    var isPreparingSeek: Bool { seekTask != nil }
    private let visualsBuffer = RealtimeVisualsBuffer()
    private var uiUpdateTimer: Timer?
    // Taktrate, mit der Oszilloskop-Daten und Laufzeit aus dem Realtime-Puffer
    // in die @Published-Felder gespiegelt werden. Siehe setUIUpdateInterval().
    private var uiUpdateInterval: TimeInterval = 0.02
    private var currentVolume: Float = 0.3
    // Zielposition eines Seeks, der im gestoppten Zustand angefordert wurde (dann
    // gibt es noch keinen Processor). play() wendet sie beim Aufbau an, damit die
    // Wiedergabe an der per Slider gewaehlten Stelle beginnt.
    private var pendingSeekSeconds: Double?

    public init() {}

    public func setSid(_ fileData: SidFileData) {
        stop()
        self.activeSid = fileData
        self.trackName = fileData.metadata.title
        self.composer = fileData.metadata.author
        self.info = fileData.metadata.info
        self.subtunesCount = fileData.metadata.subtunesCount
        self.currentSubtune = 0
        self.elapsedSeconds = 0.0
        self.prefModel = fileData.prefModel
    }

    public func play() {
        guard let sid = activeSid else { return }
        if isPlaying { return }
        if seekTask != nil {
            isPlaying = true
            isPaused = false
            startUIUpdates()
            return
        }

        // Fortsetzen nach Pause: Processor und Source-Node leben noch mitsamt
        // ihrem Emulations-Stand (CPU-Register, Speicher, Position). Es reicht,
        // die Audio-Engine wieder anzuwerfen — NICHT neu aufbauen, sonst begaenne
        // der Song von vorn.
        if engineProcessor != nil, sourceNode != nil {
            do {
                if !audioEngine.isRunning { try audioEngine.start() }
                isPlaying = true
                isPaused = false
                startUIUpdates()
            } catch {
                print("Fehler beim Fortsetzen der AVAudioEngine: \(error)")
            }
            return
        }

        let mixer = audioEngine.mainMixerNode
        mixer.outputVolume = currentVolume * currentVolume
        var sampleRate = mixer.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0.0 || sampleRate.isNaN || sampleRate.isInfinite {
            sampleRate = 44100.0
        }

        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            print("Fehler: Konnte standard stereo format nicht erstellen.")
            return
        }

        // Initialize processor
        let processor = ViciousProcessor(sampleRate: sampleRate)
        _ = processor.loadSID(sidFile: sid)
        processor.setModelOverride(modelOverride.map { Double($0) })
        for voice in 0..<3 { processor.setVoiceMuted(voice: voice, muted: voiceMuted[voice]) }
        processor.setFilterEnabled(filterEnabled)
        processor.initSubtune(sub: currentSubtune)
        let requestedSeek = pendingSeekSeconds
        pendingSeekSeconds = nil
        // Die Master-Lautstaerke regelt ausschliesslich der Mixer (siehe unten,
        // quadratische psychoakustische Kurve). Der Processor rendert deshalb mit
        // seiner vollen Standard-Lautstaerke (1.0) — wuerde er hier zusaetzlich mit
        // currentVolume skaliert, laege der Regler effektiv bei currentVolume^3.
        self.engineProcessor = processor
        let slot = ProcessorSlot(processor)
        self.processorSlot = slot

        let buffer = visualsBuffer

        // Safe process block called on Real-Time CoreAudio Thread
        let renderBlock: @Sendable (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus = { [slot] (isSilence, timestamp, frameCount, outputData) -> OSStatus in
            let processor = slot.current()
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2,
                  let leftPtr = buffers[0].mData,
                  let rightPtr = buffers[1].mData else {
                return noErr
            }

            let left = leftPtr.assumingMemoryBound(to: Float.self)
            let right = rightPtr.assumingMemoryBound(to: Float.self)

            for frame in 0..<Int(frameCount) {
                // Stereo: bei 1 SID identisch auf beiden Kanaelen, bei 2SID/3SID
                // pannt der Processor die Chips links/rechts (playStereo).
                let sample = processor.playStereo()
                left[frame] = Float(sample.left)
                right[frame] = Float(sample.right)
            }

            // Sync visualizer data approx. 43 times per second
            buffer.visualizerTicker += Int(frameCount)
            if buffer.visualizerTicker >= 1024 {
                buffer.visualizerTicker = 0
                let liveData = processor.getChannelsData()
                buffer.write(envelopes: liveData.envelopes,
                             frequencies: liveData.frequencies,
                             gates: liveData.gates,
                             waveforms: liveData.waveforms,
                             pulsewidths: liveData.pulsewidths,
                             playtime: liveData.playtime)
            }

            return noErr
        }

        let sourceNode = AVAudioSourceNode(renderBlock: renderBlock)
        self.sourceNode = sourceNode

        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: mixer, format: stereoFormat)

        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("Fehler bei iOS AVAudioSession Aktivierung: \(error)")
        }
        #endif

        // codereview-ok: isPlaying wird erst nach erfolgreichem start() gesetzt; catch raeumt sauber auf (2026-07-01)
        do {
            if requestedSeek == nil && !audioEngine.isRunning {
                try audioEngine.start()
            }
            isPlaying = true
            isPaused = false
            startUIUpdates()
            if let requestedSeek { seek(seconds: requestedSeek) }
        } catch {
            print("Fehler beim Starten der AVAudioEngine: \(error)")
            // Engine-Start fehlgeschlagen: den bereits attachten/verbundenen
            // SourceNode symmetrisch zu stop() wieder abbauen, sonst leakt er und
            // ein erneuter play()-Aufruf haengt einen zweiten Knoten an.
            audioEngine.disconnectNodeOutput(sourceNode)
            audioEngine.detach(sourceNode)
            self.sourceNode = nil
            self.engineProcessor = nil
        }
    }

    // Pause: haelt die Wiedergabe an, BEHAELT aber Processor, Source-Node und
    // Emulations-Stand — play() setzt danach genau hier fort. Im Gegensatz zu
    // stop(), das alles abbaut und an den Anfang zuruecksetzt.
    public func pause() {
        guard isPlaying else { return }
        audioEngine.pause()
        isPlaying = false
        isPaused = true
        stopUIUpdates()
    }

    public func stop() {
        cancelSeekPreparation()
        audioEngine.stop()
        if let node = sourceNode {
            audioEngine.disconnectNodeOutput(node)
            audioEngine.detach(node)
        }
        sourceNode = nil
        engineProcessor = nil
        processorSlot = nil
        isPlaying = false
        isPaused = false
        stopUIUpdates()

        // Stop bedeutet „zurueck an den Anfang": Position und gemerkten Seek loeschen.
        pendingSeekSeconds = nil
        self.elapsedSeconds = 0.0
        visualsBuffer.updatePlaytime(0.0)

        // Die Anzeigewerte muessen hier nicht zurueckgesetzt werden: Die
        // Oszilloskope zeichnen im Stop-Zustand die Null-Linie und lesen den
        // Puffer gar nicht erst.
    }

    /// Wirft die Audio-Engine weg und legt eine neue an.
    ///
    /// Gebraucht wird das nach `mediaServicesWereReset`: Der Audiodienst des
    /// Systems ist neu gestartet, die alte Engine ist tot. `stop()` allein
    /// genuegt nicht — es baut zwar den Source-Node ab und wirft den Emulator
    /// weg, benutzt danach aber weiter dieselbe (ungueltige) Engine.
    ///
    /// Der Aufrufer baut anschliessend seinen Titel neu auf; der Zustand hier
    /// ist danach derselbe wie nach `stop()`, also Anfang.
    public func rebuildAudioEngine() {
        stop()
        audioEngine = AVAudioEngine()
        audioEngineGeneration &+= 1
    }

    /// Wie oft die Engine schon neu angelegt wurde. Nur zur Diagnose (und um
    /// den Neuaufbau ueberhaupt pruefbar zu machen) — die Wiedergabe rechnet
    /// nicht damit.
    public private(set) var audioEngineGeneration = 0

    public func setVolume(_ vol: Float) {
        self.currentVolume = vol
        // Psychoakustische Lautstaerke-Kurve (quadratisch) — einzige Stelle, an der
        // die Master-Lautstaerke angewandt wird. Der Processor bleibt bei 1.0, damit
        // der Regler nicht doppelt (effektiv kubisch) wirkt.
        audioEngine.mainMixerNode.outputVolume = vol * vol
    }

    // SID-Modell-Override setzen (nil = Auto). Wirkt live auf den laufenden Song.
    public func setModelOverride(_ model: Int?) {
        self.modelOverride = model
        if let processor = engineProcessor {
            processor.setModelOverride(model.map { Double($0) })
        }
    }

    // Stimme 1-3 stumm/laut schalten (Analyse; wirkt live auf den laufenden Song).
    public func toggleVoiceMuted(_ voice: Int) {
        guard voice >= 0 && voice < voiceMuted.count else { return }
        voiceMuted[voice].toggle()
        engineProcessor?.setVoiceMuted(voice: voice, muted: voiceMuted[voice])
    }

    // SID-Filter an/aus (Analyse; wirkt live auf den laufenden Song).
    public func toggleFilterEnabled() {
        filterEnabled.toggle()
        engineProcessor?.setFilterEnabled(filterEnabled)
    }

    private func cancelSeekPreparation() {
        seekGeneration &+= 1
        seekTask?.cancel()
        seekTask = nil
    }

    public func seek(seconds: Double) {
        let target = ViciousProcessor.normalizedSeekSeconds(seconds)
        cancelSeekPreparation()
        if let processor = engineProcessor, let slot = processorSlot, let sid = activeSid {
            // Ein eigener Processor berechnet den Zielstand. Weder MainActor
            // noch der Lock des gerade ausgegebenen Processors warten darauf.
            audioEngine.pause()
            let generation = seekGeneration
            let sub = currentSubtune
            let rate = processor.sampleRate
            let model = modelOverride
            let worker = Task.detached(priority: .userInitiated) {
                let prepared = ViciousProcessor(sampleRate: rate)
                _ = prepared.loadSID(sidFile: sid)
                prepared.setModelOverride(model.map { Double($0) })
                prepared.initSubtune(sub: sub)
                try prepared.seekCancellable(seconds: target) { try Task.checkCancellation() }
                return prepared
            }
            seekTask = Task { [weak self] in
                do {
                    let prepared = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    guard let self, self.seekGeneration == generation else { return }
                    prepared.setModelOverride(self.modelOverride.map { Double($0) })
                    for voice in 0..<3 { prepared.setVoiceMuted(voice: voice, muted: self.voiceMuted[voice]) }
                    prepared.setFilterEnabled(self.filterEnabled)
                    slot.replace(with: prepared)
                    self.engineProcessor = prepared
                    self.seekTask = nil
                    self.visualsBuffer.updatePlaytime(target)
                    if self.isPlaying { try self.audioEngine.start() }
                } catch {
                    guard let self, self.seekGeneration == generation else { return }
                    self.seekTask = nil
                    self.stopUIUpdates()
                    self.isPlaying = false
                    self.isPaused = true
                }
            }
        } else {
            pendingSeekSeconds = target
        }
        visualsBuffer.updatePlaytime(target)
        elapsedSeconds = target
    }

    public func setSubtune(sub: Int) {
        guard sub >= 0 && sub < subtunesCount else { return }
        let wasSeeking = isPreparingSeek
        cancelSeekPreparation()
        self.currentSubtune = sub
        self.elapsedSeconds = 0.0
        self.pendingSeekSeconds = nil
        visualsBuffer.updatePlaytime(0.0)

        if let processor = engineProcessor {
            processor.initSubtune(sub: sub)
        }
        if wasSeeking && isPlaying { try? audioEngine.start() }
    }

    // Taktrate der UI-Aktualisierung setzen.
    //
    // Wozu: die Audioausgabe laeuft auf einem eigenen Realtime-Thread und ist
    // von diesem Timer voellig unabhaengig. Der Timer spiegelt nur Messwerte
    // ins UI. Auf iOS spielt die App im gesperrten Zustand weiter — dort waeren
    // 50 Aktualisierungen pro Sekunde fuer einen ausgeschalteten Bildschirm
    // reine Batterieheizung. Die App schaltet deshalb im Hintergrund auf einen
    // langsamen Takt (etwa 1 s) und im Vordergrund zurueck auf 0,02 s.
    //
    // Bewusst nicht "aus": die verstrichene Zeit wird auch im Hintergrund
    // gebraucht — fuer Auto-Next und fuer die Anzeige auf dem Sperrbildschirm.
    //
    // Die Mac-App ruft das nie auf und behaelt den Standardtakt von 0,02 s.
    public func setUIUpdateInterval(_ seconds: TimeInterval) {
        let clamped = (seconds.isFinite && seconds > 0) ? seconds : 0.02
        guard clamped != uiUpdateInterval else { return }
        uiUpdateInterval = clamped
        // Laeuft gerade ein Timer, mit der neuen Taktrate neu aufsetzen.
        if uiUpdateTimer != nil {
            stopUIUpdates()
            startUIUpdates()
        }
    }

    private func startUIUpdates() {
        // Im .common-Modus in die RunLoop haengen, damit der Timer AUCH waehrend
        // eines Slider-Drags feuert. Slider-Tracking laeuft im Event-Tracking-Modus;
        // ein Timer im Default-Modus pausiert dann und das Oszilloskop wuerde beim
        // Ziehen des Volume-/Positions-Reglers einfrieren.
        let timer = Timer(timeInterval: uiUpdateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateUI()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiUpdateTimer = timer
    }

    private func stopUIUpdates() {
        uiUpdateTimer?.invalidate()
        uiUpdateTimer = nil
    }

    /// Der aktuelle Anzeigestand der drei Stimmen, an SwiftUI vorbei.
    ///
    /// Gedacht fuer Ansichten, die ohnehin in ihrem eigenen Takt zeichnen (die
    /// Oszilloskope). Sie holen sich den Stand beim Zeichnen ab, statt ihn sich
    /// 50-mal je Sekunde zustellen zu lassen — siehe die Begruendung oben bei
    /// den Anzeigewerten.
    public func currentVisuals() -> VoiceVisuals {
        let b = visualsBuffer.read()
        return VoiceVisuals(envelopes: [b.envelopes.0, b.envelopes.1, b.envelopes.2],
                            frequencies: [b.frequencies.0, b.frequencies.1, b.frequencies.2],
                            gates: [b.gates.0, b.gates.1, b.gates.2],
                            waveforms: [b.waveforms.0, b.waveforms.1, b.waveforms.2],
                            pulsewidths: [b.pulsewidths.0, b.pulsewidths.1, b.pulsewidths.2])
    }

    private func updateUI() {
        guard seekTask == nil else { return }
        // Nur noch die Spielzeit geht durch SwiftUI — und auch die nur, wenn
        // sie sich um mindestens ein Zehntel geaendert hat. Der Zeitanzeige und
        // dem Positionsregler genuegt das; jede Zuweisung wirft sonst den
        // Rumpf der Oberflaeche neu auf.
        let playtime = visualsBuffer.read().playtime
        if abs(playtime - elapsedSeconds) >= 0.1 || playtime == 0.0 {
            self.elapsedSeconds = playtime
        }
    }
}
#endif
