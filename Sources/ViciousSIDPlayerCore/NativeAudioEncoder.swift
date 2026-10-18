import Foundation
#if canImport(AudioToolbox) && canImport(AVFoundation)
import AudioToolbox
import AVFoundation
#endif

enum NativeAudioEncoder {
    static func encode(pcm: URL, to destination: URL, format: AudioExportFormat,
                       quality: AACExportQuality, channels: Int, frames: Int,
                       progress: @Sendable (Int) -> Void) throws {
#if canImport(AudioToolbox) && canImport(AVFoundation)
        guard format != .wav, format.isAvailable else { throw AudioExportError.encoderUnavailable(format.displayName) }
        guard (1...2).contains(channels), frames >= format.minimumFrames else { throw AudioExportError.invalidEncodedFile }
        let input = try FileHandle(forReadingFrom: pcm)
        defer { try? input.close() }
        let header = try FLACMetadataWriter.readExactly(44, from: input)
        guard header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8),
              header[22] == channels, header[23] == 0, header[34] == 16,
              try input.seekToEnd() == UInt64(44 + frames * channels * 2) else { throw AudioExportError.invalidEncodedFile }
        try input.seek(toOffset: 44)
        var output = AudioStreamBasicDescription(mSampleRate: 44100,
            mFormatID: format == .flac ? kAudioFormatFLAC : kAudioFormatMPEG4AAC,
            mFormatFlags: format == .flac ? kAppleLosslessFormatFlag_16BitSourceData : 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: format == .flac ? 16 : 0, mReserved: 0)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &output))
        // Apples FLAC-Encoder liefert bei weniger als einem ganzen Startblock
        // nur einen leeren Header, ohne Fehler zu melden. Der erste Block muss
        // deshalb in die Datei passen; unter 192 Samples lehnt der Codec ihn ab.
        if format == .flac { output.mFramesPerPacket = UInt32(min(4608, frames)) }
        var reference: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(destination as CFURL,
            format == .flac ? kAudioFileFLACType : kAudioFileM4AType, &output, nil, 0, &reference))
        guard let file = reference else { throw AudioExportError.invalidEncodedFile }
        var isOpen = true
        defer { if isOpen { ExtAudioFileDispose(file) } }
        // Softwarecodierung benötigt keine Audio-Session und konkurriert beim
        // iPhone-Export nicht mit der weiterlaufenden Wiedergabe um den Codec.
        #if os(iOS)
        if format == .m4a {
            var manufacturer = kAppleSoftwareAudioCodecManufacturer
            try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_CodecManufacturer,
                UInt32(MemoryLayout.size(ofValue: manufacturer)), &manufacturer))
        }
        #endif
        var client = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &client))
        if format == .m4a {
            var converter: AudioConverterRef?
            size = UInt32(MemoryLayout<AudioConverterRef?>.size)
            try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter))
            guard let converter else { throw AudioExportError.encoderUnavailable(format.displayName) }
            var bitrate = UInt32(quality.rawValue)
            try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout.size(ofValue: bitrate)), &bitrate))
            // Nach einer Änderung am geliehenen Converter verlangt ExtAudioFile
            // den Formatabgleich, sonst kann der Container alte Angaben behalten.
            var config: CFArray?
            try withUnsafePointer(to: &config) {
                try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
                    UInt32(MemoryLayout<CFArray?>.size), $0))
            }
        }
        var encoded = 0
        while encoded < frames {
            try Task.checkCancellation()
            let count = min(16384, frames - encoded)
            var bytes = try FLACMetadataWriter.readExactly(count * channels * 2, from: input)
            try bytes.withUnsafeMutableBytes { buffer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(buffer.count), mData: buffer.baseAddress))
                try check(ExtAudioFileWrite(file, UInt32(count), &list))
            }
            encoded += count; progress(encoded)
        }
        let status = ExtAudioFileDispose(file)
        isOpen = false
        try check(status)
        try Task.checkCancellation()
        if format == .flac { try FLACMetadataWriter.validate(destination, channels: channels, frames: frames) }
#else
        throw AudioExportError.encoderUnavailable(format.displayName)
