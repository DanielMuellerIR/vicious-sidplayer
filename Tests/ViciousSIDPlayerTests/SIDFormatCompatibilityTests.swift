import XCTest
@testable import ViciousSIDPlayerCore

final class SIDFormatCompatibilityTests: XCTestCase {
    private func setWord(_ value: Int, _ offset: Int, _ data: inout Data) {
        data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255)
    }
    private func fixture(version: Int = 2, songs: Int = 1) -> Data {
        var data = Data(count: version == 1 ? 0x76 : 0x7C)
        data.replaceSubrange(0..<4, with: Array("PSID".utf8))
        func put(_ value: Int, _ offset: Int) {
            data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255)
        }
        put(version, 4); put(data.count, 6); put(0x1000, 8)
        put(0x1000, 10); put(0x1000, 12); put(songs, 14); put(1, 16)
        if version >= 2 { put(0x14, 0x76) }
        data.append(0x60)
        return data
    }

    func testWindows1252HeaderTextAndDataSlices() throws {
        var data = fixture()
        let title: [UInt8] = [0x80, 32, 0x93, 83, 73, 68, 0x94, 32, 0x97, 32, 0x8C]
        data.replaceSubrange(0x16..<(0x16 + title.count), with: title)
        XCTAssertEqual(try SidParser.parse(data: data).metadata.title, "€ “SID” — Œ")
        let wrapped = Data(repeating: 0xFF, count: 17) + data
        XCTAssertEqual(try SidParser.parse(data: wrapped.dropFirst(17)).metadata.title, "€ “SID” — Œ")
    }

    func testVersion5SharedMetadataUsesTheWholeArea() throws {
        var data = fixture(version: 5)
        let title = "An extended title longer than thirty-two bytes"
        let fields = Array((title + "\0Composer\0Released in 2026").utf8)
        data.replaceSubrange(0x16..<(0x16 + fields.count), with: fields)
        let sid = try SidParser.parse(data: data)
        XCTAssertEqual(sid.metadata.title, title)
        XCTAssertEqual(sid.metadata.author, "Composer")
        XCTAssertEqual(sid.metadata.info, "Released in 2026")
        XCTAssertEqual(sid.binaryData, Data([0x60]))
        XCTAssertEqual(try LibraryMetadata(data: data).released, "Released in 2026")
    }

    func testVersion5FallsBackToThreeFullWidthFields() throws {
        var data = fixture(version: 5)
        let title = String(repeating: "T", count: 32)
        data.replaceSubrange(0x16..<0x36, with: Array(title.utf8))
        data.replaceSubrange(0x36..<0x3E, with: Array("Composer".utf8))
        data.replaceSubrange(0x56..<0x5A, with: Array("2026".utf8))
        let metadata = try SidParser.parse(data: data).metadata
        XCTAssertEqual(metadata.title, title); XCTAssertEqual(metadata.author, "Composer"); XCTAssertEqual(metadata.info, "2026")
        data[0x16] = 0x81
        XCTAssertTrue(try SidParser.parse(data: data).metadata.title.hasPrefix("�"))
    }

    func testBlankDisplayedTitleDoesNotShiftValidVariableAuthorAndRelease() throws {
        var data = fixture(version: 5)
        let fields = Array("   \0Composer\0Released in 2026".utf8)
        data.replaceSubrange(0x16..<(0x16 + fields.count), with: fields)
        let sid = try SidParser.parse(data: data)
        XCTAssertEqual(sid.metadata.author, "Composer")
        XCTAssertEqual(sid.metadata.info, "Released in 2026")
        XCTAssertNil(try LibraryMetadata(data: data).title)
    }

    func testVersion5AddressConfigurationsAndCommonModel() throws {
        let expected: [[UInt32]] = [[0xD420, 0xD440], [0xD440, 0xD480], [0xD480, 0xD500],
            [0xD500, 0xD600], [0xD420, 0xD480], [0xD420, 0xD500], [0xD500, 0xDE00]]
        for configuration in 0...6 {
            var data = fixture(version: 5); data[0x7A] = UInt8(configuration * 16 + 3)
            setWord(0x3D4, 0x76, &data)
            let sid = try SidParser.parse(data: data)
            XCTAssertEqual([sid.secondSidAddress, sid.thirdSidAddress], expected[configuration])
            XCTAssertEqual(sid.prefModel, 6581); XCTAssertEqual(sid.prefModel2, 0); XCTAssertEqual(sid.prefModel3, 0)
            XCTAssertEqual(try LibraryMetadata(data: data).chipModels, [.mos6581, .mos6581, .mos6581])
        }
        for (configuration, start, second, third) in [(0, 0x7E, 0xD7E0, 0xDE00), (6, 0x50, 0xD500, 0xD600),
                                                     (4, 0x42, 0xD420, 0xD440), (0, 0x43, 0xD420, 0xD440)] {
            var data = fixture(version: 5); data[0x7A] = UInt8(configuration * 16 + 3); data[0x7B] = UInt8(start)
            let sid = try SidParser.parse(data: data)
            XCTAssertEqual(sid.secondSidAddress, UInt32(second)); XCTAssertEqual(sid.thirdSidAddress, UInt32(third))
        }
        var sparse = fixture(version: 4); sparse[0x7A] = 0x43; sparse[0x7B] = 0xE0
        let sid = try SidParser.parse(data: sparse)
        XCTAssertEqual(sid.secondSidAddress, 0); XCTAssertEqual(sid.thirdSidAddress, 0xDE00)
    }

    func testEmbeddedLengthsAreMetadataAndNeverLoadedIntoRAM() throws {
        var data = fixture(version: 5, songs: 2); setWord(0x414, 0x76, &data)
        data.append(contentsOf: [0x02, 0x34, 0x05, 0x54, 0, 0, 0, 0])
        let sid = try SidParser.parse(data: data)
        XCTAssertEqual(sid.embeddedSongLengths!, [154.554, 0]); XCTAssertEqual(sid.binaryData, Data([0x60]))
        let wrapped = Data(repeating: 0, count: 9) + data
        XCTAssertEqual(try SidParser.parse(data: wrapped.dropFirst(9)).embeddedSongLengths, sid.embeddedSongLengths)
        var readsTrailer = fixture(version: 5); setWord(0x414, 0x76, &readsTrailer)
        readsTrailer.removeLast(); readsTrailer.append(contentsOf: [0xAD, 0x07, 0x10, 0x8D, 0, 0xD4, 0x60])
        readsTrailer.append(contentsOf: [0x02, 0x34, 0x05, 0x54])
        let processor = ViciousProcessor(sampleRate: 44100)
        _ = processor.loadSID(sidFile: try SidParser.parse(data: readsTrailer)); processor.initSubtune(sub: 0)
        XCTAssertEqual(processor.getChannelsData().frequencies.0, 0)
        for tail: [UInt8] in [[0, 0x60, 0, 0], [0x0A, 0, 0, 0], [0, 0, 0x10, 0], [0, 0, 0]] {
            var invalid = fixture(version: 5); setWord(0x414, 0x76, &invalid); invalid.append(contentsOf: tail)
            XCTAssertThrowsError(try SidParser.parse(data: invalid)) { error in
                XCTAssertEqual(error as? SidParser.ParserError, .invalidSongLengths)
            }
        }
    }

    func testAllVersion5LayoutsRenderLikeEquivalentVersion4Addresses() throws {
        let layouts = [[0xD400, 0xD420, 0xD440], [0xD400, 0xD440, 0xD480], [0xD400, 0xD480, 0xD500],
            [0xD400, 0xD500, 0xD600], [0xD400, 0xD420, 0xD480], [0xD400, 0xD420, 0xD500], [0xD400, 0xD500, 0xDE00]]
        for (layout, addresses) in layouts.enumerated() {
            for model in [6581, 8580] {
                var code: [UInt8] = []
                func store(_ value: UInt8, _ address: Int) { code += [0xA9, value, 0x8D, UInt8(address & 255), UInt8(address >> 8)] }
                for (chip, base) in addresses.enumerated() {
                    store(UInt8(0x37 + chip), base); store(UInt8(0x10 * (chip + 1)), base + 1)
                    store(0, base + 5); store(0xF0, base + 6); store(0x21, base + 4); store(15, base + 24)
                }
                code.append(0x60)
                var current = fixture(version: 5), legacy = fixture(version: 4)
                for version in [4, 5] {
                    var data = version == 5 ? current : legacy
                    setWord(0x1000 + code.count, 12, &data)
                    setWord((model == 6581 ? 0x14 : 0x24) | (version == 5 ? 0x3C0 : 0), 0x76, &data)
                    data[0x7A] = version == 5 ? UInt8(layout * 16 + 3) : UInt8((addresses[1] - 0xD000) / 16)
                    data[0x7B] = version == 5 ? 0 : UInt8((addresses[2] - 0xD000) / 16)
                    data.removeLast(); data.append(contentsOf: code + [0x60])
                    if version == 5 { current = data } else { legacy = data }
                }
                func processor(_ data: Data) throws -> ViciousProcessor {
                    let p = ViciousProcessor(sampleRate: 44100)
                    _ = p.loadSID(sidFile: try SidParser.parse(data: data)); p.initSubtune(sub: 0); return p
                }
                let actual = try processor(current), expected = try processor(legacy), visuals = actual.getChannelsData()
                XCTAssertEqual((0..<3).map { visuals.chip($0).frequencies.0 }, [0x1037, 0x2038, 0x3039])
                var samples: [Double] = [], reference: [Double] = []
                for _ in 0..<1024 {
                    let a = actual.playStereo(), b = expected.playStereo()
                    samples += [a.left, a.right]; reference += [b.left, b.right]
                }
                XCTAssertEqual(samples, reference, "Layout \(layout), Modell \(model)")
                XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.001)
            }
        }
    }

    func testUnsupportedFeaturesAndInvalidAddressLimitsHaveSpecificErrors() throws {
        for (flags, configuration, start, error): (Int, Int, Int, SidParser.ParserError) in [
            (0x14, 4, 0, .unsupportedChipCount(4)), (0x15, 0, 0, .unsupportedMUS), (0x814, 0, 0, .unsupportedOPL),
            (0x814, 2, 0xF0, .invalidSIDConfiguration), (0x14, 0x73, 0, .invalidSIDConfiguration),
            (0x14, 3, 0xFE, .invalidSIDConfiguration), (0x14, 1, 0, .invalidSIDConfiguration)
        ] {
            var data = fixture(version: 5); setWord(flags, 0x76, &data); data[0x7A] = UInt8(configuration); data[0x7B] = UInt8(start)
            XCTAssertThrowsError(try SidParser.parse(data: data)) { XCTAssertEqual($0 as? SidParser.ParserError, error) }
        }
        var duplicate = fixture(version: 4); duplicate[0x7A] = 0x42; duplicate[0x7B] = 0x42
        XCTAssertThrowsError(try SidParser.parse(data: duplicate)) { XCTAssertEqual($0 as? SidParser.ParserError, .invalidSIDConfiguration) }
    }

    func testRSIDReservedFieldsAndSimpleInstalledIRQ() throws {
        for version in [2, 5] {
            var data = fixture(version: version)
            data.replaceSubrange(0..<4, with: Array("RSID".utf8))
            setWord(0, 8, &data); setWord(0x0800, 10, &data); setWord(0, 12, &data)
            var code: [UInt8] = []
            func store(_ value: UInt8, _ address: Int) { code += [0xA9, value, 0x8D, UInt8(address & 255), UInt8(address >> 8)] }
            store(0x30, 0x0314); store(8, 0x0315); store(15, 0xD418); code.append(0x60)
            while code.count < 0x30 { code.append(0xEA) }
            store(0x37, 0xD400); store(0x20, 0xD401); store(0x21, 0xD404); store(0, 0xD405); store(0xF0, 0xD406); code.append(0x40)
            data.replaceSubrange(0x7C..<data.count, with: [0, 8] + code)
            let sid = try SidParser.parse(data: data), processor = ViciousProcessor(sampleRate: 44100)
            XCTAssertTrue(sid.isRSID); _ = processor.loadSID(sidFile: sid); processor.initSubtune(sub: 0)
            var peak = 0.0
            for _ in 0..<2048 { let sample = processor.playStereo(); peak = max(peak, abs(sample.left), abs(sample.right)) }
            XCTAssertEqual(processor.getChannelsData().frequencies.0, 0x2037); XCTAssertGreaterThan(peak, 0.001)
            for field in [8, 12, 18] {
                var invalid = data; setWord(1, field, &invalid)
                XCTAssertThrowsError(try SidParser.parse(data: invalid)) { XCTAssertEqual($0 as? SidParser.ParserError, .invalidRSIDHeader) }
            }
            var basic = data; setWord(0x16, 0x76, &basic); setWord(0, 10, &basic)
            XCTAssertThrowsError(try SidParser.parse(data: basic)) { XCTAssertEqual($0 as? SidParser.ParserError, .unsupportedBASIC) }
        }
    }
}
