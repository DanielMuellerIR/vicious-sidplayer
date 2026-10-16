#if canImport(Combine)
import Foundation
import Combine

public struct PlaybackEndTimeTarget: Equatable, Sendable {
    public let md5: String
    public let subtune: Int
    public let title: String
    public init(md5: String, subtune: Int, title: String) { self.md5 = md5; self.subtune = subtune; self.title = title }
}

@MainActor
public final class PlaybackOptionsController: ObservableObject {
    @Published public private(set) var document = PlaybackSettingsDocument()
    @Published public private(set) var isLoaded = false
    @Published public private(set) var isReadOnly = false
    @Published public private(set) var storageError: String?
    @Published public private(set) var remainingSleepSeconds = 0.0
    @Published public private(set) var stopAfterSubtune = false
    @Published public private(set) var didExpire = false
    public var onStopRequested: (@MainActor @Sendable () -> Void)?
    public var hasSleepTimer: Bool { sleepInstant != nil }
    private let fileURL: URL?
    private let writer = DispatchQueue(label: "ViciousSIDPlayer.playback-options", qos: .utility)
    private var pending: DispatchWorkItem?
    private var revision = 0
    private var sleepInstant: ContinuousClock.Instant?
    private var timerTask: Task<Void, Never>?
    private let clock = ContinuousClock()

    public init(fileURL: URL? = MusicLibraryLocation.support()?.appendingPathComponent("playback-options.json")) {
        self.fileURL = fileURL
        Task { [weak self] in
            guard let self else { return }
            guard let fileURL else { isReadOnly = true; isLoaded = true; return }
            let result = await Task.detached(priority: .utility) {
                Result {
                    guard FileManager.default.fileExists(atPath: fileURL.path) else { return PlaybackSettingsDocument() }
                    return try JSONDecoder().decode(PlaybackSettingsDocument.self, from: Data(contentsOf: fileURL)).validated()
                }
            }.value
            switch result {
            case .success(let document): self.document = document
            case .failure: isReadOnly = true; storageError = PlaybackOptionError.invalidSettings.localizedDescription
            }
            isLoaded = true
        }
    }

    public func setRepeatMode(_ mode: PlaybackRepeatMode) { guard isLoaded else { return }; document.repeatMode = mode; saveSoon() }
    public func setFadeOutSeconds(_ value: Double) {
        guard isLoaded, value.isFinite, (0...30).contains(value) else { return }
        document.fadeOutSeconds = value; saveSoon()
    }
    public func setSleepMinutes(_ value: Int) {
        guard isLoaded, (1...180).contains(value) else { return }
        document.sleepMinutes = value; saveSoon()
    }
    public func setEndTime(_ text: String, target: PlaybackEndTimeTarget) throws {
        guard isLoaded else { return }
        let seconds = try PlaybackDurationInput.seconds(text, maximum: WavRenderer.maximumDurationSeconds)
        try document.setEndTime(seconds, md5: target.md5, subtune: target.subtune); saveSoon()
    }
    public func acknowledgeManualPlayback() { refreshSleepTimer(); didExpire = false }

    public func startSleepTimer(seconds: Double) throws {
        _ = try PlaybackSleepDeadline(seconds: seconds)
        cancelSleepTimer()
        sleepInstant = clock.now.advanced(by: .seconds(seconds)); remainingSleepSeconds = seconds
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.refreshSleepTimer()
                if self.sleepInstant == nil { return }
            }
        }
    }
    public func stopAtSubtuneEnd() { cancelSleepTimer(); stopAfterSubtune = true }
    public func cancelSleepTimer() {
        timerTask?.cancel(); timerTask = nil; sleepInstant = nil
        remainingSleepSeconds = 0; stopAfterSubtune = false; didExpire = false
    }
    public func refreshSleepTimer() {
        guard let sleepInstant else { return }
        let remaining = secondsRemaining(until: sleepInstant)
        remainingSleepSeconds = remaining
        if remaining <= 0 { requestSleepStop() }
    }
    public func finishSubtuneStop() { if stopAfterSubtune { requestSleepStop() } }
    private func requestSleepStop() {
        cancelSleepTimer(); didExpire = true; onStopRequested?()
    }
    public func fadeEnvelope(duration: Double, elapsed: Double, autoNext: Bool, hasPersonalEnd: Bool) -> PlaybackFadeEnvelope {
        let explicitEnd = autoNext || document.repeatMode != .off || document.fadeOutSeconds > 0 || hasPersonalEnd || stopAfterSubtune
        return PlaybackFadeEnvelope(songEnd: explicitEnd ? duration : nil,
            timerEnd: sleepInstant.map { max(0, elapsed) + secondsRemaining(until: $0) }, seconds: document.fadeOutSeconds)
    }

    private func secondsRemaining(until instant: ContinuousClock.Instant) -> Double {
        let duration = clock.now.duration(to: instant).components
        return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }

    public func retrySave() { saveSoon() }
    public func flush() {
        guard isLoaded, !isReadOnly, let fileURL else { return }
        pending?.cancel(); pending = nil; revision += 1
        let snapshot = document
        let save: @Sendable () -> String? = { Self.write(snapshot, to: fileURL) }
        let result = writer.sync(execute: save)
        storageError = result
    }
    private func saveSoon() {
        guard isLoaded, !isReadOnly, let fileURL else { return }
        revision += 1; let current = revision, snapshot = document
        pending?.cancel()
        let write: @Sendable () -> Void = { [weak self] in
            let error = Self.write(snapshot, to: fileURL)
            Task { @MainActor in
                guard let self, self.revision == current else { return }
                self.storageError = error
            }
        }
        let work = DispatchWorkItem(block: write)
        pending = work; writer.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    nonisolated private static func write(_ document: PlaybackSettingsDocument, to url: URL) -> String? {
        do {
            let data = try JSONEncoder().encode(document.validated())
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return nil
        } catch { return NSLocalizedString("Wiedergabeeinstellungen konnten nicht gesichert werden.", comment: "") }
    }
}
#endif