#endif
    }

    static func addMetadata(_ metadata: AudioExportMetadata, source: URL, to destination: URL,
                            format: AudioExportFormat, channels: Int, frames: Int) async throws {
        if format == .flac {
            try FLACMetadataWriter.write(metadata.flacComments, source: source, to: destination)
            try FLACMetadataWriter.validate(destination, channels: channels, frames: frames)
        } else {
#if canImport(AudioToolbox) && canImport(AVFoundation)
            try await writeM4AMetadata(metadata, source: source, to: destination, channels: channels, frames: frames)
#else
            throw AudioExportError.encoderUnavailable(format.displayName)
#endif
        }
    }

#if canImport(AudioToolbox) && canImport(AVFoundation)
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioExportError.codecFailure(status) }
    }

    @MainActor private static func writeM4AMetadata(_ metadata: AudioExportMetadata, source: URL,
                                                   to destination: URL, channels: Int, frames: Int) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioExportError.encoderUnavailable(AudioExportFormat.m4a.displayName)
        }
        session.metadata = [(AVMetadataIdentifier.commonIdentifierTitle, metadata.title),
            (.commonIdentifierArtist, metadata.artist), (.commonIdentifierAlbumName, metadata.album),
            (.iTunesMetadataUserComment, metadata.comment)].map { identifier, value in
                let item = AVMutableMetadataItem()
                item.identifier = identifier; item.value = value as NSString
                item.dataType = "com.apple.metadata.datatype.UTF-8"
                return item
            }
        let track = AVMutableMetadataItem()
        track.identifier = .iTunesMetadataTrackNumber
        track.dataType = "com.apple.metadata.datatype.raw-data"
        track.value = Data([0, 0, UInt8(metadata.track >> 8), UInt8(metadata.track & 255),
            UInt8(metadata.trackCount >> 8), UInt8(metadata.trackCount & 255), 0, 0]) as NSData
        session.metadata = (session.metadata ?? []) + [track]
        // Passthrough erhält die AAC-Pakete und ihre Priming-Angaben. Die
        // Präsentationsdauer folgt den gerenderten Samples, ohne Zweitcodierung.
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: Int64(frames), timescale: 44100))
        if #available(macOS 15.0, iOS 18.0, *) { try await session.export(to: destination, as: .m4a) }
        else { try await exportLegacy(session, to: destination) }
        try Task.checkCancellation()
        try validateM4A(destination, channels: channels, frames: frames)
    }

    static func validateM4A(_ url: URL, channels: Int, frames: Int) throws {
        var reference: AudioFileID?
        try check(AudioFileOpenURL(url as CFURL, .readPermission, 0, &reference))
        guard let file = reference else { throw AudioExportError.invalidEncodedFile }
        defer { AudioFileClose(file) }
        var table = AudioFilePacketTableInfo()
        var size = UInt32(MemoryLayout.size(ofValue: table))
        try check(AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table))
        var stream = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout.size(ofValue: stream))
        try check(AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &stream))
        // AVAsset.duration enthält im Kompatibilitätsmodus älterer SDKs auch
        // AAC-Priming und Restpadding. Die Pakettabelle trennt diese Samples
        // ausdrücklich von den gültigen Frames und prüft die Dauer ganzzahlig.
        guard table.mNumberValidFrames == Int64(frames), table.mPrimingFrames >= 0, table.mRemainderFrames >= 0,
              stream.mFormatID == kAudioFormatMPEG4AAC, stream.mChannelsPerFrame == UInt32(channels),
              stream.mSampleRate == 44100 else {
            throw AudioExportError.invalidEncodedFile
        }
    }

    @MainActor
    @available(macOS, deprecated: 15.0)
    @available(iOS, deprecated: 18.0)
    private static func exportLegacy(_ session: AVAssetExportSession, to url: URL) async throws {
        session.outputURL = url; session.outputFileType = .m4a
        let cancel: @MainActor @Sendable () -> Void = { session.cancelExport() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let finish: @MainActor @Sendable () -> Void = {
                    if session.status == .completed { continuation.resume() }
                    else if session.status == .cancelled { continuation.resume(throwing: CancellationError()) }
                    else { continuation.resume(throwing: session.error ?? AudioExportError.invalidEncodedFile) }
                }
                session.exportAsynchronously { Task { @MainActor in finish() } }
            }
        } onCancel: { Task { @MainActor in cancel() } }
    }
#endif
}
