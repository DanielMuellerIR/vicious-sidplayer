#if canImport(Combine)
import Foundation
import Combine

@MainActor
public final class AudioExportController: ObservableObject {
    public enum State: Equatable, Sendable { case idle, preparing, ready, exporting, cancelling, finished }
    @Published public private(set) var state = State.idle
    @Published public private(set) var items: [AudioExportItem] = []
    @Published public private(set) var selectedIDs: Set<Int> = []
    @Published public private(set) var progress: AudioExportProgress?
    @Published public private(set) var result: AudioExportResult?
    @Published public private(set) var error: String?
    @Published public private(set) var isUsingSlice = false
    @Published public private(set) var format = AudioExportFormat.wav
    private var task: Task<Void, Never>?
    private var generation = 0
    private var manualDuration: Double?
    private var directory: URL?
    private var durationInputError: String?

    public init() {}
    deinit { task?.cancel() }

    public var isWorking: Bool { state == .preparing || state == .exporting || state == .cancelling }
    public var selectedItems: [AudioExportItem] { items.filter { selectedIDs.contains($0.id) } }
    public var formatError: String? {
        guard format.isAvailable else { return AudioExportError.encoderUnavailable(format.displayName).localizedDescription }
        if format == .flac, selectedItems.contains(where: { $0.hasValidDuration && !$0.hasValidDuration(for: format) }) {
            return AudioExportError.flacTooShort.localizedDescription
        }
        return nil
    }
    public var canExport: Bool { state == .ready && error == nil && formatError == nil && !selectedIDs.isEmpty && selectedItems.allSatisfy { $0.hasValidDuration(for: format) } }
    public var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.estimatedBytes } }
    public func estimatedBytes(quality: AACExportQuality) -> Int64? {
        switch format {
        case .wav: return selectedBytes
        case .m4a: return selectedItems.filter(\.hasValidDuration).reduce(0) { $0 + Int64($1.seconds * Double(quality.rawValue) / 8) }
        case .flac: return nil
        }
    }

    public func prepare(sources: [AudioExportSource], durations: AudioExportDurationContext, directory: URL? = nil) {
        task?.cancel(); generation &+= 1
        let current = generation
        self.directory = directory
        let format = format
        state = .preparing; error = nil; result = nil; progress = nil
        items = []; selectedIDs = []; manualDuration = nil; durationInputError = nil; isUsingSlice = false
        let gate = AudioExportProgressGate()
        let publish: @MainActor @Sendable (Int, Int) -> Void = { [weak self] completed, total in
            guard let self, self.generation == current, self.state == .preparing else { return }
            self.progress = AudioExportProgress(completedFiles: completed, totalFiles: total,
                fileName: "", renderedFrames: 0, totalFrames: 0)
        }
        let worker = Task.detached(priority: .userInitiated) {
            let prepared = try AudioExportPlanner.prepare(sources: sources, durations: durations, format: format) { completed, total in
                guard gate.allows(force: completed == total) else { return }
                Task { @MainActor in publish(completed, total) }
            }
            return try AudioExportPlanner.naming(prepared, in: directory, format: format)
        }
        task = Task { [weak self] in
            do {
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.generation == current else { return }
                if Task.isCancelled { self.state = .idle }
                else { self.items = prepared; self.selectedIDs = Set(prepared.map(\.id)); self.state = .ready }
                self.task = nil; self.progress = nil
            } catch {
                guard let self, self.generation == current else { return }
                self.state = .idle; self.task = nil; self.progress = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    public func setFormat(_ format: AudioExportFormat) {
        guard state == .ready, self.format != format else { return }
        self.format = format
        renameForDirectory(directory)
    }
    public func renameForDirectory(_ directory: URL?) {
        guard state == .ready else { return }
        self.directory = directory
        let format = format
        let previous = items
        task?.cancel(); generation &+= 1
        let current = generation
        state = .preparing; error = durationInputError
        let worker = Task.detached(priority: .userInitiated) { try AudioExportPlanner.naming(previous, in: directory, format: format) }
        task = Task { [weak self] in
            do {
                let renamed = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.generation == current else { return }
                self.task = nil; self.state = .ready
                if !Task.isCancelled { self.items = renamed }
            } catch {
                guard let self, self.generation == current else { return }
                self.task = nil; self.state = .ready
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    public func toggleSelection(_ id: Int) {
        guard state == .ready, items.contains(where: { $0.id == id }) else { return }
        if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
    }
    public func selectAll(_ selected: Bool) {
        guard state == .ready else { return }
        selectedIDs = selected ? Set(items.map(\.id)) : []
    }
    public func setDuration(_ text: String) {
        guard state == .ready else { return }
        do {
            let seconds = try PlaybackDurationInput.seconds(text, maximum: WavRenderer.maximumDurationSeconds)
            items = try AudioExportPlanner.applyingDuration(seconds, to: items)
            manualDuration = seconds; isUsingSlice = false; error = nil; durationInputError = nil
        } catch { durationInputError = error.localizedDescription; self.error = durationInputError }
    }
    public func setSlice(_ range: ClosedRange<Double>?) {
        guard state == .ready else { return }
        do {
            items = try range.map { try AudioExportPlanner.applyingSlice($0, to: items) }
                ?? AudioExportPlanner.applyingDuration(manualDuration, to: items)
            isUsingSlice = range != nil; error = nil; durationInputError = nil
        } catch { durationInputError = error.localizedDescription; self.error = durationInputError }
    }

    public func export(directory: URL, options: AudioExportOptions) {
        export(destination: .folder(directory), options: options)
    }
    public func export(destination: AudioExportDestination, options: AudioExportOptions) {
        guard canExport, options.format == format else { return }
        let selection = selectedItems
        generation &+= 1
        let current = generation
        state = .exporting; result = nil; error = nil; progress = nil
        let gate = AudioExportProgressGate()
        let publish: @MainActor @Sendable (AudioExportProgress) -> Void = { [weak self] value in
            guard let self, self.generation == current, self.state == .exporting || self.state == .cancelling else { return }
            self.progress = value
        }
        let worker = Task.detached(priority: .userInitiated) {
            await AudioBatchExporter.run(items: selection, options: options, destination: destination) { value in
                let last = value.fraction == 1
                guard gate.allows(force: last) else { return }
                Task { @MainActor in publish(value) }
            }
        }
        task = Task { [weak self] in
            let outcome = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, self.generation == current else { return }
            self.result = outcome; self.error = outcome.error; self.state = .finished
            self.task = nil; self.progress = nil
        }
    }
    public func cancel() {
        guard isWorking else { return }
        state = .cancelling; task?.cancel()
    }
}

private final class AudioExportProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private let clock = ContinuousClock()
    private var last: ContinuousClock.Instant?
    func allows(force: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = clock.now
        guard force || last.map({ $0.duration(to: now) >= .milliseconds(100) }) != false else { return false }
        last = now
        return true
    }
}
#endif
