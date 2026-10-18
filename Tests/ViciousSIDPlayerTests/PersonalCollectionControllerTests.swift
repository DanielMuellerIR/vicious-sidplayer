#if canImport(Combine)
import XCTest
@testable import ViciousSIDPlayerCore

@MainActor
final class PersonalCollectionControllerTests: XCTestCase {
    @MainActor
    private final class Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let suite = UUID().uuidString
        let listening: ListeningLibraryController
        let history: ListeningHistoryController
        let playback: PlaybackOptionsController
        let favorites: PersonalCollectionFavoritesStore
        let library: MusicLibrary
        let md5: String
        var isPlaying = true
        var resumes = 0
        var expireDuringPause = false
        var onCatalogRead: (() -> Void)?
        lazy var transfer = PersonalCollectionController(listening: listening, history: history, playback: playback,
            favorites: favorites, supportURL: root.appendingPathComponent("Support"),
            context: { [weak self] in
                guard let self else { throw PersonalCollectionImportError.unavailable }
                self.onCatalogRead?()
                return .init(libraryID: "target", name: "Target collection", library: self.library)
            }, pause: { [weak self] in
                guard let self else { return false }
                let wasPlaying = self.isPlaying; self.isPlaying = false
                if self.expireDuringPause { try? self.playback.startSleepTimer(seconds: 0.000001) }
                return wasPlaying
            }, resume: { [weak self] in self?.isPlaying = true; self?.resumes += 1 }, didApply: {})

        init(protectedHistory: Bool = false) throws {
            defaults = UserDefaults(suiteName: suite)!
            favorites = PersonalCollectionFavoritesStore(defaults: defaults, key: "favorites")
            let support = root.appendingPathComponent("Support"), music = root.appendingPathComponent("Music")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
            var bytes = Data(repeating: 0, count: 0x7C)
            bytes.replaceSubrange(0..<4, with: Array("PSID".utf8))
            for (offset, value) in [(4, 2), (6, 0x7C), (8, 0x1000), (10, 0x1000), (12, 0x100B), (14, 3), (16, 1)] {
                bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(value & 255)
            }
            bytes.append(contentsOf: [0x60, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA, 0x60])
            try bytes.write(to: music.appendingPathComponent("Moved.sid")); md5 = SonglengthDB.md5Hex(of: bytes)
            library = MusicLibrary(root: music, supportDirectory: support)
            if protectedHistory { try Data("{\"version\":99}".utf8).write(to: support.appendingPathComponent(ListeningHistoryStore.fileName)) }
            listening = ListeningLibraryController(fileURL: support.appendingPathComponent(ListeningLibraryStore.fileName))
            history = ListeningHistoryController(fileURL: support.appendingPathComponent(ListeningHistoryStore.fileName))
            playback = PlaybackOptionsController(fileURL: support.appendingPathComponent(PlaybackSettingsStore.fileName))
        }
        func close() async {
            playback.cancelSleepTimer(); listening.flush(); playback.flush(); _ = await history.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func ready() async {
            await transfer.ready()
            listening.activateLibrary("target", tracks: [.init(trackID: "Moved.sid")])
        }
        func importURL(favoritesOnly: Bool = false) throws -> URL {
            let ref = PersonalCollectionReference(path: "Old.sid", md5: md5, subtune: 2)
            var doc = PersonalCollectionDocument(name: "Source")
            doc.favorites = [.init(path: ref.path, md5: md5)]
            if !favoritesOnly {
                doc.lists = [.init(name: "Imported list", entries: [.init(reference: ref)])]
                doc.notes = [.init(reference: ref, text: "Imported note")]
                doc.endTimes = [.init(md5: md5, subtune: 2, seconds: 125.5)]
            }
            let url = root.appendingPathComponent("transfer.vicious-collection.json")
            try PersonalCollectionCodec.encode(doc).write(to: url)
            return url
        }
    }

