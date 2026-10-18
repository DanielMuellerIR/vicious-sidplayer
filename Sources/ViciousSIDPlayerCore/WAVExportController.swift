#if canImport(Combine)
import Foundation
import Combine

@MainActor
public final class WAVExportController: ObservableObject {
    public enum State: Equatable, Sendable { case idle, preparing, ready, exporting, cancelling, finished }
    @Published public private(set) var state = State.idle
    @Published public private(set) var items: [WAVExportItem] = []
    @Published public private(set) var selectedIDs: Set<Int> = []
    @Published public private(set) var progress: WAVExportProgress?
    @Published public private(set) var result: WAVExportResult?
    @Published public private(set) var error: String?
    @Published public private(set) var isUsingSlice = false
    private var task: Task<Void, Never>?
    private var generation = 0
    private var manualDuration: Double?

    public init() {}
    deinit { task?.cancel() }

    public var isWorking: Bool { state == .preparing || state == .exporting || state == .cancelling }
    public var selectedItems: [WAVExportItem] { items.filter { selectedIDs.contains($0.id) } }
    public var canExport: Bool { state == .ready && error == nil && !selectedIDs.isEmpty && selectedItems.allSatisfy(\.hasValidDuration) }
    public var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.estimatedBytes } }

    public func prepare(sources: [WAVExportSource], durations: WAVExportDurationContext, directory: URL? = nil) {
        task?.cancel(); generation &+= 1
        let current = generation
        state = .preparing; error = nil; result = nil; progress = nil
        items = []; selectedIDs = []; manualDuration = nil; isUsingSlice = false
        let gate = WAVExportProgressGate()
        let publish: @MainActor @Sendable (Int, Int) -> Void = { [weak self] completed, total in
            guard let self, self.generation == current, self.state == .preparing else { return }
            self.progress = WAVExportProgress(completedFiles: completed, totalFiles: total,
                fileName: "", renderedFrames: 0, totalFrames: 0)
        }
        let worker = Task.detached(priority: .userInitiated) {
            let prepared = try WAVExportPlanner.prepare(sources: sources, durations: durations) { completed, total in
                guard gate.allows(force: completed == total) else { return }
                Task { @MainActor in publish(completed, total) }
            }
            return try directory.map { try WAVExportPlanner.naming(prepared, in: $0) } ?? prepared
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

    public func renameForDirectory(_ directory: URL) {
        guard state == .ready else { return }
        let previous = items
        task?.cancel(); generation &+= 1
        let current = generation
        state = .preparing; error = nil
        let worker = Task.detached(priority: .userInitiated) { try WAVExportPlanner.naming(previous, in: directory) }
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
            items = try WAVExportPlanner.applyingDuration(seconds, to: items)
            manualDuration = seconds; isUsingSlice = false; error = nil
        } catch { self.error = error.localizedDescription }
    }
    public func setSlice(_ range: ClosedRange<Double>?) {
        guard state == .ready else { return }
        do {
            items = try range.map { try WAVExportPlanner.applyingSlice($0, to: items) }
                ?? WAVExportPlanner.applyingDuration(manualDuration, to: items)
            isUsingSlice = range != nil; error = nil
        } catch { self.error = error.localizedDescription }
    }

    public func export(directory: URL, options: WAVExportOptions) {
        export(destination: .folder(directory), options: options)
    }
    public func export(destination: WAVExportDestination, options: WAVExportOptions) {
        guard canExport else { return }
        let selection = selectedItems
        generation &+= 1
        let current = generation
        state = .exporting; result = nil; error = nil; progress = nil
        let gate = WAVExportProgressGate()
        let publish: @MainActor @Sendable (WAVExportProgress) -> Void = { [weak self] value in
            guard let self, self.generation == current, self.state == .exporting || self.state == .cancelling else { return }
            self.progress = value
        }
        let worker = Task.detached(priority: .userInitiated) {
            WAVBatchExporter.run(items: selection, options: options, destination: destination) { value in
                let last = value.completedFiles + 1 == value.totalFiles && value.renderedFrames == value.totalFrames
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

private final class WAVExportProgressGate: @unchecked Sendable {
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
