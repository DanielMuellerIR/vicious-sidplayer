import Foundation
import OSLog
import ViciousSIDPlayerCore

private let completionLogger = Logger(subsystem: "com.viben.ViciousSIDPlayer", category: "Playback")

extension AppModel {
    var personalDuration: Double? { playbackOptions.document.endTime(md5: currentMD5, subtune: coordinator.currentSubtune) }
    var playbackEndTimeTarget: PlaybackEndTimeTarget? {
        currentMD5.map { PlaybackEndTimeTarget(md5: $0, subtune: coordinator.currentSubtune, title: coordinator.trackName) }
    }
    func applyPlaybackOptions() {
        coordinator.setLoopDuration(currentDuration)
        coordinator.setFadeEnvelope(playbackOptions.fadeEnvelope(duration: currentDuration, elapsed: coordinator.elapsedSeconds,
            autoNext: autoNext, hasPersonalEnd: personalDuration != nil))
    }
    func stopPlayback() {
        completionLogger.notice("Stop; Timer abgelaufen: \(self.playbackOptions.didExpire), Subtune-Endaktion: \(self.playbackOptions.stopAfterSubtune)")
        collectionImportMayResume = false
        observeHistory(force: true, playing: false)
        coordinator.stop(); stopPlaybackLoop(); services.lastSessionBucket = -1
        saveSessionState(); updateNowPlaying(force: true)
    }
    func endListeningQueue() {
        stopPlayback(); listening.setQueue(nil)
    }
    func handleConfiguredPlaybackEnd(elapsed: Double) {
        guard let action = PlaybackCompletionPolicy.action(isPlaying: coordinator.isPlaying, elapsed: elapsed, duration: currentDuration,
            currentSubtune: coordinator.currentSubtune, subtuneCount: coordinator.subtunesCount, entry: listening.queue?.current,
            autoNext: autoNext, repeatMode: playbackOptions.document.repeatMode,
            hasExplicitEnd: personalDuration != nil || playbackOptions.document.fadeOutSeconds > 0,
            stopAfterSubtune: playbackOptions.stopAfterSubtune, loopEnabled: coordinator.playbackLoop.isEnabled) else { return }
        completionLogger.notice("Songende; Aktion: \(String(describing: action), privacy: .public), Auto-Next: \(self.autoNext)")
        switch action {
        case .stop:
            if playbackOptions.stopAfterSubtune { playbackOptions.finishSubtuneStop() } else { stopPlayback() }
        case .subtune(let index): setSubtune(index, updateListeningQueue: false); applyPlaybackOptions()
        case .advanceEntry(let repeatSequence):
            ensureListeningQueue(); advanceListeningQueue(forward: true, autoplay: true, repeatSequence: repeatSequence)
        }
    }
}
