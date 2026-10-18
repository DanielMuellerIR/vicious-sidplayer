import XCTest
import AVFoundation
import ViciousSIDPlayerCore
@testable import ViciousSIDPlayer

@MainActor
final class ListeningIntegrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var models: [AppModel] = []
    private var suite = ""

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "vsp-listening-integration." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        for model in models {
            let estimate = model.lengthEstimateTask
            model.coordinator.stop(); model.stopPlaybackLoop(); model.cancelLengthEstimate()
            model.listening.flush(); model.savedSearches.flush(); model.playbackOptions.cancelSleepTimer(); model.playbackOptions.flush()
            await model.metadataIndex.suspend()
            await estimate?.value
            _ = await model.history.flush()
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
        await model.listening.ready()
        await model.playbackOptions.ready()
        await model.history.ready()
        XCTAssertTrue(model.listening.isLoaded && model.playbackOptions.isLoaded)
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
        await restored.listening.ready()
        await restored.playbackOptions.ready()
        XCTAssertTrue(restored.listening.isLoaded && restored.playbackOptions.isLoaded)
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

    func testBackgroundRefreshStillAdvancesSubtunesAndReturnsWithoutRestart() async throws {
        let model = try await makeModel()
        model.select(trackID: "Alpha/A.sid")
        model.currentTrackLengths = [0.3, 30, 30]
        model.autoNext = true
        model.setPlaybackViewVisible(true)
        model.coordinator.setVolume(0)
        model.coordinator.play(); defer { model.coordinator.stop() }
        try XCTSkipUnless(model.coordinator.isPlaying, "Kein nutzbares Audiogeraet")
        model.startPlaybackLoop()
        model.scenePhaseChanged(to: .background)
        for _ in 0..<40 where model.coordinator.currentSubtune == 0 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(model.isSceneActive)
        XCTAssertEqual(model.coordinator.currentSubtune, 1,
                       "Der eigene Auto-Next-Lauf muss bei langsamer UI weiterlaufen.")
        XCTAssertTrue(model.coordinator.isPlaying)
        model.scenePhaseChanged(to: .active)
        for _ in 0..<10 where model.coordinator.elapsedSeconds <= 0.2 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(model.isSceneActive)
        XCTAssertTrue(model.coordinator.isPlaying)
        XCTAssertEqual(model.coordinator.currentSubtune, 1)
        XCTAssertGreaterThan(model.coordinator.elapsedSeconds, 0.2)
    }

    func testPersonalDurationPrecedesHVSCAndStopsWhenAutoNextIsOff() async throws {
        let model = try await makeModel(); try await awaitMetadata(model)
        model.select(trackID: "Alpha/A.sid")
        model.currentTrackLengths = [30,40,50]
        let target = try XCTUnwrap(model.playbackEndTimeTarget)
        try model.playbackOptions.setEndTime("1:30", target: target)
        XCTAssertEqual(model.currentDuration, 90)
        model.searchText = "min:80 max:100"
        XCTAssertEqual(model.visibleTracks.map(\.id), ["Alpha/A.sid"])
        model.autoNext = false; model.coordinator.isPlaying = true
        model.handleConfiguredPlaybackEnd(elapsed: 90)
        XCTAssertFalse(model.coordinator.isPlaying)
        try model.playbackOptions.setEndTime("", target: target)
        XCTAssertEqual(model.currentDuration, 30)
    }

    func testPlayingSubtuneChangeCountsTheFirstNewObservationInterval() async throws {
        let model = try await makeModel()
        await model.history.ready()
        model.select(trackID: "Alpha/A.sid")
        model.currentTrackLengths = [2, 2, 2]
        model.coordinator.isPlaying = true
        let uptime = ProcessInfo.processInfo.systemUptime
        model.observeHistory(force: true, uptime: uptime)
        model.setSubtune(1)
        model.observeHistory(force: true, uptime: uptime + 1.25)
        XCTAssertEqual(model.history.document.events.last?.reference.subtune, 1)
        XCTAssertGreaterThan(model.history.document.events.last?.heardSeconds ?? 0, 1)
    }

    func testEndQueueClosesHistoryBeforeAnIdleInterval() async throws {
        let model = try await makeModel()
        await model.history.ready()
        model.select(trackID: "Alpha/A.sid")
        model.currentTrackLengths = [2, 2, 2]
        model.coordinator.isPlaying = true
        let uptime = ProcessInfo.processInfo.systemUptime
        model.observeHistory(force: true, uptime: uptime - 5)
        model.endListeningQueue()
        XCTAssertNil(model.listening.queue)
        XCTAssertFalse(model.coordinator.isPlaying)
        model.observeHistory(force: true, playing: true, uptime: uptime + 10)
        XCTAssertLessThan(model.history.document.events.map(\.heardSeconds).max() ?? 0, 5.5)
    }

    func testFileRepeatPreservesTheFixedEntryAndRestoresTheActualSubtune() async throws {
        let first = try await makeModel()
        let entry = ListeningEntry(trackID: "Alpha/A.sid", subtune: 2)
        first.listening.setQueue(ListeningQueue(libraryID: AppModel.listeningCollectionID, name: "Fixed", kind: .savedList, entries: [entry]))
        XCTAssertTrue(first.loadListeningEntry(entry, autoplay: false))
        first.playbackOptions.setRepeatMode(.file); first.coordinator.isPlaying = true
        first.handleConfiguredPlaybackEnd(elapsed: first.currentDuration)
        XCTAssertEqual(first.coordinator.currentSubtune, 0)
        XCTAssertEqual(first.listening.queue?.current?.subtune, 2)
        first.seek(to: 2); first.saveSessionState(); first.playbackOptions.flush(); first.listening.flush()
        let restored = try await makeModel(); restored.restoreSessionIfPossible()
        XCTAssertEqual(restored.coordinator.currentSubtune, 0)
        XCTAssertEqual(restored.listening.queue?.current?.subtune, 2)
        XCTAssertEqual(restored.coordinator.elapsedSeconds, 2, accuracy: 0.001)
        XCTAssertFalse(restored.coordinator.isPlaying)
    }

    func testSleepExpiryPreventsAutomaticInterruptionResume() async throws {
        let model = try await makeModel(); model.select(trackID: "Alpha/A.sid")
        model.configureSystemPlayback(); model.coordinator.isPlaying = true
        try model.playbackOptions.startSleepTimer(seconds: 0.05)
        for _ in 0..<150 where !model.playbackOptions.didExpire { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(model.playbackOptions.didExpire); XCTAssertFalse(model.coordinator.isPlaying)
        model.services.audioSession.resumeHandler?()
        XCTAssertFalse(model.coordinator.isPlaying)
        model.togglePlayPause()
        XCTAssertFalse(model.playbackOptions.didExpire)
        XCTAssertTrue(model.coordinator.isPlaying)
        try model.playbackOptions.startSleepTimer(seconds: 0.05)
        for _ in 0..<150 where !model.playbackOptions.didExpire { try await Task.sleep(nanoseconds: 20_000_000) }
        let entry = try XCTUnwrap(model.listening.queue?.items.last)
        model.selectListeningEntry(entry.id)
        XCTAssertFalse(model.playbackOptions.didExpire)
        XCTAssertTrue(model.coordinator.isPlaying)
        XCTAssertEqual(model.currentTrackID, entry.trackID)
    }

    func testMissingHeaderTitleUsesTheFilenameInPlayback() async throws {
        let model = try await makeModel()
        let url = try XCTUnwrap(model.trackURL(for: "B.sid"))
        var data = try Data(contentsOf: url)
        data.replaceSubrange(22..<54, with: repeatElement(UInt8(0), count: 32))
        try data.write(to: url)
        model.select(trackID: "B.sid")
        XCTAssertEqual(model.coordinator.trackName, "B")
        XCTAssertFalse(model.coordinator.isPlaying)
    }

    func testForegroundRefreshPreservesRunningPlayback() async throws {
        let model = try await makeModel(); model.select(trackID: "Alpha/A.sid")
        model.configureSystemPlayback()
        model.togglePlayPause(); model.cancelLengthEstimate()
        XCTAssertTrue(model.coordinator.isPlaying)
        let engineGeneration = model.coordinator.audioEngineGeneration
        for _ in 0..<3 {
            model.scenePhaseChanged(to: .inactive)
            model.scenePhaseChanged(to: .background)
            model.scenePhaseChanged(to: .active)
            await model.services.libraryReloadTask?.value
            XCTAssertEqual(model.currentTrackID, "Alpha/A.sid")
            XCTAssertTrue(model.coordinator.isPlaying)
            XCTAssertEqual(model.coordinator.audioEngineGeneration, engineGeneration)
        }
    }

    func testUnknownLoopAdvancesThroughTheBackgroundPlaybackTimer() async throws {
        let model = try await makeModel()
        let url = try XCTUnwrap(model.trackURL(for: "Alpha/A.sid"))
        var data = try Data(contentsOf: url); data[14] = 0; data[15] = 1
        try data.write(to: url)
        model.select(trackID: "Alpha/A.sid"); model.cancelLengthEstimate()
        XCTAssertEqual(model.currentDuration, 360)
        XCTAssertTrue(model.autoNext)
        model.configureSystemPlayback()
        model.togglePlayPause()
        model.scenePhaseChanged(to: .background)
        // Die UI-Zeitspiegelung darf den eingespeisten Endzeitpunkt nicht
        // überschreiben. Audio und der echte 1-Hz-Abschlusslauf bleiben aktiv.
        model.coordinator.setUIUpdateInterval(120)
        model.coordinator.elapsedSeconds = 360
        let deadline = Date().addingTimeInterval(6)
        while model.currentTrackID == "Alpha/A.sid", Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(model.currentTrackID, "B.sid", "Zeit \(model.coordinator.elapsedSeconds), Timer \(model.services.playbackLoop != nil)")
        XCTAssertTrue(model.coordinator.isPlaying)
        model.scenePhaseChanged(to: .active)
        await model.services.libraryReloadTask?.value
        XCTAssertEqual(model.currentTrackID, "B.sid")
        XCTAssertTrue(model.coordinator.isPlaying)
    }

    func testAutomaticPlaybackContinuesAcrossFourTrackEndsAndForegroundRefresh() async throws {
        let model = try await makeModel()
        for id in ["Alpha/A.sid", "B.sid", "C.sid"] {
            let url = try XCTUnwrap(model.trackURL(for: id))
            var data = try Data(contentsOf: url); data[14] = 0; data[15] = 1
            try data.write(to: url)
            let target = PlaybackEndTimeTarget(md5: SonglengthDB.md5Hex(of: data), subtune: 0, title: id)
            try model.playbackOptions.setEndTime("1.2", target: target)
        }
        model.configureSystemPlayback()
        model.select(trackID: "Alpha/A.sid"); model.togglePlayPause()
        model.scenePhaseChanged(to: .background)
        for expected in ["B.sid", "C.sid", "Alpha/A.sid", "B.sid"] {
            let oldID = model.currentTrackID
            let deadline = Date().addingTimeInterval(6)
            while model.currentTrackID == oldID, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertEqual(model.currentTrackID, expected,
                "Zeit \(model.coordinator.elapsedSeconds), spielt \(model.coordinator.isPlaying), Timer \(model.services.playbackLoop != nil), Fehler \(model.errorMessage ?? "—")")
            XCTAssertTrue(model.coordinator.isPlaying)
            XCTAssertNotNil(model.services.playbackLoop)
            if expected == "B.sid" {
                model.scenePhaseChanged(to: .active)
                await model.services.libraryReloadTask?.value
            }
        }
    }

    func testAutomaticSubtunesContinueIntoTheRemainingLibrary() async throws {
        let model = try await makeModel()
        model.configureSystemPlayback()
        for id in ["Alpha/A.sid", "B.sid", "C.sid"] {
            let url = try XCTUnwrap(model.trackURL(for: id))
            let data = try Data(contentsOf: url)
            for sub in 0..<3 {
                try model.playbackOptions.setEndTime("1.2", target: PlaybackEndTimeTarget(
                    md5: SonglengthDB.md5Hex(of: data), subtune: sub, title: id))
            }
        }
        model.select(trackID: "Alpha/A.sid"); model.togglePlayPause()
        model.scenePhaseChanged(to: .background)
        for expected in [("Alpha/A.sid", 1), ("Alpha/A.sid", 2), ("B.sid", 0), ("B.sid", 1)] {
            let oldID = model.currentTrackID, oldSubtune = model.coordinator.currentSubtune
            let deadline = Date().addingTimeInterval(6)
            while model.currentTrackID == oldID && model.coordinator.currentSubtune == oldSubtune && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertEqual(model.currentTrackID, expected.0)
            XCTAssertEqual(model.coordinator.currentSubtune, expected.1)
            XCTAssertTrue(model.coordinator.isPlaying)
            XCTAssertNotNil(model.services.playbackLoop)
            if expected.1 == 1 {
                model.scenePhaseChanged(to: .active)
                await model.services.libraryReloadTask?.value
            }
        }
    }

    func testShuffledLibraryKeepsAdvancingAfterForegroundRefresh() async throws {
        let model = try await makeModel()
        model.configureSystemPlayback()
        for id in ["Alpha/A.sid", "B.sid", "C.sid"] {
            let url = try XCTUnwrap(model.trackURL(for: id))
            var data = try Data(contentsOf: url); data[14] = 0; data[15] = 1
            try data.write(to: url)
            try model.playbackOptions.setEndTime("1.2", target: PlaybackEndTimeTarget(
                md5: SonglengthDB.md5Hex(of: data), subtune: 0, title: id))
        }
        model.shuffle = true
        model.select(trackID: "Alpha/A.sid"); model.togglePlayPause()
        model.scenePhaseChanged(to: .background)
        var observed = [try XCTUnwrap(model.currentTrackID)]
        for step in 0..<5 {
            let oldID = model.currentTrackID, deadline = Date().addingTimeInterval(6)
            while model.currentTrackID == oldID, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            let newID = try XCTUnwrap(model.currentTrackID)
            XCTAssertNotEqual(newID, oldID)
            observed.append(newID)
            XCTAssertTrue(model.coordinator.isPlaying)
            XCTAssertNotNil(model.services.playbackLoop)
            if step == 0 {
                model.scenePhaseChanged(to: .active)
                await model.services.libraryReloadTask?.value
            }
        }
        XCTAssertEqual(Set(observed.prefix(3)), Set(["Alpha/A.sid", "B.sid", "C.sid"]))
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                                                   AVAudioSessionInterruptionOptionKey: shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0])
    }

    func testRemotePauseDuringInterruptionPreventsAutomaticResume() async throws {
        let model = try await makeModel(); model.select(trackID: "Alpha/A.sid")
        model.configureSystemPlayback(); model.coordinator.isPlaying = true
        var resumes = 0
        model.services.audioSession.resumeHandler = { resumes += 1 }
        postInterruption(.began)
        XCTAssertFalse(model.coordinator.isPlaying)
        model.services.nowPlaying.pauseHandler?()
        postInterruption(.ended, shouldResume: true)
        XCTAssertEqual(resumes, 0, "Ein ausdrücklicher Pause-Befehl während der Unterbrechung hat Vorrang.")
        XCTAssertFalse(model.coordinator.isPlaying)
    }

    func testPreparedReplacementDuringInterruptionDoesNotAutoplay() async throws {
        let model = try await makeModel(); model.select(trackID: "Alpha/A.sid")
        model.configureSystemPlayback(); model.coordinator.isPlaying = true
        var resumes = 0
        model.services.audioSession.resumeHandler = { resumes += 1 }
        postInterruption(.began)
        model.select(trackID: "B.sid")
        XCTAssertEqual(model.currentTrackID, "B.sid")
        XCTAssertFalse(model.coordinator.isPlaying)
        postInterruption(.ended, shouldResume: true)
        XCTAssertEqual(resumes, 0, "Ein nur vorbereiteter neuer Titel darf nicht vom alten Anruf-Merker starten.")
    }

    func testInterruptedPlaybackResumesOnlyOnceWhenSystemAllows() async throws {
        let model = try await makeModel(); model.select(trackID: "Alpha/A.sid")
        model.configureSystemPlayback(); model.coordinator.isPlaying = true
        var resumes = 0
        model.services.audioSession.resumeHandler = { resumes += 1 }
        postInterruption(.began)
        XCTAssertFalse(model.coordinator.isPlaying)
        postInterruption(.ended, shouldResume: true)
        XCTAssertEqual(resumes, 1)
        postInterruption(.ended, shouldResume: true)
        XCTAssertEqual(resumes, 1)
    }

    func testInterruptionWithoutPermissionAndAlreadyPausedPlaybackStayPaused() async throws {
        let model = try await makeModel(); model.select(trackID: "Alpha/A.sid")
        model.configureSystemPlayback(); model.coordinator.isPlaying = true
        var resumes = 0
        model.services.audioSession.resumeHandler = { resumes += 1 }
        postInterruption(.began)
        postInterruption(.ended)
        XCTAssertEqual(resumes, 0)
        postInterruption(.began)
        postInterruption(.ended, shouldResume: true)
        XCTAssertEqual(resumes, 0)
    }

    func testHeadphoneRemovalCancelsPendingInterruptionResume() async throws {
        let model = try await makeModel(); model.select(trackID: "Alpha/A.sid")
        model.configureSystemPlayback(); model.coordinator.isPlaying = true
        var resumes = 0
        model.services.audioSession.resumeHandler = { resumes += 1 }
        postInterruption(.began)
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        postInterruption(.ended, shouldResume: true)
        XCTAssertEqual(resumes, 0)
    }

    func testInvalidReplacementDuringInterruptionKeepsResumePermission() async throws {
        let model = try await makeModel(); model.select(trackID: "Alpha/A.sid")
        model.configureSystemPlayback(); model.coordinator.isPlaying = true
        var resumes = 0
        model.services.audioSession.resumeHandler = { resumes += 1 }
        postInterruption(.began)
        model.select(trackID: "missing.sid")
        XCTAssertFalse(model.loadTrack(id: "B.sid", autoplay: false, subtune: 99))
        let corrupt = try XCTUnwrap(model.trackURL(for: "C.sid"))
        try Data([1, 2, 3]).write(to: corrupt)
        model.select(trackID: "C.sid")
        XCTAssertEqual(model.currentTrackID, "Alpha/A.sid")
        postInterruption(.ended, shouldResume: true)
        XCTAssertEqual(resumes, 1)
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
