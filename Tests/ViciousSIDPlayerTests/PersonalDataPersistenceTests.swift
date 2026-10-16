import XCTest
@testable import ViciousSIDPlayerCore

final class PersonalDataPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testFreshStoresCanCreateButCannotReplaceUnreadFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let listURL = root.appendingPathComponent(ListeningLibraryStore.fileName)
        let playbackURL = root.appendingPathComponent(PlaybackSettingsStore.fileName)
        try ListeningLibraryStore(fileURL: listURL).save(ListeningLibraryDocument())
        try PlaybackSettingsStore(fileURL: playbackURL).save(PlaybackSettingsDocument())
        let listBytes = try Data(contentsOf: listURL), playbackBytes = try Data(contentsOf: playbackURL)
        XCTAssertThrowsError(try ListeningLibraryStore(fileURL: listURL).save(ListeningLibraryDocument()))
        XCTAssertThrowsError(try PlaybackSettingsStore(fileURL: playbackURL).save(PlaybackSettingsDocument()))
        XCTAssertEqual(try Data(contentsOf: listURL), listBytes)
        XCTAssertEqual(try Data(contentsOf: playbackURL), playbackBytes)
    }

    func testExternalListReplacementAndDeletionSurviveFlushUntilReload() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ListeningLibraryStore(fileURL: root.appendingPathComponent(ListeningLibraryStore.fileName))
        let initial = try store.load()
        try store.save(initial)
        let external = ListeningLibraryDocument(lists: [SavedListeningList(libraryID: "other", name: "From another process")])
        let bytes = try JSONEncoder().encode(external); try bytes.write(to: store.fileURL)
        XCTAssertThrowsError(try store.save(initial))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        XCTAssertThrowsError(try store.save(initial))
        XCTAssertEqual(try store.load(), external)
        try FileManager.default.removeItem(at: store.fileURL)
        XCTAssertThrowsError(try store.save(external))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        _ = try store.load(); try store.save(initial)
        XCTAssertEqual(try store.load(), initial)
    }

    func testPlaybackStorePreservesExternalEndTimesIncludingAfterFailedLoad() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybackSettingsStore(fileURL: root.appendingPathComponent(PlaybackSettingsStore.fileName))
        let initial = try store.load(); try store.save(initial)
        var external = initial
        try external.setEndTime(42.5, md5: String(repeating: "a", count: 32), subtune: 3)
        let bytes = try JSONEncoder().encode(external); try bytes.write(to: store.fileURL)
        XCTAssertThrowsError(try store.save(initial))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        XCTAssertEqual(try store.load(), external)
        for invalid in [Data("{broken".utf8), Data("{\"version\":99}".utf8)] {
            try invalid.write(to: store.fileURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(initial))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), invalid)
        }
    }

    func testOversizedPersonalFileIsPreservedWithoutDecoding() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("oversized.json")
        let bytes = Data(repeating: 32, count: PersonalDataFile.maximumBytes + 1)
        try bytes.write(to: url)
        let lists = ListeningLibraryStore(fileURL: url), playback = PlaybackSettingsStore(fileURL: url)
        XCTAssertThrowsError(try lists.load())
        XCTAssertThrowsError(try playback.load())
        XCTAssertThrowsError(try lists.save(ListeningLibraryDocument()))
        XCTAssertThrowsError(try playback.save(PlaybackSettingsDocument()))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    #if canImport(Combine)
    @MainActor
    func testControllerFlushCannotClobberChangesBeforeImport() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let listURL = root.appendingPathComponent(ListeningLibraryStore.fileName)
        let playbackURL = root.appendingPathComponent(PlaybackSettingsStore.fileName)
        let lists = ListeningLibraryController(fileURL: listURL), playback = PlaybackOptionsController(fileURL: playbackURL)
        for _ in 0..<200 where !lists.isLoaded || !playback.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(lists.isLoaded && playback.isLoaded)
        _ = lists.createList(name: "Pending local list", entries: [])
        playback.setRepeatMode(.sequence)
        let externalLists = try JSONEncoder().encode(ListeningLibraryDocument(lists: [SavedListeningList(libraryID: "other", name: "External")]))
        var settings = PlaybackSettingsDocument(); settings.fadeOutSeconds = 9
        let externalPlayback = try JSONEncoder().encode(settings)
        try externalLists.write(to: listURL); try externalPlayback.write(to: playbackURL)
        lists.flush(); playback.flush()
        XCTAssertTrue(lists.isReadOnly && playback.isReadOnly)
        XCTAssertNotNil(lists.storageError); XCTAssertNotNil(playback.storageError)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(try Data(contentsOf: listURL), externalLists)
        XCTAssertEqual(try Data(contentsOf: playbackURL), externalPlayback)
        XCTAssertNil(lists.createList(name: "Blocked", entries: []))
        playback.setRepeatMode(.file)
        XCTAssertEqual(playback.document.repeatMode, .file)
        playback.flush()
        XCTAssertEqual(try Data(contentsOf: playbackURL), externalPlayback)
    }
    #endif
}
