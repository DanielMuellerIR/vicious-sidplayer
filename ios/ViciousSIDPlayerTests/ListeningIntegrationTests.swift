import XCTest
import ViciousSIDPlayerCore
@testable import ViciousSIDPlayer

@MainActor
final class ListeningIntegrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var models: [AppModel] = []
    private let suite = "vsp-listening-integration"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        for model in models {
            model.coordinator.stop(); model.stopPlaybackLoop(); model.listening.flush(); model.savedSearches.flush()
            await model.metadataIndex.suspend()
        }
        models = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func fixture(title: String) -> Data {
        var data = Data(repeating: 0, count: 0x7C)
        data.replaceSubrange(0..<4, with: Array("PSID".utf8))
        func word(_ offset: Int, _ value: Int) { data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255) }
        word(4, 2); word(6, 0x7C); word(8, 0x1000); word(10, 0x1000); word(12, 0x100B); word(14, 3); word(16, 1)
        data[0x77] = 0x28
        data.replaceSubrange(0x16..<(0x16 + title.utf8.count), with: Array(title.utf8))
        let author = Array("Listening Composer".utf8)
        data.replaceSubrange(0x36..<(0x36 + author.count), with: author)
        data.append(contentsOf: [0x0A,0x0A,0x0A,0x0A,0x18,0x69,0x20,0x8D,0x01,0xD4,0x60,0x60])
        return data
    }

    private func makeModel(container: String = "first") async throws -> AppModel {
        let root = directory.appendingPathComponent(container).appendingPathComponent("Documents")
        let support = directory.appendingPathComponent(container).appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        try fixture(title: "Alpha").write(to: root.appendingPathComponent("Alpha/A.sid"))
        try fixture(title: "Beta").write(to: root.appendingPathComponent("B.sid"))
        try fixture(title: "Gamma").write(to: root.appendingPathComponent("C.sid"))
        let library = MusicLibrary(root: root, supportDirectory: support)
        _ = try library.refresh()
        let model = AppModel(defaults: defaults, listeningFileURL: support.appendingPathComponent(ListeningLibraryStore.fileName))
        model.services = PlayerServices(library: library)
        model.applyLibrary(tracks: library.entries.map { LibraryTrack(id: $0.id, name: $0.displayName, folderPath: $0.folderPath) },
                           folderTree: MusicLibrary.folderTree(for: library.entries))
        for _ in 0..<100 where !model.listening.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
        model.activateListeningLibrary()
        models.append(model)
        return model
    }

    func testFiltersDoNotChangeThePreparedListeningSequence() async throws {
        let model = try await makeModel()
        model.select(trackID: "Alpha/A.sid")
        model.searchText = "B"; model.favoritesOnly = true; model.setFavorites(["B.sid"])
        model.playNext()
        XCTAssertEqual(model.currentTrackID, "B.sid")
        model.searchText = "Alpha"
        model.playNext()
        XCTAssertEqual(model.currentTrackID, "C.sid")
        XCTAssertFalse(model.coordinator.isPlaying)
        XCTAssertEqual(model.listening.queue?.items.count, 3)
    }

    func testExactSubtunesOfOneFileNavigateIndependentlyAndStopAtEnd() async throws {
        let model = try await makeModel()
        let a = ListeningEntry(trackID: "Alpha/A.sid", subtune: 2), b = ListeningEntry(trackID: "Alpha/A.sid", subtune: 0)
        model.listening.setQueue(ListeningQueue(libraryID: AppModel.listeningCollectionID, name: "Subtunes", entries: [a,b]))
        XCTAssertTrue(model.loadListeningEntry(a, autoplay: false))
        model.playNext()
        XCTAssertEqual(model.coordinator.currentSubtune, 0)
        model.playPrevious()
        XCTAssertEqual(model.coordinator.currentSubtune, 2)
        model.playNext(); model.playNext()
        XCTAssertFalse(model.coordinator.isPlaying)
        XCTAssertEqual(model.listening.queue?.current?.id, b.id)
    }

    func testRestorePreservesPositionQueueAndPendingNextAcrossAContainerMove() async throws {
        let first = try await makeModel()
        let entries = [ListeningEntry(trackID: "Alpha/A.sid", subtune: 2), ListeningEntry(trackID: "Alpha/A.sid", subtune: 0)]
        var queue = ListeningQueue(libraryID: AppModel.listeningCollectionID, name: "Saved", kind: .savedList, entries: entries)
        queue.enqueueNext(ListeningEntry(trackID: "B.sid", subtune: 1)); first.listening.setQueue(queue)
        XCTAssertTrue(first.loadListeningEntry(entries[0], autoplay: false)); first.seek(to: 12); first.listening.flush()
        let bytes = try Data(contentsOf: directory.appendingPathComponent("first/Support/listening-library.json"))
        let second = try await makeModel(container: "moved")
        try bytes.write(to: directory.appendingPathComponent("moved/Support/listening-library.json"))
        // Ein neues Modell liest die kopierte Support-Datei wie nach einem Containerumzug.
        let restored = AppModel(defaults: defaults, listeningFileURL: directory.appendingPathComponent("moved/Support/listening-library.json"))
        restored.services = PlayerServices(library: second.services.library)
        restored.applyLibrary(tracks: second.tracks, folderTree: second.folderTree)
        models.append(restored)
        for _ in 0..<100 where !restored.listening.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
        restored.restoreSessionIfPossible()
        XCTAssertEqual(restored.currentTrackID, "Alpha/A.sid")
        XCTAssertEqual(restored.coordinator.currentSubtune, 2)
        XCTAssertEqual(restored.coordinator.elapsedSeconds, 12, accuracy: 0.001)
        XCTAssertFalse(restored.coordinator.isPlaying)
        XCTAssertEqual(restored.listening.queue?.items.map(\.trackID), ["Alpha/A.sid", "B.sid", "Alpha/A.sid"])
        XCTAssertEqual(restored.listening.queue?.libraryID, "ios-documents")
    }

    func testShufflePreparationPreservesTheExactSavedEntryOfOneFile() async throws {
        let first = try await makeModel()
        let entries = [ListeningEntry(trackID: "Alpha/A.sid", subtune: 2), ListeningEntry(trackID: "Alpha/A.sid", subtune: 0)]
        first.listening.setQueue(ListeningQueue(libraryID: AppModel.listeningCollectionID, name: "Subs", kind: .savedList, entries: entries))
        XCTAssertTrue(first.loadListeningEntry(entries[0], autoplay: false))
        first.seek(to: 12); first.listening.flush()
        let savedEntry = defaults.string(forKey: AppModel.Keys.lastListeningEntryID)
        first.shuffle = true
        let shuffled = try await makeModel()
        shuffled.restoreSessionIfPossible(); shuffled.listening.flush()
        XCTAssertEqual(defaults.string(forKey: AppModel.Keys.lastListeningEntryID), savedEntry)
        XCTAssertEqual(defaults.double(forKey: AppModel.Keys.lastPosition), 12)
        shuffled.shuffle = false
        let restored = try await makeModel()
        restored.restoreSessionIfPossible()
        XCTAssertEqual(restored.listening.queue?.current?.id, entries[0].id)
        XCTAssertEqual(restored.coordinator.currentSubtune, 2)
        XCTAssertEqual(restored.coordinator.elapsedSeconds, 12, accuracy: 0.001)
        XCTAssertFalse(restored.coordinator.isPlaying)
    }

    private func awaitMetadata(_ model: AppModel) async throws {
        for _ in 0..<200 where model.metadataIndex.isIndexing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.metadataIndex.isIndexing)
        for _ in 0..<100 where !model.savedSearches.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testMetadataFiltersAndSavedViewsLeaveThePreparedSequenceUnchanged() async throws {
        let model = try await makeModel(); try await awaitMetadata(model)
        model.select(trackID: "Alpha/A.sid")
        let queue = model.listening.queue
        model.searchText = "title:Beta author:\"Listening Composer\" chips:1 model:8580"
        XCTAssertEqual(model.visibleTracks.map(\.id), ["B.sid"])
        XCTAssertEqual(model.listeningEntries(scope: .visible(searchText: model.searchText, favoritesOnly: false)).map(\.trackID), ["B.sid"])
        XCTAssertEqual(model.listening.queue, queue)
        model.savedSearches.save(name: "Beta", query: model.searchText, favoritesOnly: false); model.savedSearches.flush()
        let restored = try await makeModel(); try await awaitMetadata(restored)
        let saved = try XCTUnwrap(restored.savedSearches.document.searches.first)
        restored.searchText = saved.query
        XCTAssertEqual(restored.visibleTracks.map(\.id), ["B.sid"])
    }

    func testChangedHeaderInvalidatesMetadataWithoutReplacingAnExplicitQueue() async throws {
        let model = try await makeModel(); try await awaitMetadata(model)
        let entry = ListeningEntry(trackID: "Alpha/A.sid", subtune: 1)
        model.listening.setQueue(ListeningQueue(libraryID: AppModel.listeningCollectionID, name: "Keep", entries: [entry]))
        let root = try XCTUnwrap(model.services.library?.root)
        try fixture(title: "Changed").write(to: root.appendingPathComponent("Alpha/A.sid"))
        _ = try model.services.library?.refresh()
        model.applyLibrary(tracks: model.tracks, folderTree: model.folderTree); try await awaitMetadata(model)
        model.searchText = "title:Changed"
        XCTAssertEqual(model.visibleTracks.map(\.id), ["Alpha/A.sid"])
        XCTAssertEqual(model.listening.queue?.items, [entry])
    }

    func testFutureSavedViewsRemainReadOnlyAndByteIdentical() async throws {
        let model = try await makeModel(); try await awaitMetadata(model)
        let url = directory.appendingPathComponent("first/Support/saved-searches.json")
        let raw = Data("{\"version\":99,\"searches\":[]}".utf8); try raw.write(to: url)
        let controller = SavedLibrarySearchController(fileURL: url)
        for _ in 0..<100 where !controller.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(controller.isReadOnly)
        controller.save(name: "Do not write", query: "chips:3", favoritesOnly: false); controller.flush()
        XCTAssertEqual(try Data(contentsOf: url), raw)
    }

    func testInvalidSubtuneCannotReplaceThePreparedTitle() async throws {
        let model = try await makeModel()
        model.select(trackID: "B.sid")
        let old = model.listening.queue
        XCTAssertFalse(model.loadListeningEntry(ListeningEntry(trackID: "Alpha/A.sid", subtune: 99), autoplay: false))
        XCTAssertEqual(model.currentTrackID, "B.sid")
        XCTAssertEqual(model.coordinator.currentSubtune, 0)
        XCTAssertEqual(model.listening.queue, old)
    }

    func testMissingNextEntryIsSkippedWithoutChangingTheSavedList() async throws {
        let model = try await makeModel()
        let entries = [ListeningEntry(trackID: "Alpha/A.sid"), ListeningEntry(trackID: "missing.sid"), ListeningEntry(trackID: "C.sid", subtune: 1)]
        let id = try XCTUnwrap(model.saveListeningList(name: "Missing", entries: entries))
        model.listening.setQueue(ListeningQueue(libraryID: AppModel.listeningCollectionID, name: "Missing", entries: entries))
        XCTAssertTrue(model.loadListeningEntry(entries[0], autoplay: false)); model.playNext()
        XCTAssertEqual(model.currentTrackID, "C.sid")
        XCTAssertEqual(model.coordinator.currentSubtune, 1)
        XCTAssertEqual(model.listening.lists.first { $0.id == id }?.entries, entries)
    }
}