    func testApplyAdoptsAllSelectedStoresPreservesTransportAndRejectsStaleScheduledSaves() async throws {
        let h = try Harness(); await h.ready()
        let queue = ListeningQueue(libraryID: "target", name: "Runtime", entries: [.init(trackID: "Moved.sid", subtune: 0)])
        h.listening.setQueue(queue); h.playback.setRepeatMode(.file); h.playback.setFadeOutSeconds(3)
        try h.playback.startSleepTimer(seconds: 60)
        try h.playback.setEndTime("99", target: .init(md5: h.md5, subtune: 2, title: "Tune"))
        let url = try h.importURL(); await h.transfer.readImport(from: url)
        let conflict = try XCTUnwrap(h.transfer.preview?.conflicts.first)
        XCTAssertEqual(conflict.existingValue, "1:39"); XCTAssertEqual(conflict.importedValue, "125.5")
        await h.transfer.choose(.useImported, for: conflict.id)
        XCTAssertTrue(h.transfer.canApply)
        await h.transfer.apply()
        XCTAssertNil(h.transfer.error); XCTAssertNotNil(h.transfer.completion)
        XCTAssertEqual(h.favorites.read(), ["Moved.sid"])
        XCTAssertEqual(h.listening.document.queue, queue)
        XCTAssertEqual(h.listening.activeLists.count, 1)
        XCTAssertEqual(h.listening.document.lists.first?.name, "Imported list")
        XCTAssertEqual(h.history.document.notes.first?.text, "Imported note")
        XCTAssertEqual(h.playback.document.endTime(md5: h.md5, subtune: 2), 125.5)
        XCTAssertEqual(h.playback.document.repeatMode, .file); XCTAssertEqual(h.playback.document.fadeOutSeconds, 3)
        XCTAssertTrue(h.playback.hasSleepTimer); XCTAssertTrue(h.isPlaying); XCTAssertEqual(h.resumes, 1)
        try await Task.sleep(for: .milliseconds(400))
        let store = PlaybackSettingsStore(fileURL: h.root.appendingPathComponent("Support/" + PlaybackSettingsStore.fileName))
        XCTAssertEqual(try store.load().endTime(md5: h.md5, subtune: 2), 125.5)
        await h.transfer.readImport(from: url)
        XCTAssertFalse(h.transfer.canApply)
        await h.close()
    }

    func testAuditRepairCommitsSelectedReferencesAndRestoresPlaybackWithOriginalFilesIntact() async throws {
        let h = try Harness(); await h.ready()
        let reference = ListeningPersonalReference(libraryID: "target", trackID: "Old.sid", md5: h.md5, subtune: 2)
        h.history.saveBookmark(reference: reference, title: "Keep mark", position: 1.25)
        h.history.setNote("Keep note", for: reference)
        let listID = try XCTUnwrap(h.listening.createList(name: "Keep order", entries: [.init(trackID: "Old.sid", subtune: 2)]))
        try h.favorites.replace([], with: ["Old.sid"])
        let inventory = h.root.appendingPathComponent("Support/audit-" + h.library.indexFileName)
        try JSONSerialization.data(withJSONObject: ["version": 1, "contents": ["Old.sid": h.md5]]).write(to: inventory)
        let queue = ListeningQueue(libraryID: "target", name: "Runtime", entries: [.init(trackID: "Moved.sid", subtune: 0)])
        h.listening.setQueue(queue)
        let music = try Data(contentsOf: h.library.root.appendingPathComponent("Moved.sid"))
        h.transfer.startAudit()
        for _ in 0..<500 where h.transfer.isAuditing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(h.transfer.isAuditing)
        let report = try XCTUnwrap(h.transfer.auditReport)
        XCTAssertEqual(report.repairs.count, 2)
        XCTAssertEqual(h.favorites.read(), ["Old.sid"])
        for issue in report.repairs { h.transfer.selectAuditRepair(issue.id, enabled: true) }
        await h.transfer.applyAuditRepairs()
        XCTAssertNil(h.transfer.error); XCTAssertNotNil(h.transfer.completion)
        XCTAssertEqual(h.favorites.read(), ["Moved.sid"])
        XCTAssertEqual(h.listening.document.lists.first { $0.id == listID }?.entries.first?.trackID, "Moved.sid")
        XCTAssertEqual(h.history.document.bookmarks[0].reference.trackID, "Moved.sid")
        XCTAssertEqual(h.history.document.bookmarks[0].position, 1.25)
        XCTAssertEqual(h.history.document.notes[0].text, "Keep note")
        XCTAssertEqual(h.listening.document.queue, queue); XCTAssertTrue(h.isPlaying); XCTAssertEqual(h.resumes, 1)
        XCTAssertEqual(try Data(contentsOf: h.library.root.appendingPathComponent("Moved.sid")), music)
        await h.close()
    }

    func testAuditRepairRejectsChangedMusicWithoutSuspendingStoresOrPlayback() async throws {
        let h = try Harness(); await h.ready()
        let reference = ListeningPersonalReference(libraryID: "target", trackID: "Old.sid", md5: h.md5, subtune: 2)
        h.history.setNote("Keep note", for: reference)
        h.transfer.startAudit()
        for _ in 0..<500 where h.transfer.isAuditing { try await Task.sleep(for: .milliseconds(10)) }
        let report = try XCTUnwrap(h.transfer.auditReport)
        for issue in report.repairs { h.transfer.selectAuditRepair(issue.id, enabled: true) }
        try Data([1, 2, 3]).write(to: h.library.root.appendingPathComponent("Moved.sid"))
        await h.transfer.applyAuditRepairs()
        XCTAssertNotNil(h.transfer.error); XCTAssertNil(h.transfer.completion)
        XCTAssertEqual(h.history.document.notes[0].reference.trackID, "Old.sid")
        XCTAssertTrue(h.isPlaying); XCTAssertEqual(h.resumes, 0)
        await h.close()
    }

