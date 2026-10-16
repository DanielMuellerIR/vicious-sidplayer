#if canImport(Combine)
import XCTest
@testable import ViciousSIDPlayerCore

@MainActor
final class PlaybackOptionsControllerTests: XCTestCase {
    private func loaded(_ controller: PlaybackOptionsController) async throws {
        for _ in 0..<100 where !controller.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(controller.isLoaded)
    }
    func testFlushPersistsLatestOptionsButDoesNotRestoreAnActiveTimer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("options.json"), controller = PlaybackOptionsController(fileURL: url)
        try await loaded(controller)
        controller.setRepeatMode(.file); controller.setFadeOutSeconds(3); controller.setSleepMinutes(20)
        try controller.startSleepTimer(seconds: 60); controller.flush(); controller.cancelSleepTimer()
        let restored = PlaybackOptionsController(fileURL: url); try await loaded(restored)
        XCTAssertEqual(restored.document.repeatMode, .file); XCTAssertEqual(restored.document.fadeOutSeconds, 3)
        XCTAssertEqual(restored.document.sleepMinutes, 20); XCTAssertFalse(restored.hasSleepTimer)
    }
    func testDebouncedSaveRunsOffTheMainActorWithoutAnExplicitFlush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("options.json"), controller = PlaybackOptionsController(fileURL: url)
        try await loaded(controller)
        controller.setFadeOutSeconds(7)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: url.path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettingsDocument.self, from: Data(contentsOf: url)).fadeOutSeconds, 7)
    }
    func testFutureSettingsStayByteIdenticalWhileTemporaryControlsStillWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("options.json"), bytes = Data("{\"version\":99}".utf8)
        try bytes.write(to: url)
        let controller = PlaybackOptionsController(fileURL: url); try await loaded(controller)
        XCTAssertTrue(controller.isReadOnly); controller.setRepeatMode(.file); controller.flush()
        XCTAssertEqual(controller.document.repeatMode, .file)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testTimerFadeUsesTheDeadlineBetweenDisplayTicks() async throws {
        let controller = PlaybackOptionsController(fileURL: nil); try await loaded(controller)
        try controller.startSleepTimer(seconds: 10); defer { controller.cancelSleepTimer() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.remainingSleepSeconds, 10)
        let envelope = controller.fadeEnvelope(duration: 360, elapsed: 100, autoNext: false, hasPersonalEnd: false)
        XCTAssertLessThan(try XCTUnwrap(envelope.timerEnd), 109.95)
        XCTAssertGreaterThan(try XCTUnwrap(envelope.timerEnd), 108)
    }

    func testTimerStopsOnceAndManualPlaybackCanAcknowledgeItsExpiry() async throws {
        let controller = PlaybackOptionsController(fileURL: nil); try await loaded(controller)
        var stops = 0; controller.onStopRequested = { stops += 1 }
        try controller.startSleepTimer(seconds: 0.05)
        for _ in 0..<150 where !controller.didExpire { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.didExpire); XCTAssertEqual(stops, 1); XCTAssertFalse(controller.hasSleepTimer)
        controller.refreshSleepTimer(); XCTAssertEqual(stops, 1)
        controller.acknowledgeManualPlayback(); XCTAssertFalse(controller.didExpire)
        controller.stopAtSubtuneEnd(); controller.finishSubtuneStop(); XCTAssertEqual(stops, 2)
        controller.finishSubtuneStop(); XCTAssertEqual(stops, 2)
    }
}
#endif
