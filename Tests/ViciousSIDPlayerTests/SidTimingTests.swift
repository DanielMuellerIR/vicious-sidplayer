import XCTest
@testable import ViciousSIDPlayerCore

final class SidTimingTests: XCTestCase {
    private func sid(flags: UInt8, cia: Bool = false, version: UInt16 = 2,
                     initCode: [UInt8] = [0x60], play: [UInt8] = [0xEE,0x00,0xD4,0x60], songs: UInt16 = 1) throws -> SidFileData {
        var data = Data(count: version == 1 ? 0x76 : 0x7C)
        data.replaceSubrange(0..<4, with: "PSID".utf8)
        func put(_ value: UInt16, at offset: Int) {
            data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255)
        }
        put(version, at: 4); put(UInt16(data.count), at: 6)
        put(0x1000, at: 8); put(0x1000, at: 10)
        put(0x1000 + UInt16(initCode.count), at: 12)
        put(songs, at: 14); put(1, at: 16)
        if cia { data[0x15] = 1 }
        if version > 1 { data[0x77] = flags | 0x20 }
        return try SidParser.parse(data: data + Data(initCode + play))
    }

    func testHeaderClockFlagsAndVersionOneFallback() throws {
        for value: UInt8 in 0...3 {
            XCTAssertEqual(try sid(flags: value << 2).clockPreference.rawValue, value)
        }
        XCTAssertEqual(try sid(flags: 0x08, version: 1).clockPreference, .unknown)
    }

    func testAutomaticVBIInvokesPlayFiftyOrSixtyTimesPerSecond() throws {
        for (flag, count): (UInt8, Int) in [(0x04, 50), (0x08, 60), (0, 50), (0x0C, 50)] {
            let p = ViciousProcessor(sampleRate: 44100)
            _ = p.loadSID(sidFile: try sid(flags: flag)); p.initSubtune(sub: 0)
            for _ in 0..<44100 { _ = p.play() }
            XCTAssertEqual(p.getChannelsData().frequencies.0, count, "clock flags: \(flag)")
        }
    }

    func testSpeedBitsRepeatOnlyForVersionOneAndPlaySIDSpecificFiles() throws {
        for (version, flags, count): (UInt16, UInt8, Int) in [(1, 4, 60), (2, 4, 50), (2, 6, 60), (3, 4, 50), (4, 4, 50), (5, 4, 50)] {
            let p = ViciousProcessor(sampleRate: 44100)
            _ = p.loadSID(sidFile: try sid(flags: flags, cia: true, version: version, songs: 33)); p.initSubtune(sub: 32)
            for _ in 0..<44100 { _ = p.play() }
            XCTAssertEqual(p.getChannelsData().frequencies.0, count, "v\(version), flags \(flags)")
        }
        let normal = try sid(flags: 4, cia: true, songs: 33), specific = try sid(flags: 6, cia: true, songs: 33)
        let loop = try ViciousProcessor.prepareLoop(sid: normal, subtune: 32, sampleRate: 44100, range: 0.2...0.45)
        let p = ViciousProcessor(sampleRate: 44100); _ = p.loadSID(sidFile: specific); p.initSubtune(sub: 32)
        XCTAssertFalse(p.installLoop(loop))
    }

    func testOverrideAndCIAUseTheSelectedMachineClock() throws {
        for mode in [SidClockMode.pal, .ntsc] {
            let p = ViciousProcessor(sampleRate: 44100, clockMode: mode)
            _ = p.loadSID(sidFile: try sid(flags: mode == .pal ? 0x08 : 0x04))
            p.initSubtune(sub: 0)
            for _ in 0..<44100 { _ = p.play() }
            XCTAssertEqual(p.getChannelsData().frequencies.0, mode == .pal ? 50 : 60)

            let cia = ViciousProcessor(sampleRate: 44100, clockMode: mode)
            _ = cia.loadSID(sidFile: try sid(flags: 0, cia: true)); cia.initSubtune(sub: 0)
            for _ in 0..<44100 { _ = cia.play() }
            XCTAssertEqual(cia.getChannelsData().frequencies.0, 60)
        }
    }

    func testRSIDStartsWithCIAInterruptTimingDespiteReservedZeroSpeedBits() throws {
        for version in [2, 5] {
            for flags in [0x14, 0x18] {
                var data = Data(count: 0x7C)
                data.replaceSubrange(0..<4, with: "RSID".utf8)
                func put(_ value: Int, _ offset: Int) { data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255) }
                put(version, 4); put(0x7C, 6); put(0x1000, 10); put(1, 14); put(1, 16); put(flags, 0x76)
                var code: [UInt8] = [0xA9,0x20,0x8D,0x14,3,0xA9,0x10,0x8D,0x15,3,0x60]
                while code.count < 0x20 { code.append(0xEA) }
                data.append(contentsOf: [0, 0x10] + code + [0xEE,0,0xD4,0x40])
                let p = ViciousProcessor(sampleRate: 44100)
                _ = p.loadSID(sidFile: try SidParser.parse(data: data)); p.initSubtune(sub: 0)
                for _ in 0..<44100 { _ = p.play() }
                XCTAssertEqual(p.getChannelsData().frequencies.0, 60, "RSID v\(version), flags \(flags)")
            }
        }
    }

    func testInitSeesVideoFlagAndCorrectDefaultCIATimer() throws {
        for (flag, timer): (UInt8, Int) in [(0x04, 0x4025), (0x08, 0x4295)] {
            let registers: [UInt8] = [0xAD,0x04,0xDC,0x8D,0x00,0xD4,
                                      0xAD,0x05,0xDC,0x8D,0x01,0xD4,0x60]
            let p = ViciousProcessor(sampleRate: 44100)
            _ = p.loadSID(sidFile: try sid(flags: flag, initCode: registers)); p.initSubtune(sub: 0)
            XCTAssertEqual(p.getChannelsData().frequencies.0, timer)
            let video: [UInt8] = [0xAD,0xA6,0x02,0x8D,0x00,0xD4,0x60]
            _ = p.loadSID(sidFile: try sid(flags: flag, initCode: video)); p.initSubtune(sub: 0)
            XCTAssertEqual(p.getChannelsData().frequencies.0, flag == 0x04 ? 1 : 0)
        }
    }

    func testCustomCIATimerWrittenByVBISubtune() throws {
        for (flag, frequency): (UInt8, Double) in [(0x04, 985248), (0x08, 1022727)] {
            let setup: [UInt8] = [0xA9,0x00,0x8D,0x04,0xDC,0xA9,0x10,0x8D,0x05,0xDC,0x60]
            let p = ViciousProcessor(sampleRate: 44100)
            _ = p.loadSID(sidFile: try sid(flags: flag, initCode: setup)); p.initSubtune(sub: 0)
            for _ in 0..<22050 { _ = p.play() }
            XCTAssertEqual(Double(p.getChannelsData().frequencies.0), frequency / 4097 / 2, accuracy: 1.5)
        }
    }

    func testCIATimerWrittenDuringPlaybackChangesTheRate() throws {
        let change: [UInt8] = [0xA9,0x00,0x8D,0x04,0xDC,0xA9,0x10,0x8D,0x05,0xDC,
                              0xEE,0x00,0xD4,0x60]
        let p = ViciousProcessor(sampleRate: 44100)
        _ = p.loadSID(sidFile: try sid(flags: 8, cia: true, play: change)); p.initSubtune(sub: 0)
        for _ in 0..<22050 { _ = p.play() }
        // Der laufende erste CIA-Zyklus endet noch mit dem 60-Hz-Startwert;
        // der neu geschriebene Latch gilt ab dem naechsten Unterlauf.
        let firstInterval = 17046.0 / 1022727
        XCTAssertEqual(Double(p.getChannelsData().frequencies.0), 1 + (0.5 - firstInterval) * 1022727 / 4097, accuracy: 1.5)
    }

    #if canImport(AVFoundation)
    @MainActor
    func testClockChangeKeepsPausedPositionAndRebuildsSeek() async throws {
        let coordinator = ViciousCoordinator()
        coordinator.setVolume(0)
        coordinator.setSid(try sid(flags: 8, initCode: tone))
        coordinator.seek(seconds: 0.2)
        coordinator.play()
        coordinator.pause()
        coordinator.setClockMode(.pal)
        for _ in 0..<200 where coordinator.isPreparingSeek {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        defer { coordinator.stop() }
        XCTAssertFalse(coordinator.isPreparingSeek)
        XCTAssertTrue(coordinator.isPaused)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(coordinator.elapsedSeconds, 0.2, accuracy: 0.05)
        XCTAssertEqual(coordinator.effectiveClock, .pal)
    }
    #endif

    private var tone: [UInt8] {
        [0xA9,0x0F,0x8D,0x18,0xD4,0xA9,0x00,0x8D,0x05,0xD4,
         0xA9,0xF0,0x8D,0x06,0xD4,0xA9,0x20,0x8D,0x01,0xD4,
         0xA9,0x11,0x8D,0x04,0xD4,0x60]
    }

    private func measuredFrequency(_ samples: [Double], rate: Double) -> Double {
        let start = Int(rate / 10)
        let crossings = (start + 1..<samples.count).filter { samples[$0 - 1] <= 0 && samples[$0] > 0 }.count
        return Double(crossings) * rate / Double(samples.count - start)
    }

    func testTonePitchAndWAVOverrideAgainstOscillatorFormula() throws {
        let file = try sid(flags: 0x08, initCode: tone, play: [0x60])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (mode, cpu): (SidClockMode, Double) in [(.auto, 1022727), (.pal, 985248)] {
            let p = ViciousProcessor(sampleRate: 44100, clockMode: mode)
            _ = p.loadSID(sidFile: file); p.initSubtune(sub: 0)
            let samples = (0..<44100).map { _ in p.play() }
            XCTAssertEqual(measuredFrequency(samples, rate: 44100), 8192 * cpu / 16777216, accuracy: 2)
            try WavRenderer.render(sidFile: file, seconds: 1, clockMode: mode, to: temporary)
            let bytes = [UInt8](try Data(contentsOf: temporary))
            let wav = stride(from: 44, to: bytes.count, by: 2).map {
                Double(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8))
            }
            XCTAssertEqual(measuredFrequency(wav, rate: 44100), 8192 * cpu / 16777216, accuracy: 2)
        }
    }

    func testNTSCSeekMatchesContinuouslyRenderedAudio() throws {
        let file = try sid(flags: 0x08, initCode: tone)
        let played = ViciousProcessor(sampleRate: 44100), sought = ViciousProcessor(sampleRate: 44100)
        for p in [played, sought] { _ = p.loadSID(sidFile: file); p.initSubtune(sub: 0) }
        for _ in 0..<44100 { _ = played.play() }
        sought.seek(seconds: 1)
        XCTAssertEqual((0..<1024).map { _ in played.play() }, (0..<1024).map { _ in sought.play() })
    }

    func testEstimatorAndCacheSeparateClockModes() throws {
        let ending: [UInt8] = [0xE6,0x02,0xA5,0x02,0xC9,0x78,0xD0,0x05,0xA9,0x00,0x8D,0x18,0xD4,0x60]
        let file = try sid(flags: 0x08, initCode: tone, play: ending)
        let ntsc = try XCTUnwrap(SongLengthEstimator.estimate(sidFile: file, subtune: 0, maxSeconds: 6))
        let pal = try XCTUnwrap(SongLengthEstimator.estimate(sidFile: file, subtune: 0, maxSeconds: 6, clockMode: .pal))
        XCTAssertEqual(pal - ntsc, 0.4, accuracy: 0.03)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SongLengthCache(fileURL: url)
        cache.store(md5: "abc", subtune: 0, seconds: 12, clockMode: .pal)
        cache.store(md5: "abc", subtune: 0, seconds: 10, clockMode: .ntsc)
        XCTAssertEqual(cache.length(md5: "abc", subtune: 0, clockMode: .pal), 12)
        XCTAssertEqual(cache.length(md5: "abc", subtune: 0, clockMode: .ntsc), 10)
        XCTAssertNil(cache.length(md5: "abc", subtune: 0))
    }
}
