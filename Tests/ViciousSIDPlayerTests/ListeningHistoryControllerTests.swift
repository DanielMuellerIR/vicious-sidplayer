import XCTest
@testable import ViciousSIDPlayerCore

#if canImport(Combine)
final class ListeningHistoryControllerTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testImmediateFlushPersistsQualifiedPlaybackAndEditsAcrossRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let controller = ListeningHistoryController(fileURL: file)
        await controller.ready()
        let reference = ListeningPersonalReference(libraryID: "library", trackID: "A/Tune.sid", md5: String(repeating: "a", count: 32), subtune: 2)
        controller.observe(reference: reference, title: "Tune", position: 0, knownDuration: nil, isPlaying: true, force: true, uptime: 0)
        controller.observe(reference: reference, title: "Tune", position: 10, knownDuration: nil, isPlaying: false, force: true, uptime: 10)
        controller.saveBookmark(reference: reference, title: "Bridge", position: 1234.5)
        controller.setNote("Personal note", for: reference)
        let saved = await controller.flush()
        XCTAssertTrue(saved)
        let restored = ListeningHistoryController(fileURL: file)
        await restored.ready()
        XCTAssertEqual(restored.document.events.count, 1)
        XCTAssertEqual(restored.document.events.first?.heardSeconds, 10)
        XCTAssertEqual(restored.document.bookmarks.first?.position, 1234.5)
        XCTAssertEqual(restored.document.note(for: reference)?.text, "Personal note")
        XCTAssertEqual(restored.hasHeard(md5: reference.md5), true)
        restored.clearHistory()
        XCTAssertEqual(restored.hasHeard(md5: reference.md5), false)
        XCTAssertEqual(restored.document.bookmarks.count, 1)
        XCTAssertEqual(restored.document.notes.count, 1)
        let cleared = await restored.flush()
        XCTAssertTrue(cleared)
    }

    @MainActor
    func testConcurrentFlushesCannotRestoreAnOlderSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json")
        let controller = ListeningHistoryController(fileURL: file)
        await controller.ready()
        let reference = ListeningPersonalReference(libraryID: "library", trackID: "Tune.sid", md5: String(repeating: "b", count: 32))
        controller.setNote("First", for: reference)
        let first = Task { await controller.flush() }
        await Task.yield()
        controller.setNote("Second", for: reference)
        _ = await controller.flush()
        _ = await first.value
        let restored = ListeningHistoryController(fileURL: file)
        await restored.ready()
        XCTAssertEqual(restored.document.note(for: reference)?.text, "Second")
    }

    @MainActor
    func testExternalAndNewerDataStayUntouchedAndHeardStateIsUnknown() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("history.json")
        let controller = ListeningHistoryController(fileURL: file)
        await controller.ready()
        let external = Data("{\"version\":99}".utf8)
        try external.write(to: file)
        let saved = await controller.flush()
        XCTAssertFalse(saved)
        XCTAssertTrue(controller.isReadOnly)
        XCTAssertNil(controller.hasHeard(md5: String(repeating: "a", count: 32)))
        XCTAssertEqual(try Data(contentsOf: file), external)
        let restored = ListeningHistoryController(fileURL: file)
        await restored.ready()
        XCTAssertTrue(restored.isReadOnly)
        XCTAssertEqual(try Data(contentsOf: file), external)
    }

    @MainActor
    func testImportedContinuationRebasesTheRecorderWithoutCountingThePause() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("history.json"), controller = ListeningHistoryController(fileURL: file)
        await controller.ready()
        let ref = ListeningPersonalReference(libraryID: "target", trackID: "Tune.sid", md5: String(repeating: "a", count: 32), subtune: 0)
        let start = Date(timeIntervalSince1970: 1_792_152_000.123456)
        controller.observe(reference: ref, title: "Tune", position: 0, knownDuration: nil, isPlaying: true, force: true, uptime: 0, now: start)
        controller.observe(reference: ref, title: "Tune", position: 10, knownDuration: nil, isPlaying: false, force: true, uptime: 10, now: start.addingTimeInterval(10))
        try await controller.suspendForImport()
        let current = try XCTUnwrap(controller.document.events.first)
        let imported = ListeningHistoryEvent(id: current.id, reference: ref, title: "Tune",
            startedAt: Date(timeIntervalSince1970: 1_792_152_000.123), lastHeardAt: start.addingTimeInterval(20), heardSeconds: 20, lastPosition: 200)
        let document = try ListeningHistoryDocument(events: [imported], heardMD5s: [ref.md5], bookmarks: [], notes: [])
        let store = ListeningHistoryStore(fileURL: file); _ = try await store.load(); try await store.save(document)
        try await controller.verifyImportedDocument(document); controller.acceptImportedDocument(document); controller.resumeAfterImport()
        controller.observe(reference: ref, title: "Tune", position: 10, knownDuration: nil, isPlaying: true, force: true, uptime: 11, now: start.addingTimeInterval(21))
        controller.observe(reference: ref, title: "Tune", position: 11, knownDuration: nil, isPlaying: false, force: true, uptime: 12, now: start.addingTimeInterval(22))
        XCTAssertFalse(controller.isReadOnly)
        XCTAssertEqual(controller.document.events.count, 1)
        XCTAssertEqual(controller.document.events.first?.heardSeconds, 21)
        XCTAssertEqual(controller.document.events.first?.lastPosition, 11)
        let saved = await controller.flush()
        XCTAssertTrue(saved)
    }
}
#endif

final class ListeningReferenceResolverTests: XCTestCase {
    func testPathAndContentMustAgreeAndContentFallbackMustBeUnique() {
        let md5 = String(repeating: "a", count: 32)
        let reference = ListeningPersonalReference(libraryID: "first", trackID: "A/Tune.sid", md5: md5, subtune: 0)
        XCTAssertEqual(ListeningReferenceResolver.resolve(reference, libraryID: "first", contents: ["A/Tune.sid": md5, "B/Tune.sid": md5]), .found("A/Tune.sid"))
        XCTAssertEqual(ListeningReferenceResolver.resolve(reference, libraryID: "other", contents: ["A/Tune.sid": md5, "B/Tune.sid": md5]), .ambiguous)
        XCTAssertEqual(ListeningReferenceResolver.resolve(reference, libraryID: "other", contents: ["B/Tune.sid": md5]), .found("B/Tune.sid"))
        XCTAssertEqual(ListeningReferenceResolver.resolve(reference, libraryID: "first", contents: ["A/Tune.sid": String(repeating: "b", count: 32)]), .missing)
    }

    func testHeardSearchNeverConfusesUnknownWithNever() {
        let never = LibrarySearchQuery("heard:never"), yes = LibrarySearchQuery("heard:yes"), unknown = LibrarySearchQuery("heard:unknown")
        for heard in [true, false, nil] as [Bool?] {
            XCTAssertEqual(never.matches(name: "Tune", folderPath: "", metadata: nil, heard: heard), heard == false)
            XCTAssertEqual(yes.matches(name: "Tune", folderPath: "", metadata: nil, heard: heard), heard == true)
            XCTAssertEqual(unknown.matches(name: "Tune", folderPath: "", metadata: nil, heard: heard), heard == nil)
        }
        XCTAssertNotNil(LibrarySearchQuery("heard:no").error)
    }
}
