import XCTest
import AVFoundation
import ViciousSIDPlayerCore
@testable import ViciousSIDPlayer

@MainActor
final class ListeningHistoryIntegrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var models: [AppModel] = []
    private let suite = "vsp-history-integration"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func fixture() -> Data {
        var data = Data(repeating: 0, count: 0x7C)
        data.replaceSubrange(0..<4, with: Array("PSID".utf8))
        func word(_ offset: Int, _ value: Int) { data[offset] = UInt8(value >> 8); data[offset + 1] = UInt8(value & 255) }
        word(4, 2); word(6, 0x7C); word(8, 0x1000); word(10, 0x1000); word(12, 0x1001); word(14, 3); word(16, 1)
        data.replaceSubrange(0x16..<0x1A, with: Array("Tune".utf8))
        data.append(contentsOf: [0x60, 0x60])
        return data
    }
    private func makeModel() async throws -> AppModel {
        let root = directory.appendingPathComponent("Documents"), support = directory.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try fixture().write(to: root.appendingPathComponent("Tune.sid"))
        let library = MusicLibrary(root: root, supportDirectory: support)
        _ = try library.refresh()
        let model = AppModel(defaults: defaults, listeningFileURL: support.appendingPathComponent(ListeningLibraryStore.fileName))
        model.services = PlayerServices(library: library)
        model.applyLibrary(tracks: library.entries.map { LibraryTrack(id: $0.id, name: $0.displayName, folderPath: $0.folderPath) }, folderTree: MusicLibrary.folderTree(for: library.entries))
        models.append(model)
        await model.history.ready()
        for _ in 0..<100 where !model.listening.isLoaded || !model.playbackOptions.isLoaded || model.metadataIndex.isIndexing {
            try await Task.sleep(for: .milliseconds(10))
        }
        return model
    }

    func testLoopMarkersSurviveStopAndInsideSeekButNewSubtuneClearsThem() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid")
        let coordinator = model.coordinator
        coordinator.elapsedSeconds = 0.2; coordinator.setLoopStart()
        coordinator.elapsedSeconds = 0.6; coordinator.setLoopEnd(); coordinator.setLoopEnabled(true)
        model.seek(to: 0.3)
        XCTAssertTrue(coordinator.playbackLoop.isEnabled)
        model.stopPlayback()
        XCTAssertFalse(coordinator.playbackLoop.isEnabled)
        XCTAssertEqual(coordinator.playbackLoop.range, 0.2...0.6)
        coordinator.setLoopEnabled(true); model.seek(to: 2)
        XCTAssertFalse(coordinator.playbackLoop.isEnabled)
        XCTAssertEqual(coordinator.playbackLoop.range, 0.2...0.6)
        model.setSubtune(2)
        XCTAssertNil(coordinator.playbackLoop.range)
    }

    func testCollectionAuditRepairsVerifiedBookmarkAfterPreviewWithoutStartingPreparedAudio() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid"); model.setSubtune(2)
        let digest = try XCTUnwrap(model.currentMD5)
        let old = ListeningPersonalReference(libraryID: AppModel.listeningCollectionID, trackID: "Missing/Tune.sid", md5: digest, subtune: 2)
        model.history.saveBookmark(reference: old, title: "Keep mark", position: 1.25)
        let queue = model.listening.queue, position = model.coordinator.elapsedSeconds
        let transfer = model.collectionTransfer
        transfer.startAudit()
        for _ in 0..<500 where transfer.isAuditing { try await Task.sleep(for: .milliseconds(10)) }
        let report = try XCTUnwrap(transfer.auditReport)
        XCTAssertEqual(report.fileCount, 1)
        let issue = try XCTUnwrap(report.repairs.first { $0.reference?.path == old.trackID })
        XCTAssertEqual(model.history.document.bookmarks[0].reference.trackID, old.trackID)
        transfer.selectAuditRepair(issue.id, enabled: true)
        await transfer.applyAuditRepairs()
        XCTAssertNil(transfer.error)
        XCTAssertEqual(model.history.document.bookmarks[0].reference.trackID, "Tune.sid")
        XCTAssertEqual(model.history.document.bookmarks[0].position, 1.25)
        XCTAssertEqual(model.currentTrackID, "Tune.sid"); XCTAssertFalse(model.coordinator.isPlaying)
        XCTAssertEqual(model.coordinator.elapsedSeconds, position); XCTAssertEqual(model.listening.queue, queue)
    }

    func testCollectionAuditCancellationPreservesPreparedTrackAndPersonalData() async throws {
        let model = try await makeModel(); model.select(trackID: "Tune.sid")
        let before = model.history.document, queue = model.listening.queue
        model.collectionTransfer.startAudit(); model.collectionTransfer.cancelAudit()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.collectionTransfer.auditCancelled)
        XCTAssertNil(model.collectionTransfer.auditReport)
        XCTAssertEqual(model.history.document, before); XCTAssertEqual(model.listening.queue, queue)
        XCTAssertEqual(model.currentTrackID, "Tune.sid"); XCTAssertFalse(model.coordinator.isPlaying)
    }

    func testExportPresentationKeepsPlaybackQueueHistoryAndLoopUntouched() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid"); model.setSubtune(2)
        let coordinator = model.coordinator
        coordinator.elapsedSeconds = 0.2; coordinator.setLoopStart()
        coordinator.elapsedSeconds = 0.6; coordinator.setLoopEnd(); coordinator.setLoopEnabled(true)
        let queue = model.listening.queue, history = model.history.document
        let presentation = try XCTUnwrap(model.makeAudioExportPresentation())
        let current = try XCTUnwrap(presentation.choices.first { $0.id == 0 })
        XCTAssertEqual(current.sources.first?.subtune, 2)
        XCTAssertEqual(current.slice, 0.2...0.6)
        XCTAssertEqual(presentation.choices.first { $0.id == 1 }?.sources.first?.subtune, nil)
        XCTAssertEqual(model.listening.queue, queue)
        XCTAssertEqual(model.history.document, history)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(coordinator.currentSubtune, 2)
        XCTAssertEqual(coordinator.playbackLoop.range, 0.2...0.6)
        XCTAssertTrue(coordinator.playbackLoop.isEnabled)
    }

    func testExportDurationSnapshotUsesPersonalEndTimeAndFullFingerprint() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid"); model.setSubtune(2)
        let md5 = try XCTUnwrap(model.currentMD5)
        let target = PlaybackEndTimeTarget(md5: md5, subtune: 2, title: "Tune")
        try model.playbackOptions.setEndTime("0.4", target: target)
        let presentation = try XCTUnwrap(model.makeAudioExportPresentation())
        try model.playbackOptions.setEndTime("1.5", target: target)
        let sources = try XCTUnwrap(presentation.choices.first { $0.id == 0 }?.sources)
        let items = try await Task.detached {
            try AudioExportPlanner.prepare(sources: sources, durations: presentation.durations)
        }.value
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.md5, md5)
        XCTAssertEqual(items.first?.seconds, 0.4)
        XCTAssertEqual(items.first?.durationSource, .personal)
        XCTAssertFalse(model.coordinator.isPlaying)
    }

    func testNativeCompressedBatchUsesThePresentationAndKeepsPlaybackUntouched() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid"); model.setSubtune(2)
        let presentation = try XCTUnwrap(model.makeAudioExportPresentation())
        let source = try XCTUnwrap(presentation.choices.first { $0.id == 1 }?.sources)
        let queue = model.listening.queue, history = model.history.document
        for format in [AudioExportFormat.m4a, .flac] {
            XCTAssertTrue(format.isAvailable)
            let output = directory.appendingPathComponent(format.rawValue)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let items = try await Task.detached {
                let prepared = try AudioExportPlanner.prepare(sources: source, durations: presentation.durations, format: format)
                return try AudioExportPlanner.applyingDuration(0.1, to: prepared)
            }.value
            let result = await Task.detached {
                await AudioBatchExporter.run(items: items, options: AudioExportOptions(format: format), directory: output)
            }.value
            XCTAssertNil(result.error); XCTAssertFalse(result.wasCancelled); XCTAssertEqual(result.files.count, 3)
            for url in result.files {
                XCTAssertEqual(url.pathExtension, format.rawValue)
                let audio = try AVAudioFile(forReading: url)
                XCTAssertEqual(audio.processingFormat.channelCount, 1)
                if format == .flac { XCTAssertEqual(audio.length, 4410) }
                else {
                    let duration = try await AVURLAsset(url: url).load(.duration)
                    XCTAssertEqual(duration.seconds, 0.1, accuracy: 1.0 / 44100)
                }
            }
        }
        XCTAssertEqual(model.listening.queue, queue); XCTAssertEqual(model.history.document, history)
        XCTAssertEqual(model.coordinator.currentSubtune, 2); XCTAssertFalse(model.coordinator.isPlaying)
    }

    func testLoopPreventsNormalCompletionButSleepExpiryStopsIt() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid")
        let coordinator = model.coordinator
        coordinator.elapsedSeconds = 0; coordinator.setLoopStart()
        coordinator.elapsedSeconds = 0.25; coordinator.setLoopEnd(); coordinator.setLoopEnabled(true)
        coordinator.isPlaying = true
        model.autoNext = true
        model.handleConfiguredPlaybackEnd(elapsed: 1000)
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(coordinator.currentSubtune, 0)
        try model.playbackOptions.startSleepTimer(seconds: 0.02)
        try await Task.sleep(for: .milliseconds(50))
        model.playbackOptions.refreshSleepTimer()
        XCTAssertTrue(model.playbackOptions.didExpire)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertFalse(coordinator.playbackLoop.isEnabled)
        XCTAssertEqual(coordinator.playbackLoop.range, 0...0.25)
    }

    func testMediaServiceRebuildRestoresLoopOnlyForUnchangedMusic() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid"); model.setSubtune(2)
        let coordinator = model.coordinator
        coordinator.elapsedSeconds = 0.2; coordinator.setLoopStart()
        coordinator.elapsedSeconds = 0.6; coordinator.setLoopEnd(); coordinator.setLoopEnabled(true)
        coordinator.elapsedSeconds = 0.4
        model.rebuildAfterMediaServicesReset()
        XCTAssertEqual(coordinator.currentSubtune, 2)
        XCTAssertEqual(coordinator.elapsedSeconds, 0.4)
        XCTAssertEqual(coordinator.playbackLoop.range, 0.2...0.6)
        XCTAssertTrue(coordinator.playbackLoop.isEnabled)
        XCTAssertFalse(coordinator.isPlaying)

        model.volume = 0; model.togglePlayPause()
        for _ in 0..<300 where coordinator.isPreparingSeek || coordinator.isPreparingLoop {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertTrue(coordinator.playbackLoop.isEnabled)
        XCTAssertGreaterThanOrEqual(coordinator.elapsedSeconds, 0.2)
        XCTAssertLessThan(coordinator.elapsedSeconds, 0.8, "Auch ein gepufferter Seek braucht anschließend seinen A-Zustand")
        model.togglePlayPause(); XCTAssertTrue(coordinator.isPaused)
        model.togglePlayPause()
        XCTAssertFalse(coordinator.isPreparingLoop, "Pause erhält den bereits vorbereiteten A-Zustand")
        model.stopPlayback()

        var changed = fixture(); changed[0x16] = 0x58
        try changed.write(to: directory.appendingPathComponent("Documents/Tune.sid"))
        model.rebuildAfterMediaServicesReset()
        XCTAssertNil(coordinator.playbackLoop.range)
        XCTAssertFalse(coordinator.playbackLoop.isEnabled)
    }

    func testPreparationAndStoppedSeekNeverMarkAFileAsHeard() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid")
        for uptime in [0.0, 10, 50] {
            model.seek(to: uptime)
            model.observeHistory(force: true, uptime: uptime)
        }
        XCTAssertTrue(model.history.document.events.isEmpty)
        model.searchText = "heard:never"
        XCTAssertEqual(model.visibleTracks.map(\.id), ["Tune.sid"])
        XCTAssertFalse(model.coordinator.isPlaying)
    }

    func testHistoryLoadsExactSubtuneAndPositionAndRejectsChangedOrLongTargets() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid")
        let fileReference = try XCTUnwrap(model.currentHistoryReference)
        let reference = ListeningPersonalReference(libraryID: fileReference.libraryID, trackID: fileReference.trackID, md5: fileReference.md5, subtune: 2)
        model.volume = 0
        model.playHistoryReference(reference, position: 42.5)
        XCTAssertEqual(model.coordinator.currentSubtune, 2)
        XCTAssertEqual(model.coordinator.elapsedSeconds, 42.5, accuracy: 0.01)
        XCTAssertTrue(model.coordinator.isPlaying)
        XCTAssertTrue(model.history.document.events.isEmpty)
        model.coordinator.stop(); model.stopPlaybackLoop()
        model.playHistoryReference(reference, position: 1200.1)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.coordinator.isPlaying)
        try Data("changed".utf8).write(to: directory.appendingPathComponent("Documents/Tune.sid"))
        model.playHistoryReference(reference, position: 0)
        XCTAssertEqual(model.errorMessage, "Der Titel fehlt oder sein Inhalt wurde geändert.")
        XCTAssertFalse(model.coordinator.isPlaying)
    }

    func testQualifiedHistoryAndPersonalEditsSurviveModelRestart() async throws {
        let model = try await makeModel()
        model.select(trackID: "Tune.sid")
        let reference = try XCTUnwrap(model.currentHistoryReference)
        // Kontrollierte monotone Beobachtungen pruefen die Modellverdrahtung;
        // echte Audiozeit und GUI-Bedienung werden gesondert abgenommen.
        model.observeHistory(force: true, playing: true, uptime: 0)
        model.observeHistory(force: true, playing: false, uptime: 10)
        model.history.saveBookmark(reference: reference, title: "Bridge", position: 45)
        model.history.setNote("Remember this subtune", for: reference)
        _ = await model.history.flush()
        let restored = try await makeModel()
        XCTAssertEqual(restored.history.document.events.count, 1)
        XCTAssertEqual(restored.history.document.bookmarks.first?.position, 45)
        XCTAssertEqual(restored.history.document.note(for: reference)?.text, "Remember this subtune")
        restored.searchText = "heard:never"
        XCTAssertTrue(restored.visibleTracks.isEmpty)
        restored.searchText = "heard:yes"
        XCTAssertEqual(restored.visibleTracks.map(\.id), ["Tune.sid"])
        restored.history.clearHistory()
        restored.searchText = "heard:never"
        XCTAssertEqual(restored.visibleTracks.map(\.id), ["Tune.sid"])
        XCTAssertEqual(restored.history.document.notes.count, 1)
    }
}
