import XCTest
@testable import ViciousSIDPlayerCore

final class ListeningHistoryTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func reference(_ number: Int = 1, subtune: Int? = 0, library: String = "root", path: String = "A/Tune.sid") -> ListeningPersonalReference {
        ListeningPersonalReference(libraryID: library, trackID: path, md5: String(format: "%032x", number), subtune: subtune)
    }
    private func event(_ number: Int = 1, seconds: Double = 10, date: Date? = nil) -> ListeningHistoryEvent {
        ListeningHistoryEvent(reference: reference(number), title: "Tune", startedAt: date ?? now,
            lastHeardAt: date ?? now, heardSeconds: seconds, lastPosition: 42)
    }
    private func observe(_ recorder: inout ListeningHistoryRecorder, reference: ListeningPersonalReference? = nil,
                         playing: Bool, uptime: Double, position: Double, duration: Double? = nil) -> ListeningHistoryEvent? {
        recorder.observe(reference: reference ?? self.reference(), title: "Tune", position: position,
            knownDuration: duration, isPlaying: playing, uptime: uptime, now: now.addingTimeInterval(uptime))
    }

    func testPreparingAndSeekingWithoutPlaybackNeverCreatesHistory() {
        var recorder = ListeningHistoryRecorder()
        for time in [0.0, 10, 300, 1000] {
            XCTAssertNil(observe(&recorder, playing: false, uptime: time, position: time))
        }
        XCTAssertNil(observe(&recorder, playing: true, uptime: 1001, position: 1000))
    }

    func testSeekAddsOnlyActualListeningTimeAndPauseDoesNotCreateAnotherEpisode() throws {
        var recorder = ListeningHistoryRecorder()
        XCTAssertNil(observe(&recorder, playing: true, uptime: 0, position: 0))
        XCTAssertNil(observe(&recorder, playing: true, uptime: 1, position: 500))
        let first = try XCTUnwrap(observe(&recorder, playing: false, uptime: 10, position: 509))
        XCTAssertEqual(first.heardSeconds, 10); XCTAssertEqual(first.lastPosition, 509)
        let paused = try XCTUnwrap(observe(&recorder, playing: false, uptime: 300, position: 900))
        XCTAssertEqual(paused.heardSeconds, 10); XCTAssertEqual(paused.lastPosition, 509)
        _ = observe(&recorder, playing: true, uptime: 301, position: 900)
        let resumed = try XCTUnwrap(observe(&recorder, playing: true, uptime: 302, position: 901))
        XCTAssertEqual(resumed.id, first.id); XCTAssertEqual(resumed.heardSeconds, 11)
        XCTAssertEqual(resumed.lastPosition, 901)
    }

    func testStopDoesNotReplaceTheLastHeardPositionWithTheResetDisplay() throws {
        var recorder = ListeningHistoryRecorder()
        _ = observe(&recorder, playing: true, uptime: 0, position: 0)
        let heard = try XCTUnwrap(observe(&recorder, playing: true, uptime: 10, position: 10))
        let stopped = try XCTUnwrap(observe(&recorder, playing: false, uptime: 11, position: 0))
        XCTAssertEqual(stopped.id, heard.id); XCTAssertEqual(stopped.heardSeconds, 11)
        XCTAssertEqual(stopped.lastPosition, 10)
        recorder.reset()
        XCTAssertNil(observe(&recorder, playing: false, uptime: 12, position: 0))
    }

    func testSubtuneRepeatReusesEpisodeButSubtuneChangeDoesNot() throws {
        var recorder = ListeningHistoryRecorder()
        _ = observe(&recorder, playing: true, uptime: 0, position: 0)
        let first = try XCTUnwrap(observe(&recorder, playing: true, uptime: 10, position: 10))
        let repeatStart = try XCTUnwrap(observe(&recorder, playing: true, uptime: 11, position: 0))
        XCTAssertEqual(repeatStart.id, first.id); XCTAssertEqual(repeatStart.heardSeconds, 11)
        let completed = try XCTUnwrap(observe(&recorder, reference: reference(subtune: 1), playing: true, uptime: 12, position: 0))
        XCTAssertEqual(completed.id, first.id)
        let second = try XCTUnwrap(observe(&recorder, reference: reference(subtune: 1), playing: true, uptime: 22, position: 10))
        XCTAssertNotEqual(second.id, first.id); XCTAssertEqual(second.reference.subtune, 1)
        XCTAssertEqual(second.heardSeconds, 10)
    }

    func testShortTuneUsesAProportionalThresholdButUnknownDurationNeedsTenSeconds() throws {
        var short = ListeningHistoryRecorder(), unknown = ListeningHistoryRecorder()
        _ = observe(&short, playing: true, uptime: 0, position: 0, duration: 2)
        XCTAssertNil(observe(&short, playing: true, uptime: 0.9, position: 0.9, duration: 2))
        XCTAssertEqual(try XCTUnwrap(observe(&short, playing: true, uptime: 1, position: 1, duration: 2)).heardSeconds, 1)
        _ = observe(&unknown, playing: true, uptime: 0, position: 0)
        XCTAssertNil(observe(&unknown, playing: true, uptime: 9, position: 9))
        XCTAssertNotNil(observe(&unknown, playing: true, uptime: 10, position: 10))
    }

    func testUnobservedGapAndClockRollbackDoNotInventListeningTime() throws {
        var recorder = ListeningHistoryRecorder()
        _ = observe(&recorder, playing: true, uptime: 0, position: 0)
        XCTAssertNil(observe(&recorder, playing: true, uptime: 120, position: 120))
        let valid = try XCTUnwrap(observe(&recorder, playing: false, uptime: 130, position: 130))
        XCTAssertEqual(valid.heardSeconds, 10)
        XCTAssertNil(observe(&recorder, playing: true, uptime: 100, position: 130))
        let fresh = try XCTUnwrap(observe(&recorder, playing: true, uptime: 110, position: 140))
        XCTAssertNotEqual(fresh.id, valid.id); XCTAssertEqual(fresh.heardSeconds, 10)
    }

    func testLongPauseStartsANewEpisodeAndInvalidObservationResetsPendingTime() throws {
        var recorder = ListeningHistoryRecorder()
        _ = observe(&recorder, playing: true, uptime: 0, position: 0)
        let first = try XCTUnwrap(observe(&recorder, playing: false, uptime: 10, position: 10))
        _ = observe(&recorder, playing: true, uptime: 1000, position: 10)
        let next = try XCTUnwrap(observe(&recorder, playing: true, uptime: 1010, position: 20))
        XCTAssertNotEqual(first.id, next.id)
        XCTAssertNil(observe(&recorder, playing: true, uptime: .nan, position: 20))
        XCTAssertNil(observe(&recorder, playing: true, uptime: 1011, position: 21))
    }

    func testRetentionPreservesHeardIndexAndExplicitClearKeepsBookmarksAndNotes() throws {
        var document = ListeningHistoryDocument()
        let old = event(1, date: now.addingTimeInterval(-181 * 86400))
        try document.record(old, now: old.lastHeardAt)
        try document.record(event(2), retention: .init(maximumEvents: 1), now: now)
        XCTAssertEqual(document.events.count, 1); XCTAssertTrue(document.hasHeard(md5: old.reference.md5))
        try document.saveBookmark(ListeningBookmark(reference: reference(), name: "Intro", position: 1))
        try document.setNote("Notiz", for: reference(subtune: nil), now: now)
        document.clearHistory()
        XCTAssertTrue(document.events.isEmpty); XCTAssertTrue(document.heardMD5s.isEmpty)
        XCTAssertEqual(document.bookmarks.count, 1); XCTAssertEqual(document.notes.count, 1)
        XCTAssertNoThrow(try document.validated())
    }

    func testUpdatingAnEpisodeKeepsItsIDAndRejectsRegressedOrReusedEvents() throws {
        var document = ListeningHistoryDocument(), original = event()
        try document.record(original, now: now)
        original.heardSeconds = 20; original.lastHeardAt = now.addingTimeInterval(10); original.lastPosition = 2
        try document.record(original, now: now.addingTimeInterval(10))
        XCTAssertEqual(document.events.count, 1); XCTAssertEqual(document.events[0].lastPosition, 2)
        let before = document
        original.heardSeconds = 1
        XCTAssertThrowsError(try document.record(original, now: now))
        XCTAssertEqual(document, before)
        let reused = ListeningHistoryEvent(id: original.id, reference: reference(2), title: "Other", startedAt: now,
            lastHeardAt: now, heardSeconds: 10, lastPosition: 0)
        XCTAssertThrowsError(try document.record(reused, now: now))
        XCTAssertEqual(document, before)
    }

    func testNotesFollowContentAcrossRootsButFileAndSubtuneNotesStaySeparate() throws {
        var document = ListeningHistoryDocument()
        let first = reference(subtune: nil), moved = reference(subtune: nil, library: "other-root", path: "Moved/Tune.sid")
        try document.setNote("Erste Zeile\nZweite Zeile 🎵", for: first, now: now)
        let id = try XCTUnwrap(document.note(for: first)).id
        try document.setNote("Geändert", for: moved, now: now)
        XCTAssertEqual(document.notes.count, 1); XCTAssertEqual(document.note(for: first)?.id, id)
        XCTAssertEqual(document.note(for: first)?.text, "Geändert")
        try document.setNote("Subtune", for: reference(), now: now)
        try document.setNote("Anderer Inhalt", for: reference(2, subtune: nil), now: now)
        XCTAssertEqual(document.notes.count, 3)
        try document.setNote(" \n ", for: moved, now: now)
        XCTAssertNil(document.note(for: first)); XCTAssertEqual(document.notes.count, 2)
        XCTAssertNoThrow(try document.validated())
    }

    func testBookmarksPreserveFractionalAndLongPositionsWithoutClaimingSeekSupport() throws {
        var document = ListeningHistoryDocument()
        var bookmark = ListeningBookmark(reference: reference(), name: "Refrain", position: 1500.125, updatedAt: now)
        try document.saveBookmark(bookmark)
        bookmark.name = "Refrain später"; bookmark.position = 1600.5
        try document.saveBookmark(bookmark)
        XCTAssertEqual(document.bookmarks, [bookmark])
        XCTAssertNoThrow(try document.validated())
        document.removeBookmark(bookmark.id); XCTAssertTrue(document.bookmarks.isEmpty)
    }

    func testInvalidIdentityAndNumbersDoNotChangePersonalData() throws {
        var document = ListeningHistoryDocument()
        try document.setNote("Erhalten", for: reference(), now: now)
        let before = document
        for bad in [reference(subtune: 256), reference(path: "../Tune.sid"),
                    ListeningPersonalReference(libraryID: "root", trackID: "Tune.sid", md5: "bad", subtune: 0)] {
            XCTAssertThrowsError(try document.saveBookmark(ListeningBookmark(reference: bad, name: "X", position: 0)))
        }
        for bad in [Double.nan, .infinity, -1] {
            XCTAssertThrowsError(try document.saveBookmark(ListeningBookmark(reference: reference(), name: "X", position: bad)))
        }
        XCTAssertThrowsError(try document.setNote(String(repeating: "x", count: 16_001), for: reference(), now: now))
        XCTAssertEqual(document, before)
    }

    func testRoundTripAndLargeEventSeriesKeepBoundedHistoryWithCompleteHeardIndex() throws {
        var document = ListeningHistoryDocument()
        for i in 1...1000 {
            try document.record(event(i, date: now.addingTimeInterval(Double(i))), retention: .init(maximumEvents: 20),
                now: now.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(document.events.count, 20); XCTAssertEqual(document.heardMD5s.count, 1000)
        XCTAssertTrue(document.hasHeard(md5: reference().md5)); XCTAssertEqual(document.events.first?.reference, reference(1000))
        let data = try JSONEncoder().encode(document.validated())
        XCTAssertEqual(try JSONDecoder().decode(ListeningHistoryDocument.self, from: data).validated(), document)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); raw["heardMD5s"] = []
        let broken = try JSONSerialization.data(withJSONObject: raw)
        XCTAssertThrowsError(try JSONDecoder().decode(ListeningHistoryDocument.self, from: broken).validated())
    }

    func testStoreRequiresLoadAndPreservesExternallyChangedFutureData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), store = ListeningHistoryStore(fileURL: url)
        do { try await store.save(.init()); XCTFail("Laden ist erforderlich") }
        catch { XCTAssertEqual(error as? ListeningHistoryError, .readOnly) }
        var document = try await store.load(); try document.record(event(), now: now)
        try await store.save(document)
        let restored = try await store.load(); XCTAssertEqual(restored, document)
        let future = Data("{\"version\":99}".utf8); try future.write(to: url)
        do { try await store.save(document); XCTFail("Fremde Änderung darf nicht überschrieben werden") }
        catch { XCTAssertEqual(error as? ListeningHistoryError, .externalChange) }
        XCTAssertEqual(try Data(contentsOf: url), future)
        do { _ = try await store.load(); XCTFail("Neue Version ist nicht lesbar") }
        catch { XCTAssertEqual(error as? ListeningHistoryError, .unsupportedVersion) }
        do { try await store.save(document); XCTFail("Schreibschutz muss erhalten bleiben") }
        catch { XCTAssertEqual(error as? ListeningHistoryError, .readOnly) }
        XCTAssertEqual(try Data(contentsOf: url), future)
    }

    func testStorePreservesAnExternalSameVersionEditUntilReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), store = ListeningHistoryStore(fileURL: url)
        var original = try await store.load(); try original.record(event(), now: now)
        try await store.save(original)
        var edited = original; try edited.setNote("Externe Notiz", for: reference(), now: now)
        let bytes = try JSONEncoder().encode(edited); try bytes.write(to: url)
        do { try await store.save(original); XCTFail("Externe Notiz muss erhalten bleiben") }
        catch { XCTAssertEqual(error as? ListeningHistoryError, .externalChange) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        var reloaded = try await store.load()
        try reloaded.saveBookmark(ListeningBookmark(reference: reference(), name: "Marke", position: 10))
        try await store.save(reloaded)
        let final = try await store.load()
        XCTAssertEqual(final.note(for: reference())?.text, "Externe Notiz")
        XCTAssertEqual(final.bookmarks.count, 1)
    }

    func testStoreRejectsDamagedAndOversizedDataWithoutReplacingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("history.json"), store = ListeningHistoryStore(fileURL: url)
        let damaged = Data("{broken".utf8); try damaged.write(to: url)
        do { _ = try await store.load(); XCTFail("Beschädigte Daten dürfen nicht gelesen werden") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ListeningHistoryStore.maximumFileBytes + 1)); try handle.close()
        do { _ = try await store.load(); XCTFail("Zu große Datei darf nicht gelesen werden") }
        catch { XCTAssertEqual(error as? ListeningHistoryError, .capacityExceeded) }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
                       ListeningHistoryStore.maximumFileBytes + 1)
    }
}
