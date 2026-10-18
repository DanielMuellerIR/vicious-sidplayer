import XCTest
@testable import ViciousSIDPlayerCore

final class LibraryMetadataTests: XCTestCase, @unchecked Sendable {
    func testOldMetadataCacheIsRebuiltForTheNewHeaderInterpretation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Music"), support = directory.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let bytes = fixture(); try bytes.write(to: root.appendingPathComponent("Tune.sid"))
        let library = MusicLibrary(root: root, supportDirectory: support); _ = try library.refresh()
        let entry = try XCTUnwrap(library.entries.first)
        let record = LibraryMetadataRecord(fileSize: entry.fileSize, modificationDate: entry.modificationDate,
            metadata: try LibraryMetadata(data: bytes))
        let records = try JSONSerialization.jsonObject(with: JSONEncoder().encode([entry.id: record]))
        let cache = LibraryMetadataCache(root: root, supportDirectory: support), file = await cache.fileURL
        try JSONSerialization.data(withJSONObject: ["version": 1, "records": records]).write(to: file)
        let old = await cache.cachedRecords(for: library.entries)
        XCTAssertTrue(old.isEmpty)
        let rebuilt = try await cache.refresh(entries: library.entries)
        XCTAssertEqual(rebuilt[entry.id]?.metadata?.title, "Cyber Noid")
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 2)
        XCTAssertEqual(try Data(contentsOf: entry.url(relativeTo: root)), bytes)
    }
    private func fixture(title: String = "Cyber Noid", author: String = "Jérôme", flags: UInt16 = 0x20, chips: Int = 1) -> Data {
        var bytes = Data(repeating: 0, count: 0x7C)
        bytes.replaceSubrange(0..<4, with: "PSID".utf8)
        func word(_ offset: Int, _ value: UInt16) { bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(value & 255) }
        word(4, 4); word(6, 0x7C); word(8, 0x1000); word(10, 0x1000); word(12, 0x1000); word(14, 3); word(16, 1); word(0x76, flags)
        for (offset, value) in [(0x16, title), (0x36, author), (0x56, "1987 Demo")] {
            let text = Array(value.data(using: .isoLatin1)!)
            bytes.replaceSubrange(offset..<(offset + text.count), with: text)
        }
        if chips > 1 { bytes[0x7A] = 0x42 }
        if chips > 2 { bytes[0x7B] = 0x44 }
        bytes.append(0x60)
        return bytes
    }

    func testHeaderFieldsModelsAndRealDataSlices() throws {
        let bytes = fixture(flags: 0x1A0, chips: 3)
        var envelope = Data([0, 0, 0]); envelope.append(bytes)
        let metadata = try LibraryMetadata(data: envelope[3...])
        XCTAssertEqual(metadata.title, "Cyber Noid"); XCTAssertEqual(metadata.author, "Jérôme")
        XCTAssertEqual(metadata.released, "1987 Demo"); XCTAssertEqual(metadata.subtunes, 3)
        XCTAssertEqual(metadata.chipModels, [.mos8580, .mos8580, .mos6581])
        XCTAssertEqual(metadata.md5, SonglengthDB.md5Hex(of: bytes))
    }

    func testUnknownHeadersDoNotBecomeEmulatorFallbackFacts() throws {
        let metadata = try LibraryMetadata(data: fixture(title: "", author: "", flags: 0))
        XCTAssertNil(metadata.title); XCTAssertNil(metadata.author)
        XCTAssertEqual(metadata.chipModels, [.unknown])
        XCTAssertTrue(LibrarySearchQuery("model:unknown").matches(name: "File", folderPath: "", metadata: metadata))
        XCTAssertFalse(LibrarySearchQuery("model:6581").matches(name: "File", folderPath: "", metadata: metadata))
    }

    func testStructuredUnicodeSearchUsesAllTermsAndQuotedFieldValues() throws {
        let metadata = try LibraryMetadata(data: fixture())
        for query in ["title:\"Cyber Noid\" author:jér released:1987 chips:1 model:8580", "Cyber Demo", "Folder author:JÉRÔME", "author:jerome"] {
            XCTAssertTrue(LibrarySearchQuery(query).matches(name: "renamed", folderPath: "Folder", metadata: metadata), query)
        }
        XCTAssertFalse(LibrarySearchQuery("author:other").matches(name: "Jérôme", folderPath: "", metadata: metadata))
        XCTAssertFalse(LibrarySearchQuery("chips:2").matches(name: "File", folderPath: "", metadata: metadata))
    }

    func testMalformedQueriesCannotSilentlyBroadenTheSelection() {
        for query in ["author:", "chips:4", "model:6590", "duration:maybe", "what:hi", "title:\"unfinished", "min:nan", "max:inf", "min:-1", "min:3:99", "min:180 max:60"] {
            let parsed = LibrarySearchQuery(query)
            XCTAssertNotNil(parsed.error, query)
            XCTAssertFalse(parsed.matches(name: "Anything", folderPath: "", metadata: nil), query)
        }
    }

    func testDurationFiltersTreatUnknownAndZeroExplicitly() {
        let query = LibrarySearchQuery("min:1:00 max:180")
        XCTAssertTrue(query.matches(name: "", folderPath: "", metadata: nil, duration: 60))
        XCTAssertTrue(query.matches(name: "", folderPath: "", metadata: nil, duration: 180))
        XCTAssertFalse(query.matches(name: "", folderPath: "", metadata: nil, duration: 181))
        XCTAssertFalse(query.matches(name: "", folderPath: "", metadata: nil))
        XCTAssertTrue(LibrarySearchQuery("duration:unknown metadata:unknown").matches(name: "", folderPath: "", metadata: nil))
        XCTAssertTrue(LibrarySearchQuery("duration:known max:0").matches(name: "", folderPath: "", metadata: nil, duration: 0))
    }

    func testKnownDurationUsesDatabaseBeforeCacheAndNeverFallbackOrLoop() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = try LibraryMetadata(data: fixture()), cache = SongLengthCache(fileURL: url)
        XCTAssertNil(metadata.firstSubtuneDuration(database: nil, cache: cache))
        cache.store(md5: metadata.md5, subtune: 0, seconds: -1)
        XCTAssertNil(metadata.firstSubtuneDuration(database: nil, cache: cache))
        cache.store(md5: metadata.md5, subtune: 0, seconds: 90)
        XCTAssertEqual(metadata.firstSubtuneDuration(database: nil, cache: cache), 90)
        XCTAssertEqual(metadata.firstSubtuneDuration(database: SonglengthDB(entries: [metadata.md5: [120]]), cache: cache), 120)
    }

    func testCacheReusesUnchangedFilesInvalidatesEditsAndDropsRemovedFiles() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("Music"), support = temp.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("A.sid")
        try fixture().write(to: url)
        let library = MusicLibrary(root: root, supportDirectory: support)
        _ = try library.refresh()
        let cache = LibraryMetadataCache(root: root, supportDirectory: support)
        let first = try await cache.refresh(entries: library.entries)
        XCTAssertEqual(first["A.sid"]?.metadata?.title, "Cyber Noid")
        try fixture(title: "Changed title").write(to: url)
        _ = try library.refresh()
        let stale = await cache.cachedRecords(for: library.entries)
        XCTAssertTrue(stale.isEmpty)
        let second = try await cache.refresh(entries: library.entries)
        XCTAssertEqual(second["A.sid"]?.metadata?.title, "Changed title")
        let reloaded = LibraryMetadataCache(root: root, supportDirectory: support)
        let cached = await reloaded.cachedRecords(for: library.entries)
        XCTAssertEqual(cached, second)
        try FileManager.default.removeItem(at: url); _ = try library.refresh()
        let empty = try await cache.refresh(entries: library.entries)
        XCTAssertTrue(empty.isEmpty)
    }

    func testDistinctRootsNeverShareMetadataAndCorruptCacheRebuilds() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let support = temp.appendingPathComponent("Support")
        var urls: [URL] = []
        for name in ["First", "Second"] {
            let root = temp.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try fixture(title: name).write(to: root.appendingPathComponent("Same.sid"))
            let library = MusicLibrary(root: root, supportDirectory: support); _ = try library.refresh()
            let cache = LibraryMetadataCache(root: root, supportDirectory: support)
            let records = try await cache.refresh(entries: library.entries)
            XCTAssertEqual(records["Same.sid"]?.metadata?.title, name)
            let file = await cache.fileURL; urls.append(file)
            try Data("{broken".utf8).write(to: file)
            let rebuilt = try await LibraryMetadataCache(root: root, supportDirectory: support).refresh(entries: library.entries)
            XCTAssertEqual(rebuilt["Same.sid"]?.metadata?.title, name)
        }
        XCTAssertNotEqual(urls[0], urls[1])
    }

    func testUnavailableFilesAreRetriedAndStaleIndexSignaturesAreNotUsed() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_000_000), data = fixture()
        let entry = MusicLibraryEntry(relativePath: "A.sid", displayName: "A", fileSize: data.count, modificationDate: date)
        let cache = LibraryMetadataCache(root: temp, supportDirectory: temp.appendingPathComponent("Support"))
        let absent = try await cache.refresh(entries: [entry]); XCTAssertNil(absent[entry.id]?.metadata)
        let url = temp.appendingPathComponent("A.sid"); try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let retried = try await cache.refresh(entries: [entry]); XCTAssertEqual(retried[entry.id]?.metadata?.title, "Cyber Noid")
        let stale = MusicLibraryEntry(relativePath: "A.sid", displayName: "A", fileSize: data.count + 1, modificationDate: date)
        let rejected = try await cache.refresh(entries: [stale]); XCTAssertNil(rejected[entry.id])
    }

    func testDurationDisplayHandlesExtremeFiniteValues() {
        XCTAssertEqual(LibraryMetadata.durationDescription(90), "1:30")
        XCTAssertFalse(LibraryMetadata.durationDescription(1e100).isEmpty)
        XCTAssertFalse(LibraryMetadata.durationDescription(.infinity).isEmpty)
    }

    func testDuplicateAndEscapingIndexEntriesCannotCrashOrReadOutsideTheRoot() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("Music"), support = temp.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try fixture().write(to: root.appendingPathComponent("A.sid"))
        try fixture(title: "Outside").write(to: temp.appendingPathComponent("outside.sid"))
        let library = MusicLibrary(root: root, supportDirectory: support); _ = try library.refresh()
        let entry = try XCTUnwrap(library.entries.first)
        let values = try temp.appendingPathComponent("outside.sid").resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let outside = MusicLibraryEntry(relativePath: "../outside.sid", displayName: "Outside", fileSize: values.fileSize!, modificationDate: values.contentModificationDate!)
        let cache = LibraryMetadataCache(root: root, supportDirectory: support)
        let first = try await cache.refresh(entries: [entry, entry, outside])
        let cached = await cache.cachedRecords(for: [entry, entry, outside])
        XCTAssertEqual(first.count, 1); XCTAssertEqual(cached.count, 1)
        XCTAssertNil(first[outside.id])
    }

    func testFiftyThousandSearchEntriesKeepIdentityAndDurationRules() throws {
        let metadata = try LibraryMetadata(data: fixture())
        let record = LibraryMetadataRecord(fileSize: 125, modificationDate: Date(timeIntervalSince1970: 0), metadata: metadata, unavailable: false)
        let tracks = (0..<50000).map { PlaylistTrack(id: "Folder/Track\($0).sid", name: "Track\($0)", folderPath: "Folder", url: URL(fileURLWithPath: "/fixture/Track\($0).sid")) }
        let playlist = Playlist(tracks: tracks), records = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, LibraryMetadataRecord(fileSize: record.fileSize, modificationDate: record.modificationDate, metadata: metadata, name: $0.name, folderPath: $0.folderPath)) })
        let favorites = PlaylistFavorites(ids: [tracks[49999].id])
        let start = Date()
        let named = LibrarySearchSelection.indices(in: playlist, query: LibrarySearchQuery("Track49999"), records: records, favoritesOnly: false, favorites: favorites)
        let nameMS = Date().timeIntervalSince(start) * 1000
        let second = Date()
        let authored = LibrarySearchSelection.indices(in: playlist, query: LibrarySearchQuery("author:jerome chips:1 model:8580 min:60 max:180"), records: records, favoritesOnly: false, favorites: favorites, duration: { _ in 90 })
        let metadataMS = Date().timeIntervalSince(second) * 1000
        XCTAssertEqual(named, [49999]); XCTAssertEqual(authored.count, 50000)
        let favorite = LibrarySearchSelection.indices(in: playlist, query: LibrarySearchQuery("title:Cyber"), records: records, favoritesOnly: true, favorites: favorites)
        XCTAssertEqual(favorite, [49999])
        print("METADATA_SEARCH_BENCH entries=50000 nameMS=\(nameMS) structuredMS=\(metadataMS)")
    }

    func testSavedSearchRoundtripAndUnsupportedDocumentsAreRejected() throws {
        var document = SavedLibrarySearchDocument()
        document.searches = [SavedLibrarySearch(name: "Short 3SID", query: "chips:3 max:180", favoritesOnly: true)]
        let decoded = try JSONDecoder().decode(SavedLibrarySearchDocument.self, from: JSONEncoder().encode(document)).validated()
        XCTAssertEqual(decoded, document)
        document.version = 99; XCTAssertThrowsError(try document.validated())
        document.version = 1; document.searches.append(document.searches[0]); XCTAssertThrowsError(try document.validated())
    }
}
