import XCTest
@testable import ViciousSIDPlayerCore

final class DSPRegressionTests: XCTestCase {
    private func sid(_ code: [UInt8], playOffset: Int? = nil, version: UInt16 = 2) throws -> SidFileData {
        var data = Data(count: version == 1 ? 0x76 : 0x7C)
        data.replaceSubrange(0..<4, with: Array("PSID".utf8))
        func put(_ value: UInt16, _ offset: Int) {
            data[offset] = UInt8(value >> 8)
            data[offset + 1] = UInt8(value & 255)
        }
        put(version, 4); put(UInt16(data.count), 6)
        put(0x1000, 8); put(0x1000, 10)
        put(UInt16(0x1000 + (playOffset ?? code.count - 1)), 12)
        put(1, 14); put(1, 16)
        if version > 1 { data[0x77] = 0x20 }
        return try SidParser.parse(data: data + Data(code))
    }

    private func processor(_ sid: SidFileData) -> ViciousProcessor {
        let processor = ViciousProcessor(sampleRate: 44100)
        _ = processor.loadSID(sidFile: sid)
        processor.initSubtune(sub: 0)
        return processor
    }

    func testBothIndirectModesWrapPointerHighByteInZeroPage() throws {
        for opcode: UInt8 in [0xA1, 0xB1] {
            // $00FF/$0000 zeigen auf $2000; $0100 ist absichtlich anders.
            let code: [UInt8] = [0xA9,0x00,0x85,0xFF, 0xA9,0x20,0x85,0x00,
                0xA9,0x30,0x8D,0x00,0x01, 0xA9,0x11,0x8D,0x00,0x20,
                0xA9,0x22,0x8D,0x00,0x30, opcode,0xFF,0x8D,0x01,0xD4,0x60]
            XCTAssertEqual(processor(try sid(code)).getChannelsData().frequencies.0, 0x1100)
        }
    }

    func testNoiseRestartReproducesFreshBeginning() throws {
        let code: [UInt8] = [0xA9,0x0F,0x8D,0x18,0xD4, 0xA9,0x00,0x8D,0x05,0xD4,
            0xA9,0xF0,0x8D,0x06,0xD4, 0xA9,0x20,0x8D,0x01,0xD4,
            0xA9,0x81,0x8D,0x04,0xD4,0x60]
        let p = processor(try sid(code))
        let beginning = (0..<4000).map { _ in p.play() }
        p.seek(seconds: 0)
        XCTAssertEqual((0..<4000).map { _ in p.play() }, beginning)
    }

    func testSeekPreservesENV3DependentCPUDecisionsAndFollowingAudio() throws {
        var code: [UInt8] = [0xA9,0x0F,0x8D,0x18,0xD4, 0xA9,0x00,0x8D,0x13,0xD4,
            0xA9,0xF0,0x8D,0x14,0xD4, 0xA9,0x11,0x8D,0x12,0xD4,
            0xA9,0x20,0x8D,0x01,0xD4,0x60]
        let playOffset = code.count
        code += [0xAD,0x1C,0xD4,0xC9,0x80,0x90,0x05,0xA9,0x50,0x8D,0x01,0xD4,0x60]
        let file = try sid(code, playOffset: playOffset)
        let played = processor(file), skipped = processor(file)
        for _ in 0..<44100 { _ = played.play() }
        skipped.seek(seconds: 1)
        XCTAssertEqual(played.getChannelsData().frequencies.0, 0x5000)
        XCTAssertEqual(skipped.getChannelsData().frequencies.0, 0x5000)
        XCTAssertEqual((0..<1000).map { _ in skipped.play() }, (0..<1000).map { _ in played.play() })
    }

    func testRestartRestoresRAMBeforeNonIdempotentInit() throws {
        let file = try sid([0xEE,0x00,0x20,0xAD,0x00,0x20,0x8D,0x01,0xD4,0x60])
        let p = processor(file)
        XCTAssertEqual(p.getChannelsData().frequencies.0, 256)
        for _ in 0..<1000 { _ = p.play() }
        p.seek(seconds: 0)
        XCTAssertEqual(p.getChannelsData().frequencies.0, 256)
        p.initSubtune(sub: 0)
        XCTAssertEqual(p.getChannelsData().frequencies.0, 256)
    }

    func testMinimalVersionOneDoesNotReadPayloadAsModelFlags() throws {
        let file = try sid([0x60], version: 1)
        XCTAssertEqual(file.binaryData, Data([0x60]))
        XCTAssertEqual(file.prefModel, 6581)
        XCTAssertEqual(try sid([0x60, 0x30, 0xEA, 0xEA, 0xEA, 0x60], version: 1).prefModel, 6581)
    }

    func testSeekNormalizationUsesOneFiniteBound() {
        XCTAssertEqual(ViciousProcessor.normalizedSeekSeconds(1500), 1200)
        XCTAssertEqual(ViciousProcessor.normalizedSeekSeconds(-1), 0)
        XCTAssertEqual(ViciousProcessor.normalizedSeekSeconds(.nan), 0)
        XCTAssertEqual(ViciousProcessor.normalizedSeekSeconds(.infinity), 0)
    }

    func testAutoNextDoesNotStartPausedOrStoppedPlaybackAtSongEnd() {
        XCTAssertFalse(PlaybackPolicy.shouldAdvance(isPlaying: false, autoNext: true, elapsed: 360, duration: 360))
        XCTAssertTrue(PlaybackPolicy.shouldAdvance(isPlaying: true, autoNext: true, elapsed: 360, duration: 360))
        XCTAssertFalse(PlaybackPolicy.shouldAdvance(isPlaying: true, autoNext: false, elapsed: 360, duration: 360))
    }

    func testInitialScanRespectsExplicitSelectionAndStop() {
        XCTAssertTrue(PlaybackPolicy.shouldStartAfterScan(requested: true, suppressed: false, currentTrackIndex: -1, pendingTrackLoaded: false))
        XCTAssertFalse(PlaybackPolicy.shouldStartAfterScan(requested: true, suppressed: false, currentTrackIndex: 4, pendingTrackLoaded: false))
        XCTAssertFalse(PlaybackPolicy.shouldStartAfterScan(requested: true, suppressed: true, currentTrackIndex: -1, pendingTrackLoaded: false))
    }
}
