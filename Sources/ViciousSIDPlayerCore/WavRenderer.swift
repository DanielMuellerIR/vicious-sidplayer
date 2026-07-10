import Foundation

// Headless-WAV-Export: rendert einen Subtune schneller als Echtzeit (die
// Emulation ist nicht an die Audio-Hardware gebunden) in eine WAV-Datei.
// Format: 16-bit PCM, mono (der Emulator liefert ein Mono-Signal), 44,1 kHz.
// Genutzt vom GUI-Export (Menue "Wiedergabe") und vom CLI (sidcheck --wav) —
// AI-Agent-/Skript-steuerbar ohne laufende GUI.
public enum WavRenderer {

    public enum RenderError: Error, LocalizedError {
        case invalidDuration
        public var errorDescription: String? {
            switch self {
            case .invalidDuration: return "Ungültige Dauer für den WAV-Export."
            }
        }
    }

    // Rendert `seconds` Sekunden des Subtunes in eine WAV-Datei bei `url`.
    // modelOverride: nil = Auto (Datei-Praeferenz), 6581/8580 erzwingen das Modell.
    public static func render(sidFile: SidFileData,
                              subtune: Int = 0,
                              seconds: Double,
                              sampleRate: Double = 44100.0,
                              modelOverride: Int? = nil,
                              to url: URL) throws {
        guard seconds.isFinite && seconds > 0 else { throw RenderError.invalidDuration }

        let processor = ViciousProcessor(sampleRate: sampleRate)
        _ = processor.loadSID(sidFile: sidFile)
        processor.setModelOverride(modelOverride.map { Double($0) })
        // Subtune sicher in den gueltigen Bereich klemmen (0-basiert).
        let sub = max(0, min(subtune, sidFile.metadata.subtunesCount - 1))
        processor.initSubtune(sub: sub)
        processor.setVolume(vol: 1.0)

        // Samples synthetisieren und nach 16-bit PCM wandeln (hart geclippt —
        // der Emulator bleibt normalerweise deutlich unter Vollaussteuerung).
        // Multi-SID-Tunes (2SID/3SID) werden stereo exportiert (gepannte Chips),
        // Single-SID mono.
        let stereo = sidFile.secondSidAddress != 0
        let totalSamples = Int(seconds * sampleRate)
        var pcm = [Int16](repeating: 0, count: totalSamples * (stereo ? 2 : 1))
        if stereo {
            for i in 0..<totalSamples {
                let sample = processor.playStereo()
                pcm[i * 2] = Int16(max(-1.0, min(1.0, sample.left)) * 32767.0)
                pcm[i * 2 + 1] = Int16(max(-1.0, min(1.0, sample.right)) * 32767.0)
            }
        } else {
            for i in 0..<totalSamples {
                let sample = max(-1.0, min(1.0, processor.play()))
                pcm[i] = Int16(sample * 32767.0)
            }
        }

        try wavData(pcm: pcm, sampleRate: Int(sampleRate), channels: stereo ? 2 : 1).write(to: url)
    }

    // Baut die komplette WAV-Datei (RIFF-Header + PCM-Daten, little-endian).
    // pcm ist bei channels == 2 interleaved (L, R, L, R, ...).
    static func wavData(pcm: [Int16], sampleRate: Int, channels: Int = 1) -> Data {
        let dataSize = pcm.count * 2         // 16 Bit = 2 Bytes pro Sample
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2

        var out = Data(capacity: 44 + dataSize)
        // RIFF-Chunk
        out.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(&out, UInt32(36 + dataSize))    // Restgroesse der Datei
        out.append(contentsOf: Array("WAVE".utf8))
        // fmt-Chunk (PCM)
        out.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(&out, 16)                       // fmt-Chunk-Groesse
        appendUInt16(&out, 1)                        // Audio-Format: 1 = PCM
        appendUInt16(&out, UInt16(channels))
        appendUInt32(&out, UInt32(sampleRate))
        appendUInt32(&out, UInt32(byteRate))
        appendUInt16(&out, UInt16(blockAlign))
        appendUInt16(&out, 16)                       // Bits pro Sample
        // data-Chunk
        out.append(contentsOf: Array("data".utf8))
        appendUInt32(&out, UInt32(dataSize))
        // Int16-Samples sind auf allen Apple-Plattformen bereits little-endian.
        pcm.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
