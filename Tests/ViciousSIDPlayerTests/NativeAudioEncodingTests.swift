import XCTest
@testable import ViciousSIDPlayerCore
#if canImport(AVFoundation)
import AVFoundation
#endif

final class NativeAudioEncodingTests: XCTestCase {
    func testNamesUseTheSelectedExtensionWithoutCollidingAcrossFormats() {
        XCTAssertEqual(AudioExportFileNames.names(for: ["Tune", "tune"], existing: ["TUNE.FLAC", "Tune.wav"], format: .flac),
            ["Tune (2).flac", "tune (3).flac"])
        XCTAssertEqual(AudioExportFileNames.names(for: ["Tune"], existing: ["Tune.wav"], format: .m4a), ["Tune.m4a"])
        XCTAssertTrue(AudioExportFormat.wav.isAvailable)
#if !canImport(AVFoundation)
        XCTAssertFalse(AudioExportFormat.flac.isAvailable)
        XCTAssertFalse(AudioExportFormat.m4a.isAvailable)
#endif
    }

    func testFLACCommentsPreserveOtherBlocksAndAllAudioBytes() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.flac"), output = root.appendingPathComponent("tagged.flac")
        let audio = Data([0xff, 0xf8, 0, 7, 1, 2, 3])
        let stream = Data(repeating: 0, count: 34), application = Data("TESTdata".utf8)
        var bytes = Data("fLaC".utf8)
        bytes.append(Data([0, 0, 0, 34])); bytes.append(stream)
        bytes.append(Data([2, 0, 0, 8])); bytes.append(application)
        bytes.append(Data([132, 0, 0, 3])); bytes.append(Data([1, 2, 3])); bytes.append(audio)
        try bytes.write(to: source)
        let comments = ["TITLE=Grüße Ω 🎶", "ARTIST=Test", "TRACKNUMBER=2"]
        try FLACMetadataWriter.write(comments, source: source, to: output)
        let result = try Data(contentsOf: output)
        XCTAssertEqual(result.prefix(54), bytes.prefix(54))
        XCTAssertEqual(result.suffix(audio.count), audio)
        XCTAssertEqual(result[54], 132)
        let payload = Data(result.dropFirst(58).dropLast(audio.count))
        func number(_ offset: Int) -> Int { (0..<4).reduce(0) { $0 | Int(payload[offset + $1]) << (8 * $1) } }
        var offset = 4 + number(0)
        XCTAssertEqual(number(offset), comments.count); offset += 4
        var recovered: [String] = []
        for _ in comments { let count = number(offset); offset += 4
            recovered.append(String(decoding: payload[offset..<(offset + count)], as: UTF8.self)); offset += count }
        XCTAssertEqual(recovered, comments)
        XCTAssertEqual(offset, payload.count)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testFLACMetadataRejectsTruncationAndInvalidFirstBlock() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for (index, bytes) in [Data("fLaC".utf8) + Data([128, 0, 0, 34]) + Data(repeating: 0, count: 33),
            Data("fLaC".utf8) + Data([129, 0, 0, 0])].enumerated() {
            let source = root.appendingPathComponent("bad\(index).flac"), output = root.appendingPathComponent("bad\(index)-tagged.flac")
            try bytes.write(to: source)
            XCTAssertThrowsError(try FLACMetadataWriter.write([], source: source, to: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

#if canImport(AVFoundation)
    func testNativeFLACKeepsShortFilesBlockBoundariesAndStereoPCMExact() throws {
        try XCTSkipUnless(AudioExportFormat.flac.isAvailable)
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        for channels in [1, 2] {
            for frames in [192, 4410, 4607, 4608, 4609, 44100] {
                let pcm = try makePCM(in: root, channels: channels, frames: frames)
                let output = root.appendingPathComponent("\(channels)-\(frames).flac")
                try NativeAudioEncoder.encode(pcm: pcm.url, to: output, format: .flac, quality: .standard,
                    channels: channels, frames: frames, progress: { _ in })
                let decoded = try AVAudioFile(forReading: output, commonFormat: .pcmFormatInt16, interleaved: true)
                XCTAssertEqual(decoded.length, Int64(frames))
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
                try decoded.read(into: buffer)
                XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(frames))
                let actual = buffer.audioBufferList.pointee.mBuffers
                XCTAssertEqual(Data(bytes: try XCTUnwrap(actual.mData), count: Int(actual.mDataByteSize)), pcm.bytes)
            }
        }
    }

    func testNativeAACQualitiesAndMetadataKeepPresentationDurationAndChannels() async throws {
        try XCTSkipUnless(AudioExportFormat.m4a.isAvailable)
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let sid = try SidParser.parse(data: metadataSID())
        let metadata = AudioExportMetadata(sid: sid, source: root.appendingPathComponent("Source.sid"), subtune: 1)
        for channels in [1, 2] {
            for quality in AACExportQuality.allCases {
              for frames in [1, 4410, 59346] {
                let pcm = try makePCM(in: root, channels: channels, frames: frames)
                let encoded = root.appendingPathComponent("\(channels)-\(quality.rawValue)-\(frames).m4a")
                let tagged = root.appendingPathComponent("tagged-\(channels)-\(quality.rawValue)-\(frames).m4a")
                try NativeAudioEncoder.encode(pcm: pcm.url, to: encoded, format: .m4a, quality: quality,
                    channels: channels, frames: frames, progress: { _ in })
                try await NativeAudioEncoder.addMetadata(metadata, source: encoded, to: tagged, format: .m4a, channels: channels, frames: frames)
                try NativeAudioEncoder.validateM4A(tagged, channels: channels, frames: frames)
                XCTAssertThrowsError(try NativeAudioEncoder.validateM4A(tagged, channels: channels, frames: frames + 1))
                let asset = AVURLAsset(url: tagged), tags = try await asset.load(.metadata)
                let title = AVMetadataItem.metadataItems(from: tags, filteredByIdentifier: .commonIdentifierTitle).first
                let titleValue = try await title?.load(.stringValue)
                XCTAssertEqual(titleValue, "Metadata Tune · Subtune 2")
                let comment = AVMetadataItem.metadataItems(from: tags, filteredByIdentifier: .iTunesMetadataUserComment).first
                let commentValue = try await comment?.load(.stringValue)
                XCTAssertEqual(commentValue, "Subtune 2/3 · 1987 Example")
                let duration = try await asset.load(.duration)
                XCTAssertEqual(duration.seconds, Double(frames) / 44100, accuracy: 1.0 / 44100)
              }
            }
        }
    }

    private func makePCM(in folder: URL, channels: Int, frames: Int) throws -> (url: URL, bytes: Data) {
        let samples = (0..<(frames * channels)).map { index in
            Int16(sin(Double(index / channels) * 2 * .pi * (index % channels == 0 ? 440 : 660) / 44100) * 0.2 * 32767)
        }
        let bytes = samples.withUnsafeBytes { Data($0) }
        let url = folder.appendingPathComponent(UUID().uuidString + ".wav")
        try (WavRenderer.wavHeader(dataSize: bytes.count, sampleRate: 44100, channels: channels) + bytes).write(to: url)
        return (url, bytes)
    }

    private func metadataSID() -> Data {
        var data = Data(repeating: 0, count: 0x7d)
        data.replaceSubrange(0..<4, with: "PSID".utf8)
        data[5] = 2; data[7] = 0x7c; data[8] = 0x10; data[10] = 0x10
        data[12] = 0x10; data[15] = 3; data[17] = 1
        for (offset, text) in [(0x16, "Metadata Tune"), (0x36, "Example Author"), (0x56, "1987 Example")] {
            data.replaceSubrange(offset..<(offset + text.utf8.count), with: text.utf8)
        }
        data[0x7c] = 0x60
        return data
    }
#endif

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
