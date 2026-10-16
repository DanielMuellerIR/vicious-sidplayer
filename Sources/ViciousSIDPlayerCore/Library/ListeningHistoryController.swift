#if canImport(Combine)
import Foundation
import Combine

@MainActor
public final class ListeningHistoryController: ObservableObject {
    @Published public private(set) var document = ListeningHistoryDocument()
    @Published public private(set) var isLoaded = false
    @Published public private(set) var isReadOnly = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var storageError: String?
    private let store: ListeningHistoryStore?
    private var recorder = ListeningHistoryRecorder()
    private var loadTask: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var revision = 0
    private var savedRevision = 0
    private var lastObservationUptime: Double?

    public init(fileURL: URL? = MusicLibraryLocation.support()?.appendingPathComponent(ListeningHistoryStore.fileName)) {
        store = fileURL.map { ListeningHistoryStore(fileURL: $0) }
        loadTask = Task { [weak self] in await self?.load() }
    }

    private func load() async {
        defer { isLoaded = true }
        guard let store else { fail(ListeningHistoryError.readOnly); return }
        do {
            var loaded = try await store.load()
            let previous = loaded
            try loaded.prune()
            document = loaded
            if loaded != previous { changed() }
        } catch { fail(error) }
    }

    public func ready() async { await loadTask?.value }

    public var hasUnsavedChanges: Bool { revision != savedRevision }

    public func hasHeard(md5: String) -> Bool? {
        guard isLoaded, !isReadOnly else { return nil }
        return document.hasHeard(md5: md5)
    }

    public func observe(reference: ListeningPersonalReference?, title: String, position: Double,
                        knownDuration: Double?, isPlaying: Bool, force: Bool = false,
                        uptime: Double = ProcessInfo.processInfo.systemUptime, now: Date = Date()) {
        guard isLoaded, !isReadOnly else { return }
        if !force, let lastObservationUptime, uptime >= lastObservationUptime, uptime - lastObservationUptime < 1 { return }
        lastObservationUptime = uptime
        guard let event = recorder.observe(reference: reference, title: title, position: position,
            knownDuration: knownDuration, isPlaying: isPlaying, uptime: uptime, now: now) else { return }
        do {
            var updated = document
            try updated.record(event, now: now)
            if updated != document { document = updated; changed() }
        } catch { fail(error) }
    }

    public func saveBookmark(reference: ListeningPersonalReference, title: String, position: Double) {
        edit { try $0.saveBookmark(ListeningBookmark(reference: reference, name: title, position: position)) }
    }
    public func removeBookmark(_ id: UUID) { edit { $0.removeBookmark(id) } }
    public func setNote(_ text: String, for reference: ListeningPersonalReference) {
        edit { try $0.setNote(text, for: reference) }
    }
    public func clearHistory() {
        guard isLoaded, !isReadOnly else { return }
        recorder.reset(); lastObservationUptime = nil
        edit { $0.clearHistory() }
    }

    private func edit(_ change: (inout ListeningHistoryDocument) throws -> Void) {
        guard isLoaded, !isReadOnly else { return }
        do {
            var updated = document
            try change(&updated)
            if updated != document { document = updated; changed() }
        } catch { storageError = NSLocalizedString("Die persönlichen Daten konnten nicht geändert werden. Namen und Textlänge prüfen.", comment: "") }
    }

    private func changed() {
        revision += 1
        guard pendingSave == nil else { return }
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            self.pendingSave = nil
            _ = await self.flush()
        }
    }

    /// Aufrufer warten beim Beenden bzw. unter iOS in einer Background-Task.
    /// Die Task-Kette verhindert, dass ein alter Snapshot einen neueren ersetzt.
    @discardableResult
    public func flush() async -> Bool {
        pendingSave?.cancel(); pendingSave = nil
        await ready()
        guard let store, !isReadOnly else { return false }
        let snapshot = document, savingRevision = revision, previous = writer
        isSaving = true
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !self.isReadOnly else { return }
            do {
                try await store.save(snapshot)
                self.savedRevision = savingRevision
                self.storageError = nil
            } catch { self.fail(error) }
        }
        writer = task
        await task.value
        if savedRevision == revision || isReadOnly { isSaving = false }
        return !isReadOnly && savedRevision == revision
    }

    private func fail(_ error: Error) {
        isReadOnly = true; isSaving = false
        storageError = NSLocalizedString("Verlauf, Lesezeichen und Notizen sind schreibgeschützt. Die vorhandene Datei bleibt erhalten; sie konnte nicht gelesen oder sicher gespeichert werden.", comment: "")
    }
}
#endif
