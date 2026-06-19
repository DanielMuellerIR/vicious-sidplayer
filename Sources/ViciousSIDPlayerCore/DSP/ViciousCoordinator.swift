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
    @Published public var trackName = "Kein Song geladen"
    @Published public var composer = "Unbekannter Komponist"
    @Published public var info = "Vicious SID Player"
    @Published public var currentSubtune = 0
    @Published public var subtunesCount = 1
    @Published public var elapsedSeconds: Double = 0.0
    @Published public var prefModel: Int = 8580
    // Nutzer-Override des SID-Modells: nil = Auto (Datei-Praeferenz), 6581 oder 8580.
    @Published public var modelOverride: Int? = nil

    // Live visual data bound to the UI
    @Published public var envelopes: [Float] = [0.0, 0.0, 0.0]
    @Published public var frequencies: [Int] = [0, 0, 0]
    @Published public var gates: [Int] = [0, 0, 0]
    @Published public var waveforms: [Int] = [0, 0, 0]
    @Published public var pulsewidths: [Float] = [0.5, 0.5, 0.5]

    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    private var activeSid: SidFileData?
    private var engineProcessor: ViciousProcessor?
    private let visualsBuffer = RealtimeVisualsBuffer()
    private var uiUpdateTimer: Timer?
    private var currentVolume: Float = 0.3

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
        processor.initSubtune(sub: currentSubtune)
        processor.setVolume(vol: Double(currentVolume))
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

        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            isPlaying = true
            startUIUpdates()
        } catch {
            print("Fehler beim Starten der AVAudioEngine: \(error)")
        }
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
        stopUIUpdates()
        
        // Reset visuals
        self.envelopes = [0.0, 0.0, 0.0]
        self.frequencies = [0, 0, 0]
        self.gates = [0, 0, 0]
        self.waveforms = [0, 0, 0]
        self.pulsewidths = [0.5, 0.5, 0.5]
    }

    public func setVolume(_ vol: Float) {
        self.currentVolume = vol
        // Psychoacoustic volume mapping (quadratic)
        audioEngine.mainMixerNode.outputVolume = vol * vol
        if let processor = engineProcessor {
            processor.setVolume(vol: Double(vol))
        }
    }

    // SID-Modell-Override setzen (nil = Auto). Wirkt live auf den laufenden Song.
    public func setModelOverride(_ model: Int?) {
        self.modelOverride = model
        if let processor = engineProcessor {
            processor.setModelOverride(model.map { Double($0) })
        }
    }

    public func seek(seconds: Double) {
        if let processor = engineProcessor {
            processor.seek(seconds: seconds)
            visualsBuffer.updatePlaytime(seconds)
            self.elapsedSeconds = seconds
        }
    }

    public func setSubtune(sub: Int) {
        guard sub >= 0 && sub < subtunesCount else { return }
        self.currentSubtune = sub
        self.elapsedSeconds = 0.0
        visualsBuffer.updatePlaytime(0.0)

        if let processor = engineProcessor {
            processor.initSubtune(sub: sub)
        }
    }

    private func startUIUpdates() {
        uiUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.updateUI()
            }
        }
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
