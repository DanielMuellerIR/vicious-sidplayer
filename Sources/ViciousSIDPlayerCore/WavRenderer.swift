import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Headless-WAV-Export: rendert einen Subtune schneller als Echtzeit (die
// Emulation ist nicht an die Audio-Hardware gebunden) in eine WAV-Datei.
// Format: 16-Bit-PCM, mono für 1SID und stereo für Multi-SID, 44,1 kHz.
// Genutzt vom GUI-Export (Menue "Wiedergabe") und vom CLI (sidcheck --wav) —
// AI-Agent-/Skript-steuerbar ohne laufende GUI.
public enum WavRenderer {

    public enum DestinationMode: Equatable, Sendable { case replace, createNew }

    /// Gemeinsame Obergrenze fuer CLI-Wiedergabe und WAV-Export. Eine Stunde ist
    /// fuer SID-Analyse grosszuegig, verhindert aber versehentliche Mehrstunden-
    /// Jobs durch Tippfehler oder untrusted CLI-Argumente.
    public static let maximumDurationSeconds = 3600.0
    private static let framesPerBlock = 4096

    public enum RenderError: Error, LocalizedError {
        case invalidDuration
        case invalidSampleRate
        case invalidFadeOut
        case invalidStart
        case invalidMix
        case fileTooLarge
        case cannotCreateTemporaryFile
        public var errorDescription: String? {
            switch self {
            case .invalidDuration: return "Ungültige Dauer für den WAV-Export."
            case .invalidSampleRate: return "Ungültige Sample-Rate für den WAV-Export."
            case .invalidFadeOut: return "Ungültiger Fadeout für den WAV-Export."
            case .invalidStart: return "Ungültige Startposition für den WAV-Export."
            case .invalidMix: return "Ungültige Stimmenauswahl für den WAV-Export."
            case .fileTooLarge: return "Die WAV-Datei überschreitet die Größenbegrenzung des RIFF-Formats."
            case .cannotCreateTemporaryFile: return "Temporäre WAV-Datei konnte nicht angelegt werden."
            }
        }
    }

    /// Rechnet eine Dauer kontrolliert in Frames um. Diese Routine wird auch
    /// vom CLI-Wiedergabepfad genutzt, damit dort kein Double-zu-Int-Trap moeglich
    /// ist und beide Ausgabepfade dieselbe fachliche Obergrenze haben.
    public static func frameCount(seconds: Double, sampleRate: Double) throws -> Int {
        guard seconds.isFinite,
              seconds > 0,
              seconds <= maximumDurationSeconds else {
            throw RenderError.invalidDuration
        }
        guard sampleRate.isFinite,
              sampleRate > 0,
              sampleRate.rounded(.down) == sampleRate,
              sampleRate <= Double(UInt32.max) else {
            throw RenderError.invalidSampleRate
        }
        let frames = seconds * sampleRate
        guard frames.isFinite, frames >= 1, frames <= Double(Int.max) else {
            throw RenderError.invalidDuration
        }
        return Int(frames.rounded(.down))
    }

    // Rendert `seconds` Sekunden des Subtunes in eine WAV-Datei bei `url`.
    // modelOverride: nil = Auto (Datei-Praeferenz), 6581/8580 erzwingen das Modell.
    public static func render(sidFile: SidFileData,
                              subtune: Int = 0,
                              seconds: Double,
                              sampleRate: Double = 44100.0,
                              modelOverride: Int? = nil,
                              clockMode: SidClockMode = .auto,
                              fadeOutSeconds: Double = 0,
                              startSeconds: Double = 0,
                              mutedChannels: [Bool] = Array(repeating: false, count: 9),
                              filterEnabled: Bool = true,
                              destinationMode: DestinationMode = .replace,
                              progress: @Sendable (Int, Int) -> Void = { _, _ in },
                              to url: URL) throws {
        guard fadeOutSeconds.isFinite, (0...30).contains(fadeOutSeconds) else { throw RenderError.invalidFadeOut }
        guard startSeconds.isFinite, (0...ViciousProcessor.maximumSeekSeconds).contains(startSeconds) else { throw RenderError.invalidStart }
        guard mutedChannels.count == 9 else { throw RenderError.invalidMix }
        let totalFrames = try frameCount(seconds: seconds, sampleRate: sampleRate)
        let channels = sidFile.secondSidAddress != 0 || sidFile.thirdSidAddress != 0 ? 2 : 1
        guard sampleRate * Double(channels * MemoryLayout<Int16>.size) <= Double(UInt32.max) else {
            throw RenderError.invalidSampleRate
        }
        let (sampleCount, sampleOverflow) = totalFrames.multipliedReportingOverflow(by: channels)
        let (dataSize, byteOverflow) = sampleCount.multipliedReportingOverflow(by: MemoryLayout<Int16>.size)
        guard !sampleOverflow,
              !byteOverflow,
              dataSize <= Int(UInt32.max) - 36 else {
            throw RenderError.fileTooLarge
        }

        let processor = ViciousProcessor(sampleRate: sampleRate, clockMode: clockMode)
        _ = processor.loadSID(sidFile: sidFile)
        processor.setModelOverride(modelOverride.map { Double($0) })
        // Subtune sicher in den gueltigen Bereich klemmen (0-basiert).
        let sub = max(0, min(subtune, sidFile.metadata.subtunesCount - 1))
        processor.setMutedChannels(mutedChannels)
        processor.setFilterEnabled(filterEnabled)
        processor.initSubtune(sub: sub)
        processor.setVolume(vol: 1.0)
        try processor.seekCancellable(seconds: startSeconds) { try Task.checkCancellation() }
        if fadeOutSeconds > 0 { processor.setFadeEnvelope(PlaybackFadeEnvelope(songEnd: startSeconds + seconds, seconds: fadeOutSeconds)) }

        // Erst in eine eindeutige Nachbardatei streamen. Dadurch bleibt ein
        // vorhandenes Ziel bei Render-/I/O-Fehlern unangetastet; erst die fertig
        // synchronisierte Datei wird atomar an ihre Stelle gesetzt.
        let fm = FileManager.default
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".vicious-wav-\(UUID().uuidString).tmp"
        )
        guard fm.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw RenderError.cannotCreateTemporaryFile
        }

        defer { try? fm.removeItem(at: temporaryURL) }
        var handle: FileHandle?
        do {
            let opened = try FileHandle(forWritingTo: temporaryURL)
            handle = opened
            try opened.write(contentsOf: wavHeader(
                dataSize: dataSize,
                sampleRate: Int(sampleRate),
                channels: channels
            ))

            var renderedFrames = 0
            progress(0, totalFrames)
            while renderedFrames < totalFrames {
                try Task.checkCancellation()
                let blockFrames = min(framesPerBlock, totalFrames - renderedFrames)
                var pcm = [Int16](repeating: 0, count: blockFrames * channels)
                if channels == 2 {
                    for frame in 0..<blockFrames {
                        let sample = processor.playStereo()
                        pcm[frame * 2] = pcm16(sample.left)
                        pcm[frame * 2 + 1] = pcm16(sample.right)
                    }
                } else {
                    for frame in 0..<blockFrames {
                        pcm[frame] = pcm16(processor.play())
                    }
                }
                // Apple- und Linux-Zielplattformen sind little-endian; blockweise
                // bleiben Spitzenbedarf und Schreibmenge konstant klein.
                let block = pcm.withUnsafeBytes { Data($0) }
                try opened.write(contentsOf: block)
                renderedFrames += blockFrames
                progress(renderedFrames, totalFrames)
            }

            try Task.checkCancellation()
            try opened.synchronize()
            try opened.close()
            handle = nil

            try publishAtomically(temporaryURL, at: url, mode: destinationMode)
        } catch {
            try? handle?.close()
            try? fm.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Rename ersetzt ein bewusst gewähltes Ziel atomar. Batch verwendet
    /// dagegen einen Hardlink auf die fertige eigene Nachbardatei: Existiert
    /// das Ziel inzwischen, scheitert link mit EEXIST und erhält seine Bytes.
    /// Foundation replaceItemAt ist unter Linux dafür nicht zuverlässig.
    private static func publishAtomically(_ source: URL, at destination: URL, mode: DestinationMode) throws {
        let errorCode: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return EINVAL }
                let result = mode == .replace ? rename(sourcePath, destinationPath) : link(sourcePath, destinationPath)
                if result == 0 { return 0 }
                return errno
            }
        }
        guard errorCode == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errorCode),
                userInfo: [
                    NSFilePathErrorKey: destination.path,
                    NSURLErrorKey: destination
                ]
            )
        }
    }

    private static func pcm16(_ sample: Double) -> Int16 {
        Int16(max(-1.0, min(1.0, sample)) * 32767.0)
    }

    // Baut nur den 44-Byte-RIFF-Header; PCM folgt danach blockweise.
    static func wavHeader(dataSize: Int, sampleRate: Int, channels: Int = 1) -> Data {
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2

        var out = Data(capacity: 44)
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
        return out
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
