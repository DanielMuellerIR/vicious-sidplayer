import XCTest
@testable import ViciousSIDPlayerCore

final class PlaybackOptionsTests: XCTestCase {
    private let md5 = "0123456789abcdef0123456789abcdef"

    func testFractionalEndTimeRemainsEditableWithoutRoundingToZero() throws {
        for seconds in [0.5, 1.125, 90.5, 120, 3600] {
            XCTAssertEqual(try PlaybackDurationInput.seconds(PlaybackDurationInput.text(seconds), maximum: 3600), seconds)
        }
    }

    func testDurationInputAllowsClearingFractionalSecondsAndClockValues() throws {
        XCTAssertNil(try PlaybackDurationInput.seconds("  ", maximum: 3600))
        XCTAssertEqual(try PlaybackDurationInput.seconds("1:30.5", maximum: 3600), 90.5)
        XCTAssertEqual(try PlaybackDurationInput.seconds("3600", maximum: 3600), 3600)
        for value in ["-1", "0", "nan", "inf", "1e999", "1:60", "1.5:00", ":30", "1:2:3", "3601"] {
            XCTAssertThrowsError(try PlaybackDurationInput.seconds(value, maximum: 3600), value)
        }
    }

    func testPersonalDurationPrecedesDatabaseCacheAndFallbackWithoutStartingAnEstimate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = SongLengthCache(fileURL: url), resolver = SongLengthResolver(cache: cache)
        cache.store(md5: md5, subtune: 0, seconds: 20)
        XCTAssertEqual(SongLengthSelection.duration(databaseLengths: [50], subtune: 0, computed: 20, personalDuration: 90), 90)
        XCTAssertEqual(resolver.knownDuration(md5: md5, subtune: 0, databaseLengths: [50], personalDuration: 90), 90)
        XCTAssertEqual(resolver.plan(md5: md5, subtune: 0, databaseLengths: [50], fileURL: url, personalDuration: 90), .personalProvidesLength)
        XCTAssertFalse(resolver.isEstimating)
        XCTAssertEqual(SongLengthSelection.duration(databaseLengths: [50], subtune: 0, computed: 20, personalDuration: .infinity), 50)
    }

    func testRepeatingAQueueConsumesOneShotRequestsAndKeepsTheTemplateIdentity() {
        let a = ListeningEntry(trackID: "A.sid", subtune: 2), b = ListeningEntry(trackID: "A.sid", subtune: 0)
        var queue = ListeningQueue(libraryID: "fixture", name: "Repeat", entries: [a,b])
        queue.enqueueNext(ListeningEntry(trackID: "Once.sid", subtune: 1))
        XCTAssertEqual(queue.next(allowCycle: true)?.trackID, "Once.sid")
        XCTAssertEqual(queue.next(allowCycle: true)?.id, b.id)
        XCTAssertEqual(queue.next(allowCycle: true)?.id, a.id)
        XCTAssertEqual(queue.items, [a,b]); XCTAssertEqual(a.subtune, 2)
    }

    func testPersonalEndTimesUseContentAndSubtuneAndCanBeRemoved() throws {
        var settings = PlaybackSettingsDocument()
        try settings.setEndTime(90, md5: md5.uppercased(), subtune: 2)
        XCTAssertEqual(settings.endTime(md5: md5, subtune: 2), 90)
        XCTAssertNil(settings.endTime(md5: md5, subtune: 0))
        XCTAssertNil(settings.endTime(md5: "different", subtune: 2))
        try settings.setEndTime(nil, md5: md5, subtune: 2)
        XCTAssertTrue(settings.endTimes.isEmpty)
        XCTAssertThrowsError(try settings.setEndTime(.infinity, md5: md5, subtune: 0))
        XCTAssertThrowsError(try settings.setEndTime(3601, md5: md5, subtune: 0))
        XCTAssertThrowsError(try settings.setEndTime(12, md5: md5, subtune: 256))
    }

    func testSettingsRoundtripAndFutureInvalidValuesAreRejected() throws {
        var settings = PlaybackSettingsDocument()
        settings.repeatMode = .sequence; settings.fadeOutSeconds = 3; settings.sleepMinutes = 20
        try settings.setEndTime(120, md5: md5, subtune: 0)
        let decoded = try JSONDecoder().decode(PlaybackSettingsDocument.self, from: JSONEncoder().encode(settings)).validated()
        XCTAssertEqual(decoded, settings)
        settings.version = 99; XCTAssertThrowsError(try settings.validated())
        settings.version = 1; settings.fadeOutSeconds = 31; XCTAssertThrowsError(try settings.validated())
        settings.fadeOutSeconds = 0; settings.endTimes["not-a-key"] = 1; XCTAssertThrowsError(try settings.validated())
    }

    func testFadeHasDefinedStartMidpointEndAndNoOvershoot() {
        let fade = PlaybackFadeEnvelope(songEnd: 10, seconds: 2)
        XCTAssertEqual(fade.gain(at: 7), 1)
        XCTAssertEqual(fade.gain(at: 8), 1)
        XCTAssertEqual(fade.gain(at: 9), 0.5)
        XCTAssertEqual(fade.gain(at: 10), 0)
        XCTAssertEqual(fade.gain(at: 100), 0)
        XCTAssertEqual(fade.gain(at: -1), 1)
        let short = PlaybackFadeEnvelope(songEnd: 1, seconds: 3)
        XCTAssertEqual(short.gain(at: 0), 1); XCTAssertEqual(short.gain(at: 0.5), 0.5)
        let disabled = PlaybackFadeEnvelope()
        XCTAssertEqual(disabled.gain(at: 10000), 1)
    }

    func testTimerFadeWinsOverALaterSongEnd() {
        let fade = PlaybackFadeEnvelope(songEnd: 120, timerEnd: 10, seconds: 2)
        XCTAssertEqual(fade.gain(at: 9), 0.5)
        XCTAssertEqual(fade.gain(at: 10), 0)
        XCTAssertEqual(PlaybackFadeEnvelope(songEnd: .nan, seconds: .infinity).gain(at: 100), 1)
    }

    func testSleepDeadlineSurvivesPauseSeekAndTitleChanges() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sleep = try PlaybackSleepDeadline(seconds: 60, now: now)
        XCTAssertEqual(sleep.remaining(at: now.addingTimeInterval(20)), 40)
        XCTAssertEqual(sleep.projectedTrackEnd(elapsed: 120, now: now.addingTimeInterval(20)), 160)
        XCTAssertEqual(sleep.projectedTrackEnd(elapsed: 0, now: now.addingTimeInterval(20)), 40)
        XCTAssertEqual(sleep.remaining(at: now.addingTimeInterval(70)), 0)
        XCTAssertThrowsError(try PlaybackSleepDeadline(seconds: .infinity, now: now))
        XCTAssertThrowsError(try PlaybackSleepDeadline(seconds: 10801, now: now))
    }

    private func action(mode: PlaybackRepeatMode = .off, sub: Int = 1, fixed: Bool = false,
                        autoNext: Bool = true, explicit: Bool = false, sleep: Bool = false) -> PlaybackCompletionAction? {
        PlaybackCompletionPolicy.action(isPlaying: true, elapsed: 90, duration: 90, currentSubtune: sub, subtuneCount: 3,
            entry: ListeningEntry(trackID: "A.sid", subtune: fixed ? sub : nil), autoNext: autoNext, repeatMode: mode,
            hasExplicitEnd: explicit, stopAfterSubtune: sleep)
    }
    func testWholeFilesAdvanceSubtunesAndExactEntriesAdvanceTheQueue() {
        XCTAssertEqual(action(), .subtune(2))
        XCTAssertEqual(action(fixed: true), .advanceEntry(repeatSequence: false))
        XCTAssertEqual(action(sub: 2), .advanceEntry(repeatSequence: false))
    }
    func testRepeatSubtuneFileAndSequenceHaveDifferentBoundaries() {
        XCTAssertEqual(action(mode: .subtune, fixed: true), .subtune(1))
        XCTAssertEqual(action(mode: .file, fixed: true), .subtune(2))
        XCTAssertEqual(action(mode: .file, sub: 2, fixed: true), .subtune(0))
        XCTAssertEqual(action(mode: .sequence, fixed: true), .advanceEntry(repeatSequence: true))
    }
    func testSleepStopOverridesEveryRepeatMode() {
        for mode in PlaybackRepeatMode.allCases { XCTAssertEqual(action(mode: mode, sleep: true), .stop) }
    }
    func testExplicitEndStopsWithoutAutoNextWhileTheLegacyLoopRemainsPossible() {
        XCTAssertNil(action(autoNext: false))
        XCTAssertEqual(action(autoNext: false, explicit: true), .stop)
        XCTAssertEqual(action(mode: .file, autoNext: false), .subtune(2))
        XCTAssertEqual(action(mode: .sequence, fixed: true, autoNext: false), .advanceEntry(repeatSequence: true))
        XCTAssertNil(PlaybackCompletionPolicy.action(isPlaying: false, elapsed: 100, duration: 90, currentSubtune: 0,
            subtuneCount: 1, entry: nil, autoNext: true, repeatMode: .off))
    }
}
