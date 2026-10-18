import XCTest
@testable import ViciousSIDPlayerCore

final class PlaybackLoopTests: XCTestCase {
    func testLoopSuppressesRepeatAndNormalCompletionInTheSharedPolicy() {
        for mode in PlaybackRepeatMode.allCases {
            XCTAssertNil(PlaybackCompletionPolicy.action(isPlaying: true, elapsed: 20, duration: 10,
                currentSubtune: 0, subtuneCount: 3, entry: nil, autoNext: true, repeatMode: mode,
                hasExplicitEnd: true, stopAfterSubtune: true, loopEnabled: true))
        }
    }

    func testMarkersValidateAndManualSeekDisablesWithoutDeleting() {
        var loop = PlaybackLoop()
        loop.setStart(.nan, duration: 10); XCTAssertNil(loop.start)
        loop.setEnd(5, duration: 10); XCTAssertNil(loop.end)
        loop.setStart(-1, duration: 10); XCTAssertEqual(loop.start, 0)
        loop.setEnd(0.1, duration: 10); XCTAssertNil(loop.range)
        loop.setEnd(4, duration: 10); loop.setEnabled(true)
        loop.seek(to: 2); XCTAssertTrue(loop.isEnabled)
        loop.seek(to: 6); XCTAssertFalse(loop.isEnabled); XCTAssertEqual(loop.range, 0...4)
        loop.setEnabled(true); loop.constrain(to: 0.1); XCTAssertFalse(loop.isEnabled)
        loop.clear(); XCTAssertEqual(loop, PlaybackLoop())
    }

    func testPitchUsesEffectiveClockAndRejectsUnreliableWaveforms() throws {
        let pitch = try XCTUnwrap(SIDPitch.estimate(register: 7493, clock: .pal, waveform: 0x20, envelope: 1))
        XCTAssertEqual(pitch.name, "A4"); XCTAssertEqual(pitch.midiNote, 69)
        XCTAssertEqual(pitch.hertz, 440.0291004180908, accuracy: 1e-10)
        let ntsc = try XCTUnwrap(SIDPitch.estimate(register: 7493, clock: .ntsc, waveform: 0x20, envelope: 1))
        XCTAssertGreaterThan(ntsc.hertz, pitch.hertz)
        for waveform in [0, 0x80, 0x30, 0xf0] {
            XCTAssertNil(SIDPitch.estimate(register: 7493, clock: .pal, waveform: waveform, envelope: 1))
        }
        XCTAssertNil(SIDPitch.estimate(register: 0, clock: .pal, waveform: 0x20, envelope: 1))
        XCTAssertNil(SIDPitch.estimate(register: 7493, clock: .pal, waveform: 0x20, envelope: .nan))
    }

    func testLoopRestoresFilteredThreeSIDExactlyAndRetainsVolume() throws {
        let sid = try fixture()
        for clock in [SidClockMode.pal, .ntsc] {
            for model in [6581, 8580] {
                let rate = 44100.0, a = 0.2, b = 0.45
                let count = Int(b * rate) - Int(a * rate)
                let muted = [false, true, false, false, false, true, false, false, false]
                func processor() -> ViciousProcessor {
                    let p = ViciousProcessor(sampleRate: rate, clockMode: clock)
                    _ = p.loadSID(sidFile: sid); p.setModelOverride(Double(model))
                    p.setMutedChannels(muted); p.initSubtune(sub: 0); return p
                }
                let reference = processor(); reference.seek(seconds: a)
                let expected = (0..<count).map { _ in reference.playStereo() }
                let live = processor(); live.seek(seconds: b)
                let snapshot = try ViciousProcessor.prepareLoop(sid: sid, subtune: 0, sampleRate: rate,
                    range: a...b, model: model, muted: muted, clockMode: clock)
                XCTAssertTrue(live.installLoop(snapshot)); live.setVolume(vol: 0.5)
                for _ in 0..<4 {
                    for sample in expected {
                        let actual = live.playStereo()
                        XCTAssertEqual(actual.left, sample.left * 0.5)
                        XCTAssertEqual(actual.right, sample.right * 0.5)
                    }
                    XCTAssertEqual(live.getChannelsData().playtime, b, accuracy: 1e-8)
                }
                live.disableLoop(); _ = live.playStereo()
                XCTAssertGreaterThan(live.getChannelsData().playtime, b)
                live.seek(seconds: 0)
                XCTAssertTrue(live.installLoop(snapshot))
                for sample in expected.prefix(2048) {
                    let actual = live.playStereo()
                    XCTAssertEqual(actual.left, sample.left * 0.5)
                    XCTAssertEqual(actual.right, sample.right * 0.5)
                }
            }
        }
    }

