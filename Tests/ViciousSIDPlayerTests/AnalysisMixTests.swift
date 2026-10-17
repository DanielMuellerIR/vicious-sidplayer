import XCTest
@testable import ViciousSIDPlayerCore

final class AnalysisMixTests: XCTestCase {
    func testSolosUniteWithoutOverwritingChannelOrChipMutes() {
        var mix = AnalysisMix()
        mix.toggleChannelMuted(1)
        mix.toggleSolo(0); mix.toggleSolo(4)
        XCTAssertEqual(mix.effectiveMuted(activeChips: [0, 1]), [false, true, true, true, false, true, true, true, true])
        mix.toggleChipMuted(1)
        XCTAssertTrue(mix.effectiveMuted(activeChips: [0, 1])[4])
        mix.clearSolos()
        XCTAssertEqual(mix.channelMuted, [false, true, false, false, false, false, false, false, false])
        XCTAssertTrue(mix.chipMuted[1])
        mix.toggleChipMuted(1)
        XCTAssertFalse(mix.effectiveMuted(activeChips: [0, 1])[4])
    }

    func testInvisibleSolosAndSparseChipsUseActualActiveSlots() {
        var mix = AnalysisMix()
        mix.toggleSolo(7)
        XCTAssertEqual(Array(mix.effectiveMuted(activeChips: [0]).prefix(3)), [false, false, false])
        XCTAssertEqual(mix.effectiveMuted(activeChips: [0, 2]), [true, true, true, true, true, true, true, false, true])
        mix.toggleChannelMuted(7)
        XCTAssertTrue(mix.effectiveMuted(activeChips: [0, 2]).allSatisfy { $0 })
    }

    func testLegacyVoiceMuteIsGlobalAndInvalidIndicesDoNotChangeState() {
        var mix = AnalysisMix()
        mix.setVoiceMuted(2, muted: true)
        XCTAssertEqual(mix.channelMuted, [false, false, true, false, false, true, false, false, true])
        let original = mix
        for index in [-1, 9, Int.max] { mix.toggleChannelMuted(index); mix.toggleSolo(index) }
        for index in [-1, 3, Int.max] { mix.toggleChipMuted(index); mix.setVoiceMuted(index, muted: false) }
        XCTAssertEqual(mix, original)
    }

