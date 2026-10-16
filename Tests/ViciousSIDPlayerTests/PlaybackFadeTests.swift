import XCTest
@testable import ViciousSIDPlayerCore

final class PlaybackFadeTests: XCTestCase {
    private let rate = 44100.0
    private func sid(stereo: Bool = false) throws -> SidFileData {
        let code: [UInt8] = [0xA9,0x0F,0x8D,0x18,0xD4, 0xA9,0x00,0x8D,0x05,0xD4,
            0xA9,0xF0,0x8D,0x06,0xD4, 0xA9,0x20,0x8D,0x01,0xD4, 0xA9,0x11,0x8D,0x04,0xD4,0x60]
        var data = Data(repeating: 0, count: 0x7C)
        data.replaceSubrange(0..<4, with: "PSID".utf8)
        func word(_ offset: Int, _ value: Int) { data[offset] = UInt8(value >> 8); data[offset+1] = UInt8(value & 255) }
        word(4, stereo ? 3 : 2); word(6, 0x7C); word(8, 0x1000); word(10, 0x1000)
        word(12, 0x1000 + code.count - 1); word(14, 1); word(16, 1); word(0x76, 0x20)
        if stereo { data[0x7A] = 0x42 }
        data.append(contentsOf: code)
        return try SidParser.parse(data: data)
    }
    private func processor(_ sid: SidFileData) -> ViciousProcessor {
        let value = ViciousProcessor(sampleRate: rate); _ = value.loadSID(sidFile: sid); value.initSubtune(sub: 0)
        return value
    }

    func testActualMonoAndStereoSamplesFollowTheFadeWhileRegistersKeepRunning() throws {
        for stereo in [false, true] {
            let file = try sid(stereo: stereo), reference = processor(file), fading = processor(file)
            fading.setFadeEnvelope(PlaybackFadeEnvelope(songEnd: 0.25, seconds: 0.1))
            var error = 0.0, peak = 0.0
            for frame in 1...13230 {
                if frame == 8000 { reference.setVolume(vol: 0.4); fading.setVolume(vol: 0.4) }
                let expectedGain = min(1, max(0, (0.25 - Double(frame) / rate) / 0.1))
                let a = reference.playStereo(), b = fading.playStereo()
                error = max(error, abs(b.left - a.left * expectedGain), abs(b.right - a.right * expectedGain))
                peak = max(peak, abs(a.left), abs(a.right))
            }
            XCTAssertGreaterThan(peak, 0.001)
            XCTAssertLessThan(error, 1e-8)
            XCTAssertEqual(fading.getChannelsData().frequencies.0, reference.getChannelsData().frequencies.0)
            XCTAssertEqual(fading.getChannelsData().envelopes.0, reference.getChannelsData().envelopes.0)
            XCTAssertEqual(fading.getChannelsData().gates.0, reference.getChannelsData().gates.0)
        }
    }

    func testSeekAndRestartKeepFadeTiedToTheActualTitlePosition() throws {
        let file = try sid(), reference = processor(file), fading = processor(file)
        fading.setFadeEnvelope(PlaybackFadeEnvelope(songEnd: 0.25, seconds: 0.1))
        for target in [0.2, 0.0, 0.16] {
            reference.seek(seconds: target); fading.seek(seconds: target)
            for _ in 0..<100 {
                let a = reference.play(), b = fading.play()
                let time = reference.getChannelsData().playtime
                let expected = min(1, max(0, (0.25 - time) / 0.1))
                XCTAssertEqual(b, a * expected, accuracy: 1e-9)
            }
        }
    }

    func testMonoAndStereoWavExportsFadeAndInvalidOptionsPreserveTheTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for stereo in [false, true] {
            let file = try sid(stereo: stereo), normal = root.appendingPathComponent("normal.wav"), faded = root.appendingPathComponent("faded.wav")
            try WavRenderer.render(sidFile: file, seconds: 0.25, to: normal)
            try WavRenderer.render(sidFile: file, seconds: 0.25, fadeOutSeconds: 0.1, to: faded)
            let a = try Data(contentsOf: normal), b = try Data(contentsOf: faded)
            XCTAssertEqual(a.count, b.count)
            let channels = stereo ? 2 : 1
            var maximumError = 0.0, nonzero = 0
            func sample(_ data: Data, _ offset: Int) -> Int16 { Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset+1]) << 8) }
            for frame in 0..<11025 {
                let gain = min(1, max(0, (0.25 - Double(frame + 1) / rate) / 0.1))
                for channel in 0..<channels {
                    let offset = 44 + (frame * channels + channel) * 2
                    let expected = Double(sample(a, offset)) * gain, actual = Double(sample(b, offset))
                    maximumError = max(maximumError, abs(actual - expected))
                    if actual != 0 { nonzero += 1 }
                }
            }
            XCTAssertGreaterThan(nonzero, 100); XCTAssertLessThanOrEqual(maximumError, 2)
            let before = try Data(contentsOf: faded)
            for invalid in [-1.0, .nan, .infinity, 31] {
                XCTAssertThrowsError(try WavRenderer.render(sidFile: file, seconds: 1, fadeOutSeconds: invalid, to: faded))
                XCTAssertEqual(try Data(contentsOf: faded), before)
            }
        }
    }
}
