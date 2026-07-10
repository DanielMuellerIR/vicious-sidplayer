import Foundation
import AVFoundation
import Combine

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

    // Live visual data bound to the UI
    @Published public var envelopes: [Float] = [0.0, 0.0, 0.0]
    @Published public var frequencies: [Int] = [0, 0, 0]
    @Published public var gates: [Int] = [0, 0, 0]
    @Published public var waveforms: [Int] = [0, 0, 0]
    @Published public var pulsewidths: [Float] = [0.5, 0.5, 0.5]

    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // codereview-ok: activeSid ist die Quelle, aus der play() den Processor neu erzeugt (2026-07-01)
    private var activeSid: SidFileData?
    private var engineProcessor: ViciousProcessor?
    private let visualsBuffer = RealtimeVisualsBuffer()
    private var uiUpdateTimer: Timer?
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
        // Wurde im gestoppten Zustand vorgespult, hier an die Zielposition springen.
        if let target = pendingSeekSeconds {
            processor.seek(seconds: target)
            visualsBuffer.updatePlaytime(target)
            pendingSeekSeconds = nil
        }
        // Die Master-Lautstaerke regelt ausschliesslich der Mixer (siehe unten,
        // quadratische psychoakustische Kurve). Der Processor rendert deshalb mit
        // seiner vollen Standard-Lautstaerke (1.0) — wuerde er hier zusaetzlich mit
        // currentVolume skaliert, laege der Regler effektiv bei currentVolume^3.
        self.engineProcessor = processor

        let buffer = visualsBuffer

        // Safe process block called on Real-Time CoreAudio Thread
        let renderBlock: @Sendable (UnsafeMutablePointer<ObjCBool>, UnsafePointer<AudioTimeStamp>, UInt32, UnsafeMutablePointer<AudioBufferList>) -> OSStatus = { [processor] (isSilence, timestamp, frameCount, outputData) -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard buffers.count >= 2,
                  let leftPtr = buffers[0].mData,
                  let rightPtr = buffers[1].mData else {
                return noErr
            }

            let left = leftPtr.assumingMemoryBound(to: Float.self)
            let right = rightPtr.assumingMemoryBound(to: Float.self)

            for frame in 0..<Int(frameCount) {
                let sample = Float(processor.play())
                left[frame] = sample
                right[frame] = sample
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
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            isPlaying = true
            isPaused = false
            startUIUpdates()
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
        audioEngine.stop()
        if let node = sourceNode {
            audioEngine.disconnectNodeOutput(node)
            audioEngine.detach(node)
        }
        sourceNode = nil
        engineProcessor = nil
        isPlaying = false
        isPaused = false
        stopUIUpdates()

        // Stop bedeutet „zurueck an den Anfang": Position und gemerkten Seek loeschen.
        pendingSeekSeconds = nil
        self.elapsedSeconds = 0.0
        visualsBuffer.updatePlaytime(0.0)

        // Reset visuals
        self.envelopes = [0.0, 0.0, 0.0]
        self.frequencies = [0, 0, 0]
        self.gates = [0, 0, 0]
        self.waveforms = [0, 0, 0]
        self.pulsewidths = [0.5, 0.5, 0.5]
    }

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

    public func seek(seconds: Double) {
        let target = (seconds.isFinite && !seconds.isNaN) ? max(0.0, seconds) : 0.0
        if let processor = engineProcessor {
            // Laeuft oder pausiert: direkt im Emulator springen.
            processor.seek(seconds: target)
        } else {
            // Gestoppt/frisch geladen: Zielposition merken, play() wendet sie an.
            pendingSeekSeconds = target
        }
        visualsBuffer.updatePlaytime(target)
        self.elapsedSeconds = target
    }

    public func setSubtune(sub: Int) {
        guard sub >= 0 && sub < subtunesCount else { return }
        self.currentSubtune = sub
        self.elapsedSeconds = 0.0
        self.pendingSeekSeconds = nil
        visualsBuffer.updatePlaytime(0.0)

        if let processor = engineProcessor {
            processor.initSubtune(sub: sub)
        }
    }

    private func startUIUpdates() {
        // Im .common-Modus in die RunLoop haengen, damit der Timer AUCH waehrend
        // eines Slider-Drags feuert. Slider-Tracking laeuft im Event-Tracking-Modus;
        // ein Timer im Default-Modus pausiert dann und das Oszilloskop wuerde beim
        // Ziehen des Volume-/Positions-Reglers einfrieren.
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
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

    private func updateUI() {
        let b = visualsBuffer.read()
        self.envelopes = [b.envelopes.0, b.envelopes.1, b.envelopes.2]
        self.frequencies = [b.frequencies.0, b.frequencies.1, b.frequencies.2]
        self.gates = [b.gates.0, b.gates.1, b.gates.2]
        self.waveforms = [b.waveforms.0, b.waveforms.1, b.waveforms.2]
        self.pulsewidths = [b.pulsewidths.0, b.pulsewidths.1, b.pulsewidths.2]
        self.elapsedSeconds = b.playtime
    }
}