    private func syntheticSID(chips: Int, filtered: Bool = false) throws -> SidFileData {
        var code: [UInt8] = []
        func store(_ value: UInt8, _ address: Int) {
            code += [0xA9, value, 0x8D, UInt8(address & 255), UInt8(address >> 8)]
        }
        for chip in 0..<chips {
            let base = 0xD400 + chip * 0x20
            store(filtered ? 0x1F : 0x0F, base + 0x18)
            if filtered { store(0xF7, base + 0x17); store(0x20, base + 0x16) }
            for voice in 0..<3 {
                let address = base + voice * 7
                store(UInt8(37 + voice), address)
                store(UInt8(0x10 + (chip * 3 + voice) * 3), address + 1)
                store(0, address + 5); store(0xF0, address + 6); store(0x21, address + 4)
            }
        }
        code.append(0x60)
        var data = Data(count: 0x7C)
        data.replaceSubrange(0..<4, with: Array("PSID".utf8))
        func put(_ value: Int, _ offset: Int) { data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255) }
        put(chips + 1, 4); put(0x7C, 6); put(0x1000, 8); put(0x1000, 10)
        put(0x1000 + code.count - 1, 12); put(1, 14); put(1, 16); put(0x194, 0x76)
        if chips > 1 { data[0x7A] = 0x42 }
        if chips > 2 { data[0x7B] = 0x44 }
        return try SidParser.parse(data: data + Data(code))
    }

    private func processor(_ file: SidFileData) -> ViciousProcessor {
        let p = ViciousProcessor(sampleRate: 44100)
        _ = p.loadSID(sidFile: file); p.initSubtune(sub: 0)
        return p
    }

    func testIndependentChannelMuteRemovesOnlyItsStereoContributionAndUnmuteKeepsState() throws {
        for chips in [2, 3] {
            let file = try syntheticSID(chips: chips)
            let full = processor(file), muted = processor(file), isolated = processor(file)
            muted.setChannelMuted(channel: 3, muted: true)
            var mask = [Bool](repeating: true, count: 9); mask[3] = false
            XCTAssertTrue(isolated.setMutedChannels(mask))
            for _ in 0..<2048 { _ = full.playStereo(); _ = muted.playStereo(); _ = isolated.playStereo() }
            var peak = 0.0
            for _ in 0..<512 {
                let a = full.playStereo(), b = muted.playStereo(), c = isolated.playStereo()
                peak = max(peak, abs(c.left), abs(c.right))
                XCTAssertEqual(a.left - b.left, c.left, accuracy: 1e-12)
                XCTAssertEqual(a.right - b.right, c.right, accuracy: 1e-12)
            }
            XCTAssertGreaterThan(peak, 0.001)
            XCTAssertFalse(muted.setMutedChannels([false]))
            muted.setChannelMuted(channel: 3, muted: false)
            for _ in 0..<512 {
                let a = full.playStereo(), b = muted.playStereo()
                XCTAssertEqual(a.left, b.left); XCTAssertEqual(a.right, b.right)
            }
            XCTAssertEqual(full.getChannelsData().playtime, muted.getChannelsData().playtime)
        }
    }

    func testAllChipVisualsKeepTheirOwnRegistersAndTheFirstChipBufferAPI() throws {
        let p = processor(try syntheticSID(chips: 3))
        for _ in 0..<2048 { _ = p.playStereo() }
        let visuals = p.getChannelsData(), buffer = RealtimeVisualsBuffer()
        buffer.write(visuals)
        for chip in 0..<3 {
            let data = buffer.readVisuals().chip(chip)
            XCTAssertEqual(data.frequencies.0, 37 + (0x10 + chip * 9) * 256)
            XCTAssertGreaterThan(data.envelopes.0, 0)
            XCTAssertEqual(data.gates.2, 1)
        }
        XCTAssertEqual(buffer.read().frequencies.0, visuals.frequencies.0)
        buffer.updatePlaytime(42.125)
        XCTAssertEqual(buffer.read().playtime, 42.125)
        XCTAssertEqual(buffer.readVisuals().chip(2).frequencies.0, visuals.chip(2).frequencies.0)
        XCTAssertEqual(visuals.chip(-1).frequencies.0, 0)
        XCTAssertEqual(processor(try syntheticSID(chips: 1)).getChannelsData().chip(1).frequencies.0, 0)
    }

    #if canImport(AVFoundation)
    func testSeekWorkerKeepsTheFullFilteredNineChannelMask() throws {
        let file = try syntheticSID(chips: 3, filtered: true)
        var mix = AnalysisMix(); mix.toggleSolo(4)
        let mask = mix.effectiveMuted(activeChips: [0, 1, 2])
        for model in [6581, 8580] {
            let continuous = processor(file)
            continuous.setModelOverride(Double(model)); continuous.setMutedChannels(mask)
            continuous.seek(seconds: 0.2)
            let prepared = try ViciousCoordinator.prepareSeekProcessor(sid: file, subtune: 0, sampleRate: 44100,
                model: model, voiceMuted: mask, seconds: 0.2)
            var peak = 0.0
            for _ in 0..<256 {
                let a = continuous.playStereo(), b = prepared.playStereo()
                peak = max(peak, abs(a.left), abs(a.right))
                XCTAssertEqual(a.left, b.left); XCTAssertEqual(a.right, b.right)
            }
            XCTAssertGreaterThan(peak, 0.001)
        }
    }

    @MainActor
    func testCoordinatorPreservesRequestedMutesAcrossChipChangesAndEngineRebuild() throws {
        let c = ViciousCoordinator()
        c.setSid(try syntheticSID(chips: 3))
        c.toggleChannelSolo(8); c.toggleChannelMuted(1); c.toggleChipMuted(1)
        let requested = c.analysisMix
        XCTAssertFalse(c.effectiveChannelMuted[8])
        XCTAssertEqual(c.activeSIDChips, [0, 1, 2])
        c.setModelOverride(8580)
        XCTAssertEqual(c.modelForChip(0), 8580); XCTAssertEqual(c.modelForChip(2), 8580)
        c.setModelOverride(nil)
        XCTAssertEqual(c.modelForChip(0), 6581); XCTAssertEqual(c.modelForChip(1), 8580)
        c.setSid(try syntheticSID(chips: 1))
        XCTAssertEqual(c.analysisMix, requested)
        XCTAssertEqual(Array(c.effectiveChannelMuted.prefix(3)), [false, true, false])
        c.rebuildAudioEngine()
        XCTAssertEqual(c.analysisMix, requested)
        XCTAssertFalse(c.isPlaying)
    }
    #endif
}
