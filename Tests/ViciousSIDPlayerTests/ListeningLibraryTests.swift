import XCTest
@testable import ViciousSIDPlayerCore

final class ListeningLibraryTests: XCTestCase {
    private func entries(_ count: Int) -> [ListeningEntry] {
        (0..<count).map { ListeningEntry(trackID: "Composer/Tune\($0).sid", subtune: $0 % 3) }
    }

    private func store() -> ListeningLibraryStore {
        ListeningLibraryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("listening.json"))
    }

    func testSelectionsUsePathsFavoritesAndExactFolderBoundaries() {
        let root = URL(fileURLWithPath: "/music")
        var playlist = Playlist()
        _ = playlist.append([root.appendingPathComponent("A/Tune.sid"),root.appendingPathComponent("A/Sub/Other.sid"),
                             root.appendingPathComponent("AB/Tune.sid")], root: root)
        let favorites = PlaylistFavorites(storedValues: ["A/Tune.sid"], root: root)
        XCTAssertEqual(ListeningSelection.entries(in: playlist, scope: .folder("A"), favorites: favorites).map(\.trackID),
                       ["A/Tune.sid","A/Sub/Other.sid"])
        XCTAssertEqual(ListeningSelection.entries(in: playlist, scope: .favorites, favorites: favorites).map(\.trackID), ["A/Tune.sid"])
        let selected = ListeningSelection.entries(in: playlist, scope: .visible(searchText: "other", favoritesOnly: false), favorites: favorites)
        _ = playlist.append([root.appendingPathComponent("A/New.sid")], root: root)
        XCTAssertEqual(selected.map(\.trackID), ["A/Sub/Other.sid"], "Eine gestartete Auswahl bleibt ein Schnappschuss")
    }

    func testExactSubtunesAndRepeatedFilesRemainDistinctQueueEntries() {
        let first = ListeningEntry(trackID: "A.sid", subtune: 2)
        let second = ListeningEntry(trackID: "A.sid", subtune: 0)
        var queue = ListeningQueue(libraryID: "root", name: "Chosen", entries: [first,second])
        XCTAssertEqual(queue.current?.subtune, 2)
        XCTAssertEqual(queue.next(), second)
        XCTAssertEqual(queue.previous(), first)
        XCTAssertEqual(queue.next(), second)
        XCTAssertNil(queue.next(), "Ausdrueckliche Folgen stoppen am Ende")
        XCTAssertNil(ListeningPlaybackPolicy.nextSubtune(entry: first, current: 2, count: 5))
        XCTAssertEqual(ListeningPlaybackPolicy.nextSubtune(entry: ListeningEntry(trackID: "A.sid"), current: 2, count: 5), 3)
        XCTAssertNil(ListeningPlaybackPolicy.nextSubtune(entry: nil, current: 4, count: 5))
    }

    func testShuffleFromMiddleVisitsEveryEntryOnceBeforeEnding() {
        let items = entries(100)
        var queue = ListeningQueue(libraryID: "root", name: "Mixed", entries: items, startingAt: 45, shuffled: true)
        XCTAssertEqual(queue.current, items[45])
        var heard = [try! XCTUnwrap(queue.current)]
        while let next = queue.next() { heard.append(next) }
        XCTAssertEqual(heard.count, items.count)
        XCTAssertEqual(Set(heard.map(\.id)), Set(items.map(\.id)))
    }

    func testShuffleCyclesAvoidImmediateRepetition() {
        let items = entries(12)
        var queue = ListeningQueue(libraryID: "root", name: "Library", kind: .library,
                                   entries: items, shuffled: true, wraps: true)
        for _ in 0..<10 {
            var cycle = [queue.current!.id]
            for _ in 1..<items.count { cycle.append(queue.next()!.id) }
            XCTAssertEqual(Set(cycle), Set(items.map(\.id)))
            XCTAssertNotEqual(queue.next()?.id, cycle.last)
        }
    }

    func testEnqueueIsFIFOAndOneShotItemsDoNotRepeatInNextCycle() {
        let base = entries(2), a = ListeningEntry(trackID: "NextA.sid", subtune: 2), b = ListeningEntry(trackID: "NextB.sid")
        var queue = ListeningQueue(libraryID: "root", name: "Library", kind: .library, entries: base, wraps: true)
        queue.enqueueNext(a); queue.enqueueNext(b)
        XCTAssertEqual(queue.next()?.trackID, a.trackID)
        XCTAssertEqual(queue.next()?.trackID, b.trackID)
        XCTAssertEqual(queue.next(), base[1])
        XCTAssertEqual(queue.next(), base[0])
        XCTAssertEqual(queue.items, base)
        XCTAssertTrue(queue.oneShotIDs.isEmpty)
    }

    func testRestartWithShuffleKeepsPendingNextRequests() {
        var queue = ListeningQueue(libraryID: "root", name: "Library", kind: .library, entries: entries(5), wraps: true)
        queue.enqueueNext(ListeningEntry(trackID: "Pending.sid", subtune: 2))
        queue.restart(shuffled: true, preservePending: true)
        XCTAssertEqual(queue.next()?.trackID, "Pending.sid")
        XCTAssertEqual(queue.current?.subtune, 2)
    }

    func testMultiRowMoveKeepsOrderIdentityAndRejectsInvalidOffsets() {
        let items = entries(6)
        var queue = ListeningQueue(libraryID: "root", name: "Move", entries: items, startingAt: 2)
        queue.move(fromOffsets: IndexSet([1, 3]), toOffset: 6)
        XCTAssertEqual(queue.items.map(\.id), [items[0],items[2],items[4],items[5],items[1],items[3]].map(\.id))
        XCTAssertEqual(queue.current, items[2])
        let unchanged = queue
        queue.move(fromOffsets: IndexSet([99]), toOffset: 0)
        XCTAssertEqual(queue, unchanged)
    }

    func testRelativeIDsResolveAcrossContainersAndRejectTraversal() {
        let entry = ListeningEntry(trackID: "Composer/Tune.sid", subtune: 2)
        XCTAssertEqual(entry.url(relativeTo: URL(fileURLWithPath: "/old-container/Documents"))?.path, "/old-container/Documents/Composer/Tune.sid")
        XCTAssertEqual(entry.url(relativeTo: URL(fileURLWithPath: "/new-container/Documents"))?.path, "/new-container/Documents/Composer/Tune.sid")
        XCTAssertNil(ListeningEntry(trackID: "../outside.sid").url(relativeTo: URL(fileURLWithPath: "/music"), allowExternal: true))
        XCTAssertNil(ListeningEntry(trackID: "/external.sid").url(relativeTo: URL(fileURLWithPath: "/music")))
    }

    func testReorderingAndRemovingKeepCurrentIdentity() {
        let items = entries(4)
        var queue = ListeningQueue(libraryID: "root", name: "Order", entries: items, startingAt: 1)
        queue.move(items[3].id, by: -2)
        XCTAssertEqual(queue.items.map(\.id), [items[0].id,items[3].id,items[1].id,items[2].id])
        XCTAssertEqual(queue.current, items[1])
        queue.remove(items[1].id)
        XCTAssertEqual(queue.current, items[1])
        queue.remove(items[0].id)
        XCTAssertEqual(queue.current, items[1])
        XCTAssertEqual(queue.next(), items[2])
    }

    func testOnlyImplicitLibraryFollowsScans() {
        let old = entries(2), added = ListeningEntry(trackID: "New.sid")
        var library = ListeningQueue(libraryID: "root", name: "Library", kind: .library, entries: old)
        var selection = ListeningQueue(libraryID: "root", name: "Selected", entries: old)
        library.reconcileLibrary([old[1],added]); selection.reconcileLibrary([old[1],added])
        XCTAssertEqual(Set(library.items.map(\.trackID)), Set([old[0].trackID,old[1].trackID,added.trackID]))
        XCTAssertEqual(selection.items, old)
    }

    func testChangingExplicitSubtuneDoesNotChangeWholeFileEntries() {
        var queue = ListeningQueue(libraryID: "root", name: "Subtunes", entries: [ListeningEntry(trackID: "A.sid", subtune: 1)])
        queue.updateExplicitSubtune(2, trackID: "A.sid")
        XCTAssertEqual(queue.current?.subtune, 2)
        var all = ListeningQueue(libraryID: "root", name: "All", entries: [ListeningEntry(trackID: "A.sid")])
        all.updateExplicitSubtune(2, trackID: "A.sid")
        XCTAssertNil(all.current?.subtune)
    }

    func testPersistentRoundTripKeepsQueueOrderAndSubtunes() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let items = entries(5)
        var queue = ListeningQueue(libraryID: "root", name: "Selected", entries: items, startingAt: 2)
        queue.enqueueNext(ListeningEntry(trackID: "Next.sid", subtune: 4))
        let doc = ListeningLibraryDocument(lists: [SavedListeningList(libraryID: "root", name: "My list", entries: items)], queue: queue)
        try store.save(doc)
        XCTAssertEqual(try store.load(), doc)
    }

    func testCorruptFutureAndInvalidDataCannotOverwriteExistingFile() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(ListeningLibraryDocument())
        let original = try Data(contentsOf: store.fileURL)
        let invalid = ListeningLibraryDocument(lists: [SavedListeningList(libraryID: "root", name: "Bad",
            entries: [ListeningEntry(trackID: "../outside.sid", subtune: -1)])])
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String:Any])
        future["version"] = 99
        let bytes = try JSONSerialization.data(withJSONObject: future)
        try bytes.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        try Data("{broken".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }

    func testFiftyThousandEntriesPersistWithoutLosingIdentity() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let items = entries(50_000)
        let doc = ListeningLibraryDocument(queue: ListeningQueue(libraryID: "root", name: "Large", entries: items, startingAt: 49_998))
        try store.save(doc)
        var loaded = try XCTUnwrap(store.load().queue)
        XCTAssertEqual(loaded.current?.trackID, "Composer/Tune49998.sid")
        XCTAssertEqual(loaded.next()?.trackID, "Composer/Tune49999.sid")
        XCTAssertNil(loaded.next())
    }

    #if canImport(Combine)
    @MainActor
    func testColdOpenIntentSurvivesAsynchronousLoadingOfSavedLists() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let items = entries(2)
        try store.save(ListeningLibraryDocument(lists: [SavedListeningList(libraryID: "root", name: "Existing", entries: items)]))
        let model = ListeningLibraryController(fileURL: store.fileURL)
        let queue = ListeningQueue(libraryID: "root", name: "Cold open", entries: [items[1]])
        model.setQueue(queue)
        for _ in 0..<100 where !model.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.queue, queue)
        XCTAssertEqual(model.lists.first?.name, "Existing")
        model.flush()
    }

    @MainActor
    func testWriteFailureIsVisibleAndDoesNotOverwriteTheBlockingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked")
        let original = Data("keep".utf8); try original.write(to: blocked)
        let model = ListeningLibraryController(fileURL: blocked.appendingPathComponent("listening.json"))
        for _ in 0..<100 where !model.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
        _ = model.createList(name: "Unsaved", entries: [])
        model.flush()
        XCTAssertNotNil(model.storageError)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(try Data(contentsOf: blocked), original)
    }

    @MainActor
    func testControllerPreservesListsAcrossRootsAndFlushesLatestRevision() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let model = ListeningLibraryController(fileURL: store.fileURL)
        for _ in 0..<100 where !model.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.isLoaded)
        let items = entries(3)
        model.activateLibrary("one", tracks: items)
        let id = try XCTUnwrap(model.createList(name: "First", entries: items))
        model.renameList(id, to: "Latest")
        model.setQueue(ListeningQueue(libraryID: "one", name: "One", entries: items))
        model.activateLibrary("two", tracks: [])
        XCTAssertNil(model.queue)
        XCTAssertEqual(model.lists.count, 1)
        XCTAssertTrue(model.activeLists.isEmpty)
        model.activateLibrary("one", tracks: items)
        model.toggleSubtuneFavorite(trackID: items[0].trackID, subtune: 2)
        XCTAssertTrue(model.isSubtuneFavorite(trackID: items[0].trackID, subtune: 2))
        model.flush()
        let saved = try store.load()
        XCTAssertEqual(saved.lists.first?.name, "Latest")
        XCTAssertEqual(saved.lists.count, 2)
    }

    @MainActor
    func testControllerDoesNotReplaceUnreadablePersonalData() async throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{broken".utf8); try original.write(to: store.fileURL)
        let model = ListeningLibraryController(fileURL: store.fileURL)
        for _ in 0..<100 where !model.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(model.isReadOnly)
        XCTAssertNotNil(model.storageError)
        XCTAssertNil(model.createList(name: "New", entries: []))
        model.flush()
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }
    #endif
}