    func testTimerExpiryDuringImportIsNotAcknowledgedOrResumed() async throws {
        let h = try Harness(); await h.ready(); h.expireDuringPause = true
        await h.transfer.readImport(from: try h.importURL())
        await h.transfer.apply()
        XCTAssertNil(h.transfer.error); XCTAssertTrue(h.playback.didExpire)
        XCTAssertFalse(h.isPlaying); XCTAssertEqual(h.resumes, 0)
        await h.close()
    }

    func testProtectedUnselectedHistoryDoesNotPreventFavoritesOnlyImport() async throws {
        let h = try Harness(protectedHistory: true); await h.ready()
        let url = h.root.appendingPathComponent("Support/" + ListeningHistoryStore.fileName), before = try Data(contentsOf: url)
        await h.transfer.readImport(from: try h.importURL(favoritesOnly: true))
        XCTAssertEqual(h.transfer.areas, [.favorites]); XCTAssertTrue(h.transfer.canApply)
        await h.transfer.apply()
        XCTAssertNil(h.transfer.error); XCTAssertEqual(h.favorites.read(), ["Moved.sid"])
        XCTAssertEqual(try Data(contentsOf: url), before)
        await h.close()
    }

    func testExternalChangeAfterPreviewSurvivesFlushWithoutPublishingImportedData() async throws {
        let h = try Harness(); await h.ready()
        await h.transfer.readImport(from: try h.importURL())
        let url = h.root.appendingPathComponent("Support/" + ListeningLibraryStore.fileName), bytes = Data("{\"version\":99}".utf8)
        try bytes.write(to: url)
        await h.transfer.apply()
        XCTAssertNotNil(h.transfer.error); XCTAssertNil(h.transfer.completion)
        XCTAssertTrue(h.listening.isReadOnly); XCTAssertTrue(h.listening.document.lists.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), bytes); XCTAssertTrue(h.favorites.read().isEmpty)
        await h.close()
    }

    func testChangedMusicBytesAfterPreviewPreventThePauseAndAllPersonalChanges() async throws {
        let h = try Harness(); await h.ready()
        await h.transfer.readImport(from: try h.importURL())
        XCTAssertTrue(h.transfer.canApply)
        let url = h.library.root.appendingPathComponent("Moved.sid")
        try Data("Externally replaced music".utf8).write(to: url)
        let before = h.listening.document
        await h.transfer.apply()
        XCTAssertNotNil(h.transfer.error); XCTAssertNil(h.transfer.completion)
        XCTAssertTrue(h.isPlaying); XCTAssertEqual(h.resumes, 0)
        XCTAssertEqual(h.listening.document, before); XCTAssertTrue(h.favorites.read().isEmpty)
        XCTAssertTrue(h.history.document.notes.isEmpty); XCTAssertTrue(h.playback.document.endTimes.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("Externally replaced music".utf8))
        await h.close()
    }

    func testPathTrustRemainsVisibleAndCanBeRevokedBeforeImport() async throws {
        let h = try Harness(); await h.ready()
        let reference = PersonalCollectionReference(path: "Moved.sid")
        var document = PersonalCollectionDocument(name: "Without content proof")
        document.favorites = [reference]
        let url = h.root.appendingPathComponent("unverified.json")
        try PersonalCollectionCodec.encode(document).write(to: url)
        await h.transfer.readImport(from: url)
        XCTAssertFalse(h.transfer.canApply); XCTAssertEqual(h.transfer.preview?.skippedPathEntries, 1)
        await h.transfer.acceptPath(reference, enabled: true)
        XCTAssertTrue(h.transfer.canApply); XCTAssertEqual(h.transfer.preview?.skippedPathEntries, 0)
        XCTAssertEqual(h.transfer.preview?.unresolved.map(\.reference), [reference])
        await h.transfer.acceptPath(reference, enabled: false)
        XCTAssertFalse(h.transfer.canApply); XCTAssertEqual(h.transfer.preview?.skippedPathEntries, 1)
        XCTAssertTrue(h.favorites.read().isEmpty)
        await h.transfer.acceptPath(reference, enabled: true)
        await h.transfer.apply()
        XCTAssertNil(h.transfer.error); XCTAssertEqual(h.favorites.read(), ["Moved.sid"])
        await h.close()
    }

    func testClosingPreviewDuringTheFinalCatalogCheckCancelsWithoutPausingOrWriting() async throws {
        let h = try Harness(); await h.ready()
        await h.transfer.readImport(from: try h.importURL())
        XCTAssertTrue(h.transfer.canApply)
        h.onCatalogRead = { [weak h] in
            h?.onCatalogRead = nil
            h?.transfer.reset()
        }
        await h.transfer.apply()
        XCTAssertTrue(h.favorites.read().isEmpty)
        XCTAssertTrue(h.listening.document.lists.isEmpty)
        XCTAssertTrue(h.history.document.notes.isEmpty)
        XCTAssertTrue(h.playback.document.endTimes.isEmpty)
        XCTAssertTrue(h.isPlaying); XCTAssertEqual(h.resumes, 0)
        XCTAssertNil(h.transfer.completion); XCTAssertNil(h.transfer.error)
        await h.close()
    }

    func testRefreshingAgainstChangedPersonalValuesClearsTheOldConflictChoice() async throws {
        let h = try Harness(); await h.ready()
        let target = PlaybackEndTimeTarget(md5: h.md5, subtune: 2, title: "Tune")
        try h.playback.setEndTime("99", target: target)
        await h.transfer.readImport(from: try h.importURL())
        let conflict = try XCTUnwrap(h.transfer.preview?.conflicts.first)
        await h.transfer.choose(.useImported, for: conflict.id)
        XCTAssertEqual(h.transfer.preview?.snapshot.playback.endTime(md5: h.md5, subtune: 2), 125.5)
        try h.playback.setEndTime("88", target: target)
        await h.transfer.refreshPreview()
        XCTAssertTrue(h.transfer.choices.isEmpty)
        XCTAssertEqual(h.transfer.preview?.snapshot.playback.endTime(md5: h.md5, subtune: 2), 88)
        XCTAssertEqual(h.transfer.preview?.conflicts.first?.existingValue, "1:28")
        await h.close()
    }

    func testHistoryRequiresExplicitSelectionAndRepeatedImportKeepsOneEpisode() async throws {
        let h = try Harness(); await h.ready()
        let url = try h.importURL(favoritesOnly: true)
        var document = try PersonalCollectionCodec.decode(Data(contentsOf: url))
        let now = Date()
        document.history = .init(events: [.init(reference: .init(path: "Old.sid", md5: h.md5, subtune: 2),
            title: "Imported episode", startedAt: now.addingTimeInterval(-25), lastHeardAt: now,
            heardSeconds: 25, lastPosition: 55.25)], heardMD5s: [h.md5])
        try PersonalCollectionCodec.encode(document).write(to: url)
        await h.transfer.readImport(from: url)
        XCTAssertFalse(h.transfer.areas.contains(.history))
        await h.transfer.apply()
        XCTAssertNil(h.transfer.error); XCTAssertTrue(h.history.document.events.isEmpty)
        XCTAssertTrue(h.history.document.heardMD5s.isEmpty)
        await h.transfer.readImport(from: url)
        await h.transfer.select(.history, enabled: true)
        await h.transfer.apply()
        XCTAssertNil(h.transfer.error); XCTAssertEqual(h.history.document.events.count, 1)
        XCTAssertEqual(h.history.document.events.first?.reference.trackID, "Moved.sid")
        XCTAssertEqual(h.history.document.events.first?.heardSeconds, 25)
        XCTAssertEqual(h.history.document.heardMD5s, [h.md5])
        await h.transfer.readImport(from: url)
        await h.transfer.select(.history, enabled: true)
        XCTAssertFalse(h.transfer.canApply)
        XCTAssertEqual(h.history.document.events.count, 1)
        await h.close()
    }

    func testStartupFinishesCommittedImportBeforeAnyControllerLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = PersonalCollectionFavoritesStore(defaults: defaults, key: "favorites")
        let transaction = PersonalCollectionTransaction(supportURL: root)
        let lists = ListeningLibraryDocument(lists: [.init(libraryID: "target", name: "Recovered")])
        try transaction.prepare([.init(file: .listeningLibrary, expected: nil, replacement: JSONEncoder().encode(lists))], oldFavorites: [], newFavorites: ["Recovered.sid"])
        _ = try transaction.commit(currentFavorites: [])
        let startup = PersonalCollectionStartup(supportURL: root, favorites: favorites)
        let listening = ListeningLibraryController(fileURL: root.appendingPathComponent(ListeningLibraryStore.fileName), startup: startup)
        let history = ListeningHistoryController(fileURL: root.appendingPathComponent(ListeningHistoryStore.fileName), startup: startup)
        let playback = PlaybackOptionsController(fileURL: root.appendingPathComponent(PlaybackSettingsStore.fileName), startup: startup)
        await listening.ready(); await history.ready(); await playback.ready()
        XCTAssertEqual(listening.document, lists); XCTAssertEqual(favorites.read(), ["Recovered.sid"])
        XCTAssertFalse(listening.isReadOnly || history.isReadOnly || playback.isReadOnly)
        XCTAssertEqual(try transaction.recover(currentFavorites: favorites.read()), .none)
    }
}
#endif
