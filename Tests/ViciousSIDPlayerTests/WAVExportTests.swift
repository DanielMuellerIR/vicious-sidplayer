import XCTest
@testable import ViciousSIDPlayerCore

final class WAVExportTests: XCTestCase {
    func testRendererUsesStartMixFilterFadeAndIntermediateProgress() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sid = try SidParser.parse(data: sparseSIDData(filtered: true))
        let muted = [false, false, false, false, false, false, false, true, true]
        var payloads: [Data] = []
        for filter in [false, true] {
            let url = folder.appendingPathComponent("\(filter).wav"), updates = ExportFrameLog()
            try WavRenderer.render(sidFile: sid, seconds: 0.6, sampleRate: 8000, fadeOutSeconds: 0.1,
                startSeconds: 0.2, mutedChannels: muted, filterEnabled: filter,
                progress: { frame, _ in updates.append(frame) }, to: url)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(bytes.count, 44 + 4800 * 4)
            let reference = ViciousProcessor(sampleRate: 8000)
            _ = reference.loadSID(sidFile: sid); reference.setMutedChannels(muted); reference.setFilterEnabled(filter)
            reference.initSubtune(sub: 0); reference.seek(seconds: 0.2)
            reference.setFadeEnvelope(PlaybackFadeEnvelope(songEnd: 0.8, seconds: 0.1))
            func sample(_ index: Int) -> Int16 {
                let offset = 44 + index * 2
                return Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
            }
            func pcm(_ value: Double) -> Int16 { Int16(max(-1, min(1, value)) * 32767) }
            var different = 0
            for frame in 0..<4800 {
                let expected = reference.playStereo()
                if sample(frame * 2) != pcm(expected.left) || sample(frame * 2 + 1) != pcm(expected.right) { different += 1 }
            }
            XCTAssertEqual(different, 0)
            let recorded = updates.snapshot()
            XCTAssertEqual(recorded.first, 0); XCTAssertEqual(recorded.last, 4800)
            XCTAssertEqual(recorded, recorded.sorted()); XCTAssertGreaterThan(recorded.count, 2)
            payloads.append(Data(bytes.dropFirst(44)))
        }
        XCTAssertNotEqual(payloads[0], payloads[1])
        let silence = folder.appendingPathComponent("muted.wav")
        try WavRenderer.render(sidFile: sid, seconds: 0.1, sampleRate: 8000,
            mutedChannels: Array(repeating: true, count: 9), to: silence)
        XCTAssertTrue(try Data(contentsOf: silence).dropFirst(44).allSatisfy { $0 == 0 })
    }

    func testSparseSecondSIDUsesStereoAndRetainsTheActiveChip() throws {
        let sid = try sparseSID()
        let mono = ViciousProcessor(sampleRate: 8000)
        let stereo = ViciousProcessor(sampleRate: 8000)
        for processor in [mono, stereo] {
            _ = processor.loadSID(sidFile: sid)
            processor.initSubtune(sub: 0)
        }
        var referencePeak = 0.0
        var maximumError = 0.0
        for _ in 0..<2048 {
            let reference = mono.play()
            let actual = stereo.playStereo()
            referencePeak = max(referencePeak, abs(reference))
            maximumError = max(maximumError, abs(actual.left - reference * 0.25), abs(actual.right - reference * 0.75))
        }
        XCTAssertGreaterThan(referencePeak, 0.001)
        XCTAssertLessThan(maximumError, 1e-12)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sparse.wav")
        try WavRenderer.render(sidFile: sid, seconds: 0.1, sampleRate: 8000, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data[22], 2)
        XCTAssertEqual(data.count, 44 + 800 * 4)
    }

    func testPlannerExpandsSubtunesAndUsesFullFileFingerprintForDurationPriority() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = sparseSIDData(subtunes: 3)
        let source = folder.appendingPathComponent("Three.sid")
        try bytes.write(to: source)
        let md5 = SonglengthDB.md5Hex(of: bytes)
        let cache = SongLengthCache(fileURL: folder.appendingPathComponent("cache.json"))
        cache.store(md5: md5, subtune: 1, seconds: 0.7, clockMode: .pal)
        cache.store(md5: md5, subtune: 2, seconds: -1, clockMode: .pal)
        var settings = PlaybackSettingsDocument()
        try settings.setEndTime(0.2, md5: md5, subtune: 0)
        let context = WAVExportDurationContext(resolver: SongLengthResolver(cache: cache),
            database: SonglengthDB(entries: [md5: [0.4]]), settings: settings, clockMode: .pal)
        let items = try WAVExportPlanner.prepare(sources: [WAVExportSource(url: source)], durations: context)
        XCTAssertEqual(items.map(\.subtune), [0, 1, 2])
        XCTAssertEqual(items.map(\.seconds), [0.2, 0.7, 360])
        XCTAssertEqual(items.map(\.durationSource), [.personal, .computed, .fallback])
        XCTAssertTrue(items.allSatisfy { $0.md5 == md5 && $0.channels == 2 && $0.activeChips == [0, 2] })
        XCTAssertEqual(Set(items.map(\.fileName)).count, 3)
        let database = SongLengthSelection.resolve(databaseLengths: [0.4], subtune: 0, computed: 0.7)
        XCTAssertEqual(database.source, .database)
        XCTAssertEqual(database.seconds, 0.4)
    }

    func testNamesProtectCaseUnicodeAndExistingTargets() {
        let names = WAVExportFileNames.names(for: ["Same", "same", "Café", "Cafe\u{301}", "CON.foo", "../escape/track", " . ", String(repeating: "🎶", count: 100)], existing: ["SAME.WAV"])
        XCTAssertEqual(Array(names.prefix(2)), ["Same (2).wav", "same (3).wav"])
        XCTAssertEqual(names[2], "Café.wav")
        XCTAssertTrue(names[3].hasSuffix(" (2).wav"))
        XCTAssertEqual(names[4], "_CON.foo.wav")
        XCTAssertTrue(names.allSatisfy { !$0.contains("/") && !$0.contains("\\") && !$0.hasPrefix(".") && $0.utf8.count <= 160 })
        let namesAtScale = WAVExportFileNames.names(for: Array(repeating: "Same", count: 10000))
        XCTAssertEqual(Set(namesAtScale).count, 10000)
        XCTAssertEqual(namesAtScale.last, "Same (10000).wav")
    }

    func testBatchDetectsChangedHeaderAndRetainsTheCompletedFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = try preparedPair(in: folder, seconds: 0.1)
        var changed = try Data(contentsOf: items[1].sourceURL)
        changed[0x16] = 0x54
        try changed.write(to: items[1].sourceURL)
        let result = WAVBatchExporter.run(items: items, options: WAVExportOptions(), directory: folder)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(try Data(contentsOf: result.files[0]).count, 44 + 4410 * 4)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".tmp") })
    }

    func testBatchRefusesAFileCreatedDuringRendering() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try preparedPair(in: folder, seconds: 0.2)[0]
        let destination = folder.appendingPathComponent(item.fileName)
        let foreign = Data("Created after preview".utf8)
        let result = WAVBatchExporter.run(items: [item], options: WAVExportOptions(), directory: folder) { progress in
            if progress.renderedFrames == 4096 { try! foreign.write(to: destination) }
        }
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(try Data(contentsOf: destination), foreign)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".tmp") })
    }

    func testCancellationRetainsFinishedFilesAndRemovesPartialOutput() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = try preparedPair(in: folder, seconds: 0.2)
        let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            WAVBatchExporter.run(items: items, options: WAVExportOptions(), directory: folder) { progress in
                if progress.completedFiles == 1 && progress.renderedFrames == 4096 {
                    started.signal(); resume.wait()
                }
            }
        }
        let observed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: started.wait(timeout: .now() + 10) == .success)
            }
        }
        worker.cancel(); resume.signal()
        let result = await worker.value
        XCTAssertTrue(observed)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(result.files.count, 1)
        XCTAssertNil(result.error)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".wav") }.count, 1)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    func testSliceRequiresOneSubtuneAndManualDurationCanBeReset() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = try preparedPair(in: folder, seconds: 0.2)
        XCTAssertThrowsError(try WAVExportPlanner.applyingSlice(1...1.5, to: items))
        let sliced = try WAVExportPlanner.applyingSlice(1...1.5, to: [items[0]])
        XCTAssertEqual(sliced[0].startSeconds, 1)
        XCTAssertEqual(sliced[0].seconds, 0.5)
        XCTAssertEqual(sliced[0].durationDescription, "0:00.5")
        let precise = try WAVExportPlanner.applyingDuration(1.3457142857149582, to: [items[0]])[0]
        XCTAssertEqual(precise.durationDescription, "0:01.346")
        XCTAssertEqual(precise.seconds, 1.3457142857149582)
        let reset = try WAVExportPlanner.applyingDuration(nil, to: sliced)
        XCTAssertEqual(reset[0].startSeconds, 0)
        XCTAssertEqual(reset[0].seconds, 360)
        XCTAssertFalse(reset[0].usesManualDuration)
        XCTAssertThrowsError(try WAVExportPlanner.applyingDuration(.nan, to: items))
    }

    func testCurrentMixIsResolvedForEachFilesActiveChips() throws {
        let mix = WAVExportMix.current(AnalysisMix())
        XCTAssertTrue(try mix.mutedChannels(activeChips: [0], fileName: "One.sid")[6])
        XCTAssertFalse(try mix.mutedChannels(activeChips: [0, 2], fileName: "Sparse.sid")[6])
        let isolated = try WAVExportMix.channel(6).mutedChannels(activeChips: [0, 2], fileName: "Sparse.sid")
        XCTAssertEqual(isolated.filter { !$0 }.count, 1)
        XCTAssertFalse(isolated[6])
        XCTAssertThrowsError(try WAVExportMix.channel(3).mutedChannels(activeChips: [0, 2], fileName: "Sparse.sid"))
    }

    func testExplicitSingleDestinationPreservesMultiSelectionAndCanReplaceOneFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = try preparedPair(in: folder, seconds: 0.1)
        let destination = folder.appendingPathComponent("explicit.wav"), original = Data("Existing output".utf8)
        try original.write(to: destination)
        let rejected = WAVBatchExporter.run(items: items, options: WAVExportOptions(), destination: .file(destination))
        XCTAssertTrue(rejected.files.isEmpty)
        XCTAssertNotNil(rejected.error)
        XCTAssertEqual(try Data(contentsOf: destination), original)
        let replaced = WAVBatchExporter.run(items: [items[0]], options: WAVExportOptions(), destination: .file(destination))
        XCTAssertEqual(replaced.files, [destination])
        XCTAssertNil(replaced.error)
        XCTAssertEqual(try Data(contentsOf: destination).count, 44 + 4410 * 4)
        let sourceBytes = try Data(contentsOf: items[0].sourceURL)
        let sourceTarget = WAVBatchExporter.run(items: [items[0]], options: WAVExportOptions(), destination: .file(items[0].sourceURL))
        XCTAssertTrue(sourceTarget.files.isEmpty)
        XCTAssertNotNil(sourceTarget.error)
        XCTAssertEqual(try Data(contentsOf: items[0].sourceURL), sourceBytes)
        let longDestination = folder.appendingPathComponent(String(repeating: "a", count: 240) + ".wav")
        let longResult = WAVBatchExporter.run(items: [items[0]], options: WAVExportOptions(), destination: .file(longDestination))
        XCTAssertNil(longResult.error)
        XCTAssertEqual(longResult.files, [longDestination])
    }

    #if canImport(Combine)
    @MainActor
    func testControllerKeepsTheLatestPreparationWhenAnOldSourceFails() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Valid.sid")
        try sparseSIDData().write(to: source)
        let context = WAVExportDurationContext(resolver: SongLengthResolver(cache: SongLengthCache(fileURL: folder.appendingPathComponent("cache.json"))),
            database: nil, settings: PlaybackSettingsDocument(), clockMode: .auto)
        let controller = WAVExportController()
        controller.prepare(sources: [WAVExportSource(url: folder.appendingPathComponent("Missing.sid"))], durations: context)
        controller.prepare(sources: [WAVExportSource(url: source, subtune: 0)], durations: context)
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while controller.isWorking && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.state, .ready)
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.items.map(\.sourceURL), [source])
        XCTAssertTrue(controller.canExport)
    }
    #endif

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func preparedPair(in folder: URL, seconds: Double) throws -> [WAVExportItem] {
        let sources = ["First.sid", "Second.sid"].map { folder.appendingPathComponent($0) }
        for source in sources { try sparseSIDData().write(to: source) }
        let context = WAVExportDurationContext(resolver: SongLengthResolver(cache: SongLengthCache(fileURL: folder.appendingPathComponent("cache.json"))),
            database: nil, settings: PlaybackSettingsDocument(), clockMode: .auto)
        let items = try WAVExportPlanner.prepare(sources: sources.map { WAVExportSource(url: $0, subtune: 0) }, durations: context)
        return try WAVExportPlanner.applyingDuration(seconds, to: items)
    }

    private func sparseSID() throws -> SidFileData { try SidParser.parse(data: sparseSIDData()) }

    private func sparseSIDData(subtunes: Int = 1, filtered: Bool = false) -> Data {
        var code: [UInt8] = []
        func store(_ value: UInt8, _ address: Int) {
            code += [0xa9, value, 0x8d, UInt8(address & 255), UInt8(address >> 8)]
        }
        store(0, 0xd418)
        store(filtered ? 0x1f : 15, 0xd458)
        if filtered { store(0xf1, 0xd457); store(0x20, 0xd456) }
        store(0x45, 0xd440)
        store(0x1d, 0xd441)
        store(0, 0xd445)
        store(0xf0, 0xd446)
        store(0x21, 0xd444)
        code += [0x60]
        let play = 0x1000 + code.count
        code += [0x60]
        var data = Data(count: 0x7c)
        data.replaceSubrange(0..<4, with: "PSID".utf8)
        func put(_ value: Int, _ offset: Int) {
            data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255)
        }
        put(4, 4); put(0x7c, 6); put(0x1000, 8); put(0x1000, 10); put(play, 12)
        put(subtunes, 14); put(1, 16); data[0x7b] = 0x44
        return data + Data(code)
    }
}

private final class ExportFrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int] = []
    func append(_ frame: Int) { lock.lock(); frames.append(frame); lock.unlock() }
    func snapshot() -> [Int] { lock.lock(); defer { lock.unlock() }; return frames }
}
