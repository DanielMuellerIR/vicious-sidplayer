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
    @Published public private(set) var isPersistenceSuspended = false
    @Published public private(set) var storageError: String?
    @Published public private(set) var remainingSleepSeconds = 0.0
    @Published public private(set) var stopAfterSubtune = false
    @Published public private(set) var didExpire = false
    public var onStopRequested: (@MainActor @Sendable () -> Void)?
    public var hasSleepTimer: Bool { sleepInstant != nil }
    private let store: PlaybackSettingsStore?
    private let writer = DispatchQueue(label: "ViciousSIDPlayer.playback-options", qos: .utility)
    private var pending: DispatchWorkItem?
    private var revision = 0
    private var loadTask: Task<Void, Never>?
    private let writeGeneration = PersonalPersistenceGeneration()
    private var sleepInstant: ContinuousClock.Instant?
    private var timerTask: Task<Void, Never>?
    private let clock = ContinuousClock()

    public init(fileURL: URL? = MusicLibraryLocation.support()?.appendingPathComponent(PlaybackSettingsStore.fileName), startup: PersonalCollectionStartup? = nil) {
        self.store = fileURL.map { PlaybackSettingsStore(fileURL: $0) }
        loadTask = Task { [weak self] in
            guard let self else { return }
            guard let store = self.store else { isReadOnly = true; isLoaded = true; return }
            let result: Result<PlaybackSettingsDocument, Error> = await Task.detached(priority: .utility) {
                do { try await startup?.ready(); return Result.success(try store.load()) }
                catch { return Result<PlaybackSettingsDocument, Error>.failure(error) }
            }.value
            switch result {
            case .success(let document): self.document = document
            case .failure: isReadOnly = true; storageError = PlaybackOptionError.invalidSettings.localizedDescription
            }
            isLoaded = true
        }
    }
    public func ready() async { await loadTask?.value }

    public func setRepeatMode(_ mode: PlaybackRepeatMode) { guard isLoaded, !isPersistenceSuspended else { return }; document.repeatMode = mode; saveSoon() }
    public func setFadeOutSeconds(_ value: Double) {
        guard isLoaded, !isPersistenceSuspended, value.isFinite, (0...30).contains(value) else { return }
        document.fadeOutSeconds = value; saveSoon()
    }
    public func setSleepMinutes(_ value: Int) {
        guard isLoaded, !isPersistenceSuspended, (1...180).contains(value) else { return }
        document.sleepMinutes = value; saveSoon()
    }
    public func setEndTime(_ text: String, target: PlaybackEndTimeTarget) throws {
        guard isLoaded, !isPersistenceSuspended else { return }
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
        guard !isPersistenceSuspended else { return }
        flushPending()
    }
    private func flushPending() {
        guard isLoaded, !isReadOnly, let store else { return }
        pending?.cancel(); pending = nil; revision += 1
        _ = writeGeneration.advance()
        let snapshot = document
        let save: @Sendable () -> Result<Void, Error> = { Result { try store.save(snapshot) } }
        receive(writer.sync(execute: save))
    }
    private func saveSoon() {
        guard isLoaded, !isReadOnly, !isPersistenceSuspended, let store else { return }
        revision += 1; let current = revision, snapshot = document
        pending?.cancel()
        let generation = writeGeneration, ticket = generation.advance()
        let write: @Sendable () -> Void = { [weak self] in
            guard generation.matches(ticket) else { return }
            let result = Result { try store.save(snapshot) }
            Task { @MainActor in
                guard let self, self.revision == current else { return }
                self.receive(result)
            }
        }
        let work = DispatchWorkItem(block: write)
        pending = work; writer.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func receive(_ result: Result<Void, Error>) {
        switch result {
        case .success: storageError = nil
        case .failure(let error):
            if error is PersonalDataFileError { isReadOnly = true }
            storageError = String(format: NSLocalizedString("Wiedergabeeinstellungen konnten nicht gesichert werden: %@", comment: ""), error.localizedDescription)
        }
    }

    public func suspendForImport() async throws {
        await ready()
        guard !isReadOnly, !isPersistenceSuspended else { throw PersonalDataFileError.readOnly }
        isPersistenceSuspended = true; flushPending()
        guard storageError == nil, !isReadOnly else {
            isPersistenceSuspended = false
            throw PersonalDataFileError.readOnly
        }
    }
    public func verifyImportedDocument(_ expected: PlaybackSettingsDocument) async throws {
        guard isPersistenceSuspended, let store else { throw PersonalDataFileError.readOnly }
        let loaded = try await Task.detached(priority: .utility) { try store.load() }.value
        guard loaded == expected else { throw PersonalDataFileError.externalChange }
    }
    public func importSnapshotBytes() async throws -> Data? {
        guard isPersistenceSuspended, let store else { throw PersonalDataFileError.readOnly }
        return try await Task.detached(priority: .utility) { try store.snapshotBytes() }.value
    }
    public func acceptImportedDocument(_ value: PlaybackSettingsDocument) {
        guard isPersistenceSuspended else { return }
        document = value; revision += 1; storageError = nil
    }
    public func resumeAfterImport() { isPersistenceSuspended = false }
}
#endif
