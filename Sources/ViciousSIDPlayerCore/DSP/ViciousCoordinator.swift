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
    private var visuals: SidVisuals = .silent
    public var visualizerTicker: Int = 0
    public init() {}

    public func write(_ value: SidVisuals) {
        lock.lock(); visuals = value; lock.unlock()
    }

    public func write(envelopes: (Float, Float, Float), frequencies: (Int, Int, Int),
                      gates: (Int, Int, Int), waveforms: (Int, Int, Int),
                      pulsewidths: (Float, Float, Float), playtime: Double) {
        let first = SidChipVisuals(envelopes: envelopes, frequencies: frequencies, gates: gates,
                                  waveforms: waveforms, pulsewidths: pulsewidths)
        write(SidVisuals(chips: (first, .silent, .silent), playtime: playtime))
    }

    public func updatePlaytime(_ playtime: Double) {
        lock.lock(); visuals.playtime = playtime; lock.unlock()
    }

    public func readVisuals() -> SidVisuals {
        lock.lock(); defer { lock.unlock() }
        return visuals
    }

    public func read() -> (envelopes: (Float, Float, Float), frequencies: (Int, Int, Int),
                           gates: (Int, Int, Int), waveforms: (Int, Int, Int),
                           pulsewidths: (Float, Float, Float), playtime: Double) {
        let value = readVisuals()
        return (value.envelopes, value.frequencies, value.gates, value.waveforms, value.pulsewidths, value.playtime)
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
    @Published public private(set) var clockMode: SidClockMode = .auto
    @Published public private(set) var clockPreference: SidClockPreference = .unknown
    public var effectiveClock: C64Clock { clockMode.resolve(clockPreference) }
    // Nur Nutzerentscheidungen werden veröffentlicht; Registerwerte bleiben
    // im festen Echtzeitpuffer und werden beim Zeichnen gelesen.
    @Published public private(set) var analysisMix = AnalysisMix()
    @Published public private(set) var activeSIDChips = [0]
    @Published public private(set) var sidBaseAddresses: [UInt32] = [0xd400, 0, 0]
    @Published public private(set) var preferredChipModels = [8580, 8580, 8580]
    public var voiceMuted: [Bool] {
        get { Array(analysisMix.channelMuted.prefix(3)) }
        set {
            guard newValue.count == 3 else { return }
            var mix = analysisMix
            for voice in 0..<3 { mix.setVoiceMuted(voice, muted: newValue[voice]) }
            analysisMix = mix; applyAnalysisMix()
        }
    }
    public var effectiveChannelMuted: [Bool] { analysisMix.effectiveMuted(activeChips: activeSIDChips) }
    @Published public var filterEnabled = true
    @Published public private(set) var playbackLoop = PlaybackLoop()
    @Published public private(set) var isPreparingLoop = false
    @Published public private(set) var loopError: String?
    private var loopTask: Task<Void, Never>?
    private var loopGeneration = 0
    private var loopDuration = 360.0
    private var loopSnapshot: ViciousProcessor.PreparedLoop?

    // Die Anzeigewerte aller SID-Stimmen (Huellkurve, Frequenz, Gate, Wellenform,
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
    public var hasSID: Bool { activeSid != nil }
    private var engineProcessor: ViciousProcessor?
    private var processorSlot: ProcessorSlot?
    private var seekTask: Task<Void, Never>?
    private var seekGeneration = 0
    public var isPreparingSeek: Bool { seekTask != nil }
    private let visualsBuffer = RealtimeVisualsBuffer()
    private var uiUpdateTimer: Timer?
    // Nur die Laufzeit wird gespiegelt; schnelle Stimmenwerte liest die
    // Zeichenansicht direkt. Siehe setUIUpdateInterval().
    private var uiUpdateInterval: TimeInterval = 0.1
    private var currentVolume: Float = 0.3
    private var fadeEnvelope = PlaybackFadeEnvelope()
    // Zielposition eines Seeks, der im gestoppten Zustand angefordert wurde (dann
    // gibt es noch keinen Processor). play() wendet sie beim Aufbau an, damit die
    // Wiedergabe an der per Slider gewaehlten Stelle beginnt.
    private var pendingSeekSeconds: Double?

    public init() {}

    public func setSid(_ fileData: SidFileData) {
        stop()
        playbackLoop.clear()
        self.activeSid = fileData
        self.trackName = fileData.metadata.title
        self.composer = fileData.metadata.author
        self.info = fileData.metadata.info
        self.subtunesCount = fileData.metadata.subtunesCount
        self.currentSubtune = 0
        self.elapsedSeconds = 0.0
        self.prefModel = fileData.prefModel
        self.clockPreference = fileData.clockPreference
        sidBaseAddresses = [0xd400, fileData.secondSidAddress, fileData.thirdSidAddress]
        activeSIDChips = [0] + (fileData.secondSidAddress != 0 ? [1] : []) + (fileData.thirdSidAddress != 0 ? [2] : [])
        preferredChipModels = [fileData.prefModel,
            fileData.prefModel2 == 0 ? fileData.prefModel : fileData.prefModel2,
            fileData.prefModel3 == 0 ? fileData.prefModel : fileData.prefModel3]
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
                if playbackLoop.isEnabled, loopSnapshot == nil, loopTask == nil { prepareActiveLoop() }
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
        let processor = ViciousProcessor(sampleRate: sampleRate, clockMode: clockMode)
        _ = processor.loadSID(sidFile: sid)
        processor.setModelOverride(modelOverride.map { Double($0) })
        processor.setMutedChannels(effectiveChannelMuted)
        processor.setFilterEnabled(filterEnabled)
        processor.initSubtune(sub: currentSubtune)
        processor.setFadeEnvelope(effectiveFadeEnvelope)
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
                buffer.write(liveData)
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
            else { prepareActiveLoop() }
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
        playbackLoop.setEnabled(false)
        cancelLoopPreparation()
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

    public func setFadeEnvelope(_ envelope: PlaybackFadeEnvelope) {
        fadeEnvelope = envelope
        engineProcessor?.setFadeEnvelope(effectiveFadeEnvelope)
    }

    // SID-Modell-Override setzen (nil = Auto). Wirkt live auf den laufenden Song.
    public func setModelOverride(_ model: Int?) {
        self.modelOverride = model
        if let processor = engineProcessor {
            processor.setModelOverride(model.map { Double($0) })
        }
        prepareActiveLoop()
    }

    public func setClockMode(_ mode: SidClockMode) {
        guard mode != clockMode else { return }
        clockMode = mode
        // Ein anderer Takt veraendert CPU, Huellkurven und Oszillatoren. Der
        // Zielstand wird deshalb wie beim Seek im Hintergrund neu aufgebaut.
        if engineProcessor != nil { seek(seconds: elapsedSeconds, preserveLoop: true) }
        prepareActiveLoop()
    }

    // Stimme 1-3 stumm/laut schalten (Analyse; wirkt live auf den laufenden Song).
    public func toggleVoiceMuted(_ voice: Int) {
        guard voice >= 0 && voice < voiceMuted.count else { return }
        var mix = analysisMix
        mix.setVoiceMuted(voice, muted: !mix.channelMuted[voice])
        analysisMix = mix; applyAnalysisMix()
    }

    public func toggleChannelMuted(_ channel: Int) {
        analysisMix.toggleChannelMuted(channel); applyAnalysisMix()
    }
    public func toggleChipMuted(_ chip: Int) {
        analysisMix.toggleChipMuted(chip); applyAnalysisMix()
    }
    public func toggleChannelSolo(_ channel: Int) {
        analysisMix.toggleSolo(channel); applyAnalysisMix()
    }
    public func clearSolos() {
        analysisMix.clearSolos(); applyAnalysisMix()
    }
    private func applyAnalysisMix() {
        engineProcessor?.setMutedChannels(effectiveChannelMuted)
        prepareActiveLoop()
    }
    public func modelForChip(_ chip: Int) -> Int {
        modelOverride ?? (preferredChipModels.indices.contains(chip) ? preferredChipModels[chip] : prefModel)
    }

    // SID-Filter an/aus (Analyse; wirkt live auf den laufenden Song).
    public func toggleFilterEnabled() {
        filterEnabled.toggle()
        engineProcessor?.setFilterEnabled(filterEnabled)
        prepareActiveLoop()
    }

    private var effectiveFadeEnvelope: PlaybackFadeEnvelope {
        PlaybackFadeEnvelope(songEnd: playbackLoop.isEnabled ? nil : fadeEnvelope.songEnd,
                             timerEnd: fadeEnvelope.timerEnd, seconds: fadeEnvelope.seconds)
    }

    public func setLoopDuration(_ seconds: Double) {
        guard seconds != loopDuration else { return }
        loopDuration = seconds
        let before = playbackLoop
        playbackLoop.constrain(to: seconds)
        if playbackLoop != before { prepareActiveLoop() }
    }
    public func setLoopStart() {
        playbackLoop.setStart(elapsedSeconds, duration: min(loopDuration, ViciousProcessor.maximumSeekSeconds))
        prepareActiveLoop()
    }
    public func setLoopEnd() {
        playbackLoop.setEnd(elapsedSeconds, duration: loopDuration)
        prepareActiveLoop()
    }
    public func setLoopEnabled(_ enabled: Bool) {
        playbackLoop.setEnabled(enabled)
        prepareActiveLoop()
    }
    public func clearLoop() {
        playbackLoop.clear()
        prepareActiveLoop()
    }
    /// Nach einem Engine-Neuaufbau darf das Frontend die Sitzungsauswahl nur
    /// bei derselben nachweislich unveränderten Datei und demselben Subtune übernehmen.
    public func restoreLoop(_ selection: PlaybackLoop) {
        playbackLoop = selection
        playbackLoop.constrain(to: loopDuration)
        prepareActiveLoop()
    }
    private func cancelLoopPreparation() {
        loopGeneration &+= 1
        loopTask?.cancel(); loopTask = nil
        loopSnapshot = nil
        isPreparingLoop = false
        engineProcessor?.disableLoop()
        engineProcessor?.setFadeEnvelope(effectiveFadeEnvelope)
    }
    private func prepareActiveLoop() {
        cancelLoopPreparation()
        loopError = nil
        guard playbackLoop.isEnabled, let range = playbackLoop.range,
              let sid = activeSid, let processor = engineProcessor else { return }
        let generation = loopGeneration
        let sub = currentSubtune, rate = processor.sampleRate, model = modelOverride
        let muted = effectiveChannelMuted, filter = filterEnabled, clock = clockMode
        isPreparingLoop = true
        let worker = Task.detached(priority: .userInitiated) {
            try ViciousProcessor.prepareLoop(sid: sid, subtune: sub, sampleRate: rate,
                range: range, model: model, muted: muted, filterEnabled: filter, clockMode: clock) {
                    try Task.checkCancellation()
                }
        }
        loopTask = Task { [weak self] in
            do {
                let snapshot = try await withTaskCancellationHandler { try await worker.value }
                    onCancel: { worker.cancel() }
                guard let self, self.loopGeneration == generation else { return }
                self.loopTask = nil; self.isPreparingLoop = false
                self.loopSnapshot = snapshot
                if let current = self.engineProcessor, !current.installLoop(snapshot) {
                    // Während eines Takt-Seeks lebt kurz der alte Processor.
                    // Der fertige neue Processor übernimmt denselben Snapshot.
                    if !self.isPreparingSeek { self.failLoopPreparation() }
                }
                self.engineProcessor?.setFadeEnvelope(self.effectiveFadeEnvelope)
            } catch {
                guard let self, self.loopGeneration == generation else { return }
                self.failLoopPreparation()
            }
        }
    }
    private func failLoopPreparation() {
        playbackLoop.setEnabled(false)
        cancelLoopPreparation()
        loopError = NSLocalizedString("A/B-Schleife konnte nicht vorbereitet werden.", comment: "")
    }

    /// Register bleiben im vorhandenen Echtzeitpuffer. Erst die lesende
    /// Oberfläche wählt einen Chip; hier entsteht kein Array im Audiocallback.
    public func currentRegisters(chip: Int) -> SidChipVisuals {
        visualsBuffer.readVisuals().chip(chip)
    }

    private func cancelSeekPreparation() {
        seekGeneration &+= 1
        seekTask?.cancel()
        seekTask = nil
    }

    public func seek(seconds: Double) {
        seek(seconds: seconds, preserveLoop: false)
    }

    private func seek(seconds: Double, preserveLoop: Bool) {
        let target = ViciousProcessor.normalizedSeekSeconds(seconds)
        if !preserveLoop { playbackLoop.seek(to: target) }
        if !playbackLoop.isEnabled { cancelLoopPreparation() }
        cancelSeekPreparation()
        if let processor = engineProcessor, let slot = processorSlot, let sid = activeSid {
            // Ein eigener Processor berechnet den Zielstand. Weder MainActor
            // noch der Lock des gerade ausgegebenen Processors warten darauf.
            audioEngine.pause()
            let generation = seekGeneration
            let sub = currentSubtune
            let rate = processor.sampleRate
            let model = modelOverride
            let clock = clockMode
            let muted = effectiveChannelMuted
            let worker = Task.detached(priority: .userInitiated) {
                try Self.prepareSeekProcessor(sid: sid, subtune: sub, sampleRate: rate,
                                              model: model, voiceMuted: muted, seconds: target,
                                              clockMode: clock)
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
                    prepared.setMutedChannels(self.effectiveChannelMuted)
                    prepared.setFilterEnabled(self.filterEnabled)
                    prepared.setFadeEnvelope(self.effectiveFadeEnvelope)
                    let loopInstalled = self.playbackLoop.isEnabled
                        && (self.loopSnapshot.map { prepared.installLoop($0) } ?? false)
                    slot.replace(with: prepared)
                    self.engineProcessor = prepared
                    self.seekTask = nil
                    self.visualsBuffer.updatePlaytime(target)
                    if self.isPlaying { try self.audioEngine.start() }
                    if self.playbackLoop.isEnabled, !loopInstalled, self.loopTask == nil { self.prepareActiveLoop() }
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

    nonisolated static func prepareSeekProcessor(sid: SidFileData, subtune: Int,
                                                sampleRate: Double, model: Int?,
                                                voiceMuted: [Bool], seconds: Double,
                                                clockMode: SidClockMode = .auto) throws -> ViciousProcessor {
        let prepared = ViciousProcessor(sampleRate: sampleRate, clockMode: clockMode)
        _ = prepared.loadSID(sidFile: sid)
        prepared.setModelOverride(model.map { Double($0) })
        prepared.initSubtune(sub: subtune)
        // Mute beeinflusst den Filtereingang und muss deshalb schon beim
        // Vorspulen gelten; spaeteres Setzen liesse einen hoerbaren Filterrest.
        prepared.setMutedChannels(voiceMuted.count == 3 ? (0..<9).map { voiceMuted[$0 % 3] } : voiceMuted)
        try prepared.seekCancellable(seconds: seconds) { try Task.checkCancellation() }
        return prepared
    }

    public func setSubtune(sub: Int) {
        guard sub >= 0 && sub < subtunesCount else { return }
        let wasSeeking = isPreparingSeek
        cancelSeekPreparation()
        playbackLoop.clear()
        cancelLoopPreparation()
        self.currentSubtune = sub
        self.elapsedSeconds = 0.0
        self.pendingSeekSeconds = nil
        visualsBuffer.write(.silent)

        if wasSeeking, let processor = engineProcessor, let sid = activeSid, let slot = processorSlot {
            // Ein abgebrochener Taktwechsel darf den alten Processor nicht
            // behalten: dessen CPU-Takt ist beim Laden festgelegt worden.
            let replacement = ViciousProcessor(sampleRate: processor.sampleRate, clockMode: clockMode)
            _ = replacement.loadSID(sidFile: sid)
            replacement.setModelOverride(modelOverride.map { Double($0) })
            replacement.setMutedChannels(effectiveChannelMuted)
            replacement.setFilterEnabled(filterEnabled)
            replacement.initSubtune(sub: sub)
            replacement.setFadeEnvelope(effectiveFadeEnvelope)
            slot.replace(with: replacement)
            engineProcessor = replacement
        } else { engineProcessor?.initSubtune(sub: sub) }
        if wasSeeking && isPlaying { try? audioEngine.start() }
    }

    // Taktrate der UI-Aktualisierung setzen.
    //
    // Wozu: die Audioausgabe laeuft auf einem eigenen Realtime-Thread und ist
    // von diesem Timer voellig unabhaengig. Der Timer spiegelt nur Messwerte
    // ins UI. Auf iOS spielt die App im gesperrten Zustand weiter — dort waeren
    // 50 Aktualisierungen pro Sekunde fuer einen ausgeschalteten Bildschirm
    // unnoetige Arbeit. Die Frontends schalten deshalb bei unsichtbarer
    // Oberflaeche auf 1 s. Sichtbar reichen 0,1 s fuer Zeit und Scrubber;
    // Oszilloskop und Analyse lesen ihre Werte in eigenen Zeichenplaenen.
    //
    // Bewusst nicht "aus": die verstrichene Zeit wird auch im Hintergrund
    // gebraucht — fuer Auto-Next und fuer die Anzeige auf dem Sperrbildschirm.
    //
    public func setUIUpdateInterval(_ seconds: TimeInterval) {
        let clamped = (seconds.isFinite && seconds > 0) ? seconds : 0.1
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

    /// Der aktuelle Anzeigestand der drei Stimmen eines Chips, an SwiftUI vorbei.
    ///
    /// Gedacht fuer Ansichten, die ohnehin in ihrem eigenen Takt zeichnen (die
    /// Oszilloskope). Sie holen sich den Stand beim Zeichnen ab, statt ihn sich
    /// 50-mal je Sekunde zustellen zu lassen — siehe die Begruendung oben bei
    /// den Anzeigewerten.
    public func currentVisuals(chip: Int = 0) -> VoiceVisuals {
        let b = visualsBuffer.readVisuals().chip(chip)
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