    func testIncompatibleSnapshotsAreRejectedAndConfigurationChangeDisablesLoop() throws {
        let sid = try fixture(), other = try fixture(changed: true)
        XCTAssertThrowsError(try ViciousProcessor.prepareLoop(sid: sid, subtune: 0, sampleRate: 0.5, range: 0...0.25))
        XCTAssertThrowsError(try ViciousProcessor.prepareLoop(sid: sid, subtune: 0, sampleRate: 8000, range: 0...0.1))
        let snapshot = try ViciousProcessor.prepareLoop(sid: sid, subtune: 0, sampleRate: 8000, range: 0...0.25)
        let p = ViciousProcessor(sampleRate: 8000)
        _ = p.loadSID(sidFile: other); p.initSubtune(sub: 0)
        XCTAssertFalse(p.installLoop(snapshot))
        _ = p.loadSID(sidFile: sid)
        XCTAssertFalse(p.installLoop(snapshot))
        p.initSubtune(sub: 0)
        XCTAssertTrue(p.installLoop(snapshot))
        p.setChannelMuted(channel: 0, muted: true)
        for _ in 0..<4000 { _ = p.play() }
        XCTAssertEqual(p.getChannelsData().playtime, 0.5, accuracy: 1e-8)
        XCTAssertFalse(p.installLoop(snapshot))
    }

    func testSleepFadeUsesContinuousTimeAcrossShortLoops() throws {
        let sid = try fixture()
        let snapshot = try ViciousProcessor.prepareLoop(sid: sid, subtune: 0, sampleRate: 8000, range: 0...0.25)
        let p = ViciousProcessor(sampleRate: 8000)
        _ = p.loadSID(sidFile: sid); p.initSubtune(sub: 0)
        XCTAssertTrue(p.installLoop(snapshot))
        p.setFadeEnvelope(PlaybackFadeEnvelope(songEnd: 0.1, timerEnd: 1, seconds: 0.5))
        var audible = false
        for _ in 0..<7200 { let sample = p.play(); audible = audible || abs(sample) > 0.0001 }
        XCTAssertTrue(audible)
        for _ in 0..<1000 { _ = p.play() }
        for _ in 0..<100 { XCTAssertEqual(p.play(), 0) }
    }

    func testRegisterPeekIncludesActualChipBaseAndEmulatedReadbackWithoutChangingAudio() throws {
        let sid = try fixture(), p = ViciousProcessor(sampleRate: 8000), ref = ViciousProcessor(sampleRate: 8000)
        for processor in [p, ref] { _ = processor.loadSID(sidFile: sid); processor.initSubtune(sub: 0) }
        for _ in 0..<3000 {
            let visuals = p.getChannelsData()
            XCTAssertEqual(visuals.chip(2).baseAddress, 0xd440)
            XCTAssertEqual(visuals.chip(1).registers[0], 38)
            XCTAssertEqual(p.play(), ref.play())
        }
        XCTAssertFalse(SIDRegister.offsets.contains(0x19)); XCTAssertFalse(SIDRegister.offsets.contains(0x1a))
        XCTAssertEqual(SIDRegister.offsets.count, 27)
    }

    private func fixture(changed: Bool = false) throws -> SidFileData {
        var code: [UInt8] = []
        func store(_ value: UInt8, _ address: Int) { code += [0xa9, value, 0x8d, UInt8(address & 255), UInt8(address >> 8)] }
        for chip in 0..<3 {
            let base = 0xd400 + chip * 0x20
            store(0x1f, base + 0x18); store(0xf7, base + 0x17); store(0x20, base + 0x16)
            for voice in 0..<3 {
                let address = base + voice * 7
                store(UInt8(37 + chip + voice + (changed ? 1 : 0)), address)
                store(UInt8(0x10 + (chip * 3 + voice) * 3), address + 1)
                store(0, address + 5); store(0xf0, address + 6); store(0x21, address + 4)
            }
        }
        code += [0x60]
        let play = 0x1000 + code.count
        // OSC3/ENV3 beeinflussen den Kontrollfluss und den Filter: Eine bloße
        // Oszillator-Kopie ohne CPU/RAM-Stand würde diesen Test nicht bestehen.
        code += [0xad, 0x1b, 0xd4, 0x8d, 0x16, 0xd4, 0xad, 0x1c, 0xd4, 0x8d, 0x00, 0xd4, 0x60]
        var data = Data(count: 0x7c)
        data.replaceSubrange(0..<4, with: "PSID".utf8)
        func put(_ value: Int, _ offset: Int) { data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255) }
        put(4, 4); put(0x7c, 6); put(0x1000, 8); put(0x1000, 10); put(play, 12)
        put(1, 14); put(1, 16); put(0x194, 0x76); data[0x7a] = 0x42; data[0x7b] = 0x44
        return try SidParser.parse(data: data + Data(code))
    }
}
