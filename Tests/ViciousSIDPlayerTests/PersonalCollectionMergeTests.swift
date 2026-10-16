import XCTest
@testable import ViciousSIDPlayerCore

final class PersonalCollectionMergeTests: XCTestCase {
    private let md5 = String(repeating: "a", count: 32)
    private let other = String(repeating: "b", count: 32)
    private let now = Date(timeIntervalSince1970: 1_792_152_000.123)

    private func empty() -> PersonalCollectionSnapshot {
        .init(favorites: [], listening: .init(), history: .init(), playback: .init())
    }
    private func reference(_ path: String = "Old.sid", sub: Int? = 2) -> PersonalCollectionReference {
        .init(path: path, md5: md5, subtune: sub)
    }
    private func archive() -> PersonalCollectionDocument {
        var doc = PersonalCollectionDocument(name: "Source", createdAt: now)
        doc.favorites = [reference(sub: nil)]
        doc.lists = [.init(name: "Twice", entries: [.init(reference: reference()), .init(reference: reference())])]
        doc.bookmarks = [.init(reference: reference(), name: "Bridge", position: 1500.25, updatedAt: now)]
        doc.notes = [.init(reference: reference(sub: nil), text: "File note", updatedAt: now),
                     .init(reference: reference(), text: "Subtune note", updatedAt: now)]
        doc.endTimes = [.init(md5: md5, subtune: 2, seconds: 125.5)]
        return doc
    }
    private func resolver() throws -> PersonalCollectionResolver {
        try .init(tracks: [.init(path: "Moved.sid", md5: md5), .init(path: "Other.sid", md5: other)])
    }

    func testMovedCollectionRoundTripIsIdempotentAndLeavesRuntimeStateAlone() throws {
        let doc = try PersonalCollectionCodec.decode(PersonalCollectionCodec.encode(archive()))
        var target = empty()
        target.listening.queue = .init(libraryID: "target", name: "Runtime", entries: [.init(trackID: "Other.sid", subtune: 0)])
        target.playback.repeatMode = .sequence; target.playback.fadeOutSeconds = 7; target.playback.sleepMinutes = 45
        let merged = try PersonalCollectionMerge.preview(doc, into: target, libraryID: "target", resolver: resolver(), now: now)
        XCTAssertTrue(merged.hasChanges); XCTAssertTrue(merged.conflicts.isEmpty && merged.unresolved.isEmpty)
        XCTAssertEqual(merged.snapshot.favorites, ["Moved.sid"])
        XCTAssertEqual(merged.snapshot.listening.lists[0].entries.map(\.trackID), ["Moved.sid", "Moved.sid"])
        XCTAssertEqual(merged.snapshot.listening.lists[0].entries.map(\.id), doc.lists[0].entries.map(\.id))
        XCTAssertEqual(merged.snapshot.history.bookmarks[0].reference.subtune, 2)
        XCTAssertEqual(merged.snapshot.history.bookmarks[0].position, 1500.25)
        XCTAssertEqual(merged.snapshot.history.notes.count, 2)
        XCTAssertEqual(merged.snapshot.listening.queue, target.listening.queue)
        XCTAssertEqual(merged.snapshot.playback.repeatMode, .sequence)
        XCTAssertEqual(merged.snapshot.playback.fadeOutSeconds, 7)
        XCTAssertEqual(merged.snapshot.playback.sleepMinutes, 45)
        let again = try PersonalCollectionMerge.preview(doc, into: merged.snapshot, libraryID: "target", resolver: resolver(), now: now)
        XCTAssertEqual(again.snapshot, merged.snapshot); XCTAssertFalse(again.hasChanges)
        let exported = try PersonalCollectionExport.make(merged.snapshot, libraryID: "target", name: "New root", contents: ["Moved.sid": md5], now: now)
        XCTAssertNil(exported.document.history)
        XCTAssertTrue(exported.unverifiedReferences.isEmpty)
        XCTAssertEqual(exported.document.notes.map(\.text), ["File note", "Subtune note"])
        XCTAssertEqual(exported.document.lists[0].entries.map { $0.reference.path }, ["Moved.sid", "Moved.sid"])
    }

