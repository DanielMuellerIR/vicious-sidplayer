import Foundation
#if canImport(AudioToolbox)
import AudioToolbox
#endif

public enum AudioExportFormat: String, CaseIterable, Identifiable, Sendable {
    case wav, m4a, flac
    public var id: String { rawValue }
    public var displayName: String { self == .m4a ? "M4A (AAC)" : rawValue.uppercased() }
    public var minimumFrames: Int { self == .flac ? 192 : 1 }
    public var description: String {
        switch self {
        case .wav: return NSLocalizedString("Unkomprimiert · 44,1 kHz · 16 Bit", comment: "")
        case .m4a: return NSLocalizedString("Verlustbehaftet · 44,1 kHz · kleinere Dateien", comment: "")
        case .flac: return NSLocalizedString("Verlustfrei · 44,1 kHz · 16 Bit", comment: "")
        }
    }
    public var isAvailable: Bool {
        if self == .wav { return true }
#if canImport(AudioToolbox)
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size) == noErr,
              size > 0, size <= 65536, Int(size) % MemoryLayout<AudioFormatID>.size == 0 else { return false }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        let status = ids.withUnsafeMutableBytes { AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, $0.baseAddress!) }
        return status == noErr && ids.contains(self == .flac ? kAudioFormatFLAC : kAudioFormatMPEG4AAC)
#else
        return false
#endif
    }
}

public enum AACExportQuality: Int, CaseIterable, Identifiable, Sendable {
    case compact = 128000, standard = 192000, high = 256000
    public var id: Int { rawValue }
    public var displayName: String { "\(rawValue / 1000) kbit/s" }
}

struct AudioExportMetadata: Sendable {
    let title: String
    let artist: String
    let album: String
    let comment: String
    let track: Int
    let trackCount: Int

    init(sid: SidFileData, source: URL, subtune: Int) {
        let name = sid.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        album = name.isEmpty ? source.deletingPathExtension().lastPathComponent : name
        title = sid.subtuneAmount > 1 ? "\(album) · Subtune \(subtune + 1)" : album
        artist = sid.metadata.author
        track = subtune + 1; trackCount = sid.subtuneAmount
        comment = ["Subtune \(track)/\(trackCount)", sid.metadata.info].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var flacComments: [String] {
        ["TITLE=\(title)", "ARTIST=\(artist)", "ALBUM=\(album)", "TRACKNUMBER=\(track)",
         "TRACKTOTAL=\(trackCount)", "COMMENT=\(comment)"]
    }
}