    func testConflictsKeepExistingUntilExplicitChoiceAndPreserveOtherCollections() throws {
        let doc = archive()
        var target = try PersonalCollectionMerge.preview(doc, into: empty(), libraryID: "target", resolver: resolver(), now: now).snapshot
        target.listening.lists[0].name = "Local list"
        target.listening.lists.append(.init(libraryID: "unrelated", name: "Do not touch"))
        try target.history.setNote("Local text", for: target.history.notes[1].reference)
        var changedBookmark = target.history.bookmarks[0]; changedBookmark.position = 1
        try target.history.saveBookmark(changedBookmark)
        try target.playback.setEndTime(99, md5: md5, subtune: 2)
        let preview = try PersonalCollectionMerge.preview(doc, into: target, libraryID: "target", resolver: resolver(), now: now)
        XCTAssertEqual(preview.conflicts.count, 4)
        XCTAssertEqual(preview.snapshot, target)
        let choices = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.id, PersonalCollectionMergeChoice.useImported) })
        let selected = try PersonalCollectionMerge.preview(doc, into: target, libraryID: "target", resolver: resolver(), choices: choices, now: now)
        XCTAssertEqual(selected.updates, 4)
        XCTAssertEqual(selected.snapshot.listening.lists[0].name, "Twice")
        XCTAssertEqual(selected.snapshot.listening.lists[1].name, "Do not touch")
        XCTAssertEqual(selected.snapshot.history.notes[1].text, "Subtune note")
        XCTAssertEqual(selected.snapshot.history.bookmarks[0].position, 1500.25)
        XCTAssertEqual(selected.snapshot.playback.endTime(md5: md5, subtune: 2), 125.5)
    }

    func testMissingReferencesStayPersonalButCannotBecomeWrongPathFavoritesOrListEntries() throws {
        var doc = archive()
        doc.favorites.append(.init(path: "Other.sid"))
        let missing = try PersonalCollectionResolver(tracks: [.init(path: "Old.sid", md5: other), .init(path: "Other.sid", md5: other)])
        let preview = try PersonalCollectionMerge.preview(doc, into: empty(), libraryID: "target", resolver: missing, now: now)
        XCTAssertTrue(preview.snapshot.favorites.isEmpty)
        XCTAssertTrue(preview.snapshot.listening.lists[0].entries.isEmpty)
        XCTAssertEqual(preview.skippedPathEntries, 4)
        XCTAssertEqual(preview.snapshot.history.bookmarks[0].reference.md5, md5)
        XCTAssertEqual(preview.snapshot.history.notes.count, 2)
        XCTAssertTrue(preview.unresolved.contains { $0.resolution == .changed })
        let accepted = try PersonalCollectionMerge.preview(doc, into: empty(), libraryID: "target", resolver: missing,
            acceptedPaths: [.init(path: "Other.sid")], now: now)
        XCTAssertEqual(accepted.snapshot.favorites, ["Other.sid"])
        XCTAssertEqual(accepted.skippedPathEntries, 3)
    }

    func testSubtuneFavoritesUnionAndCollidingNoteIDsRemainStable() throws {
        var target = empty()
        let occupied = UUID()
        target.listening.lists = [.init(libraryID: "target", name: "Favorites", entries: [.init(id: occupied, trackID: "Other.sid", subtune: 1)], kind: .subtuneFavorites)]
        let native = ListeningPersonalReference(libraryID: "target", trackID: "Other.sid", md5: other)
        target.history = try .init(events: [], heardMD5s: [], bookmarks: [], notes: [.init(id: occupied, reference: native, text: "Keep")])
        var doc = PersonalCollectionDocument(name: "Collision", createdAt: now)
        doc.lists = [.init(name: "Other favorites", kind: .subtuneFavorites, entries: [.init(id: occupied, reference: reference())])]
        doc.notes = [.init(id: occupied, reference: reference(sub: nil), text: "Imported", updatedAt: now)]
        let choices = ["note-id:\(occupied)": PersonalCollectionMergeChoice.useImported]
        let first = try PersonalCollectionMerge.preview(doc, into: target, libraryID: "target", resolver: resolver(), choices: choices, now: now)
        let repeatedPreview = try PersonalCollectionMerge.preview(doc, into: target, libraryID: "target", resolver: resolver(), choices: choices, now: now)
        XCTAssertEqual(first.snapshot, repeatedPreview.snapshot)
        XCTAssertEqual(first.snapshot.listening.lists.count, 1)
        XCTAssertEqual(first.snapshot.listening.lists[0].entries.count, 2)
        XCTAssertEqual(first.snapshot.history.notes.count, 2)
        let again = try PersonalCollectionMerge.preview(doc, into: first.snapshot, libraryID: "target", resolver: resolver(), now: now)
        XCTAssertEqual(again.snapshot, first.snapshot)
    }

    func testOptionalHistoryMergesEpisodesWithoutAddingHeardSecondsAndKeepsIndependentIndex() throws {
        var target = empty()
        let native = ListeningPersonalReference(libraryID: "target", trackID: "Moved.sid", md5: md5, subtune: 2)
        let event = ListeningHistoryEvent(reference: native, title: "Tune", startedAt: now, lastHeardAt: now.addingTimeInterval(10), heardSeconds: 10, lastPosition: 10)
        target.history = try .init(events: [event], heardMD5s: [md5, other], bookmarks: [], notes: [])
        var doc = PersonalCollectionDocument(name: "History", createdAt: now)
        doc.history = .init(events: [.init(id: event.id, reference: reference(), title: "Tune", startedAt: now,
            lastHeardAt: now.addingTimeInterval(20), heardSeconds: 20, lastPosition: 200)], heardMD5s: [md5])
        let roundTrip = try PersonalCollectionCodec.decode(PersonalCollectionCodec.encode(doc))
        let merged = try PersonalCollectionMerge.preview(roundTrip, into: target, libraryID: "target", resolver: resolver(), now: now)
        XCTAssertTrue(merged.conflicts.isEmpty)
        XCTAssertEqual(merged.snapshot.history.events[0].heardSeconds, 20)
        XCTAssertEqual(merged.snapshot.history.heardMD5s, [md5, other])
        let again = try PersonalCollectionMerge.preview(roundTrip, into: merged.snapshot, libraryID: "target", resolver: resolver(), now: now)
        XCTAssertEqual(again.snapshot, merged.snapshot)
        let exported = try PersonalCollectionExport.make(target, libraryID: "target", name: "History", contents: ["Moved.sid": md5], includeHistory: true, now: now)
        XCTAssertEqual(exported.document.history?.heardMD5s, [md5, other])
        let muchLater = now.addingTimeInterval(181 * 86400)
        let withoutHistory = try PersonalCollectionMerge.preview(PersonalCollectionDocument(name: "No history"), into: target,
            libraryID: "target", resolver: resolver(), now: muchLater)
        XCTAssertEqual(withoutHistory.snapshot.history, target.history)
        let pruned = try PersonalCollectionMerge.preview(roundTrip, into: target, libraryID: "target", resolver: resolver(), now: muchLater)
        XCTAssertTrue(pruned.snapshot.history.events.isEmpty)
        XCTAssertEqual(pruned.snapshot.history.heardMD5s, [md5, other])
    }

    func testUUIDFromAnotherCollectionCannotReplaceItsListAndEpisodeCollisionNeedsChoice() throws {
        var target = empty(), doc = archive()
        target.listening.lists = [.init(id: doc.lists[0].id, libraryID: "other-collection", name: "Protected")]
        let native = ListeningPersonalReference(libraryID: "target", trackID: "Moved.sid", md5: md5, subtune: 2)
        let event = ListeningHistoryEvent(reference: native, title: "Local episode", startedAt: now,
            lastHeardAt: now.addingTimeInterval(10), heardSeconds: 10, lastPosition: 10)
        target.history = try .init(events: [event], heardMD5s: [md5], bookmarks: [], notes: [])
        doc.history = .init(events: [.init(id: event.id, reference: reference(), title: "Other episode",
            startedAt: now.addingTimeInterval(-100), lastHeardAt: now.addingTimeInterval(20), heardSeconds: 20, lastPosition: 20)], heardMD5s: [md5])
        let preview = try PersonalCollectionMerge.preview(doc, into: target, libraryID: "target", resolver: resolver(), now: now)
        XCTAssertTrue(preview.conflicts.contains { !$0.canUseImported && $0.id.hasPrefix("list:") })
        XCTAssertTrue(preview.conflicts.contains { $0.id.hasPrefix("event:") })
        let choices = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.id, PersonalCollectionMergeChoice.useImported) })
        let selected = try PersonalCollectionMerge.preview(doc, into: target, libraryID: "target", resolver: resolver(), choices: choices, now: now)
        XCTAssertEqual(selected.snapshot.listening.lists[0], target.listening.lists[0])
        XCTAssertEqual(selected.snapshot.history.events[0].title, "Other episode")
        XCTAssertEqual(target.history.events[0].heardSeconds, 10)
    }

    func testLargeListKeepsAllEntryIdentitiesAndRepeatedImportAddsNothing() throws {
        let entries = (0..<50_001).map { PersonalCollectionEntry(reference: .init(path: "Composer/Tune\($0).sid", md5: md5, subtune: $0 % 3)) }
        let catalog = try PersonalCollectionResolver(tracks: entries.map { .init(path: $0.reference.path, md5: md5) })
        var doc = PersonalCollectionDocument(name: "Large", createdAt: now)
        doc.lists = [.init(name: "Large list", entries: entries)]
        let preview = try PersonalCollectionMerge.preview(doc, into: empty(), libraryID: "target", resolver: catalog, now: now)
        XCTAssertEqual(preview.snapshot.listening.lists[0].entries.map(\.id), entries.map(\.id))
        let again = try PersonalCollectionMerge.preview(doc, into: preview.snapshot, libraryID: "target", resolver: catalog, now: now)
        XCTAssertFalse(again.hasChanges)
        XCTAssertEqual(again.snapshot.listening.lists[0].entries.count, 50_001)
    }
}
