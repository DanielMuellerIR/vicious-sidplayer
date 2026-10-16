#if canImport(Combine)
import Foundation
import Combine

/// Gemeinsamer Zustand der nativen Oberflaechen. Lesen, Kodieren und Schreiben
/// laufen neben dem Hauptthread; die fachlichen Regeln bleiben reine Core-Werte.
@MainActor
public final class ListeningLibraryController: ObservableObject {
    @Published public private(set) var document = ListeningLibraryDocument()
    @Published public private(set) var isLoaded = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var storageError: String?
    @Published public private(set) var isReadOnly = false
    @Published public private(set) var isPersistenceSuspended = false
    @Published public private(set) var activeLibraryID = "opened-files"
    @Published public private(set) var availableTrackIDs: Set<String> = []

    private let store: ListeningLibraryStore?
    private let writer = DispatchQueue(label: "ViciousSIDPlayer.listening-persistence", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var revision = 0
    private var queueChangedBeforeLoad = false
    private var loadTask: Task<Void, Never>?
    private let writeGeneration = PersonalPersistenceGeneration()
    private let startup: PersonalCollectionStartup?

    public var queue: ListeningQueue? { document.queue }
    public var lists: [SavedListeningList] { document.lists }
    public var activeLists: [SavedListeningList] { lists.filter { $0.libraryID == activeLibraryID } }

    public init(fileURL: URL? = ListeningLibraryStore.defaultURL(), startup: PersonalCollectionStartup? = nil) {
        self.store = fileURL.map { ListeningLibraryStore(fileURL: $0) }
        self.startup = startup
        loadTask = Task { await load() }
    }

    private func load() async {
        guard let store else {
            storageError = ListeningLibraryError.unavailableLocation.localizedDescription
            isReadOnly = true
            isLoaded = true
            return
        }
        let result: Result<ListeningLibraryDocument, Error> = await Task.detached(priority: .userInitiated) {
            do { try await self.startup?.ready(); return Result.success(try store.load()) }
            catch { return Result<ListeningLibraryDocument, Error>.failure(error) }
        }.value
        switch result {
        case .success(var document):
            if queueChangedBeforeLoad { document.queue = self.document.queue }
            self.document = document
        case .failure(let error):
            storageError = String(format: NSLocalizedString("Hörfolgen konnten nicht geladen werden: %@ Die vorhandene Datei bleibt erhalten.", comment: ""), error.localizedDescription)
            isReadOnly = true
        }
        isLoaded = true
        if queueChangedBeforeLoad { saveSoon() }
    }
    public func ready() async { await loadTask?.value }

    public func activateLibrary(_ id: String, tracks: [ListeningEntry], removeMissing: Bool = false) {
        guard !isPersistenceSuspended else { return }
        activeLibraryID = id
        let available = Set(tracks.map(\.trackID))
        if available != availableTrackIDs { availableTrackIDs = available }
        guard isLoaded else { return }
        guard document.queue?.libraryID == id else {
            if document.queue != nil { setQueue(nil) }
            return
        }
        if var queue = document.queue, queue.kind == .library {
            let old = queue
            queue.reconcileLibrary(tracks, removeMissing: removeMissing)
            if queue != old { setQueue(queue) }
        }
    }

    public func setQueue(_ queue: ListeningQueue?) {
        guard !isPersistenceSuspended else { return }
        if !isLoaded { queueChangedBeforeLoad = true }
        guard queue != document.queue else { return }
        document.queue = queue
        saveSoon()
    }

    public func setShuffle(_ enabled: Bool) {
        guard var queue = document.queue else { return }
        queue.setShuffle(enabled)
        setQueue(queue)
    }

    public func enqueueNext(_ entry: ListeningEntry) {
        guard var queue = document.queue else { return }
        queue.enqueueNext(entry)
        setQueue(queue)
    }

    public func moveQueueEntry(_ id: UUID, by offset: Int) {
        guard var queue = document.queue else { return }
        queue.move(id, by: offset)
        setQueue(queue)
    }

    public func moveQueueEntries(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard var queue = document.queue else { return }
        queue.move(fromOffsets: offsets, toOffset: destination)
        setQueue(queue)
    }

    public func removeQueueEntry(_ id: UUID) {
        guard var queue = document.queue else { return }
        queue.remove(id)
        setQueue(queue)
    }

    @discardableResult
    public func createList(name: String, entries: [ListeningEntry]) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !isReadOnly, !isPersistenceSuspended, !name.isEmpty else { return nil }
        let list = SavedListeningList(libraryID: activeLibraryID, name: name, entries: entries)
        document.lists.append(list)
        saveSoon()
        return list.id
    }

    public func renameList(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !isReadOnly, !isPersistenceSuspended, !name.isEmpty,
              let index = document.lists.firstIndex(where: { $0.id == id && $0.kind == .regular }) else { return }
        document.lists[index].name = name
        saveSoon()
    }

    public func deleteList(_ id: UUID) {
        guard isLoaded, !isReadOnly, !isPersistenceSuspended else { return }
        document.lists.removeAll { $0.id == id }
        saveSoon()
    }

    public func append(_ entry: ListeningEntry, to listID: UUID) {
        guard isLoaded, !isReadOnly, !isPersistenceSuspended, let index = document.lists.firstIndex(where: { $0.id == listID && $0.libraryID == activeLibraryID }) else { return }
        guard document.lists[index].kind != .subtuneFavorites || entry.subtune != nil else { return }
        if document.lists[index].kind == .subtuneFavorites,
           document.lists[index].entries.contains(where: { $0.trackID == entry.trackID && $0.subtune == entry.subtune }) { return }
        document.lists[index].entries.append(ListeningEntry(trackID: entry.trackID, subtune: entry.subtune))
        saveSoon()
    }

    public func moveListEntry(_ id: UUID, in listID: UUID, by offset: Int) {
        guard isLoaded, !isReadOnly, !isPersistenceSuspended, let index = document.lists.firstIndex(where: { $0.id == listID }),
              let position = document.lists[index].entries.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(document.lists[index].entries.count - 1, position + offset))
        guard target != position else { return }
        let entry = document.lists[index].entries.remove(at: position)
        document.lists[index].entries.insert(entry, at: target)
        saveSoon()
    }

    public func moveListEntries(in listID: UUID, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard isLoaded, !isReadOnly, !isPersistenceSuspended, let index = document.lists.firstIndex(where: { $0.id == listID }) else { return }
        moveListeningEntries(&document.lists[index].entries, fromOffsets: offsets, toOffset: destination)
        saveSoon()
    }

    public func removeListEntry(_ id: UUID, from listID: UUID) {
        guard isLoaded, !isReadOnly, !isPersistenceSuspended, let index = document.lists.firstIndex(where: { $0.id == listID }) else { return }
        document.lists[index].entries.removeAll { $0.id == id }
        saveSoon()
    }

    public func setSubtune(_ subtune: Int?, entryID: UUID, listID: UUID) {
        guard isLoaded, !isReadOnly, !isPersistenceSuspended, subtune.map({ (0..<256).contains($0) }) ?? true,
              let list = document.lists.firstIndex(where: { $0.id == listID && $0.kind == .regular }),
              let entry = document.lists[list].entries.firstIndex(where: { $0.id == entryID }) else { return }
        document.lists[list].entries[entry].subtune = subtune
        saveSoon()
    }

    public func isSubtuneFavorite(trackID: String, subtune: Int) -> Bool {
        activeLists.contains { $0.kind == .subtuneFavorites && $0.entries.contains { $0.trackID == trackID && $0.subtune == subtune } }
    }

    public func toggleSubtuneFavorite(trackID: String, subtune: Int) {
        guard isLoaded, !isReadOnly, !isPersistenceSuspended else { return }
        if let index = document.lists.firstIndex(where: { $0.libraryID == activeLibraryID && $0.kind == .subtuneFavorites }) {
            if let entry = document.lists[index].entries.firstIndex(where: { $0.trackID == trackID && $0.subtune == subtune }) {
                document.lists[index].entries.remove(at: entry)
            } else {
                document.lists[index].entries.append(ListeningEntry(trackID: trackID, subtune: subtune))
            }
        } else {
            document.lists.append(SavedListeningList(libraryID: activeLibraryID, name: "Lieblings-Subtunes",
                entries: [ListeningEntry(trackID: trackID, subtune: subtune)], kind: .subtuneFavorites))
        }
        saveSoon()
    }

    public func retrySave() { saveSoon() }

    private func saveSoon() {
        guard isLoaded, !isReadOnly, !isPersistenceSuspended, let store else { return }
        revision += 1
        let revision = revision, snapshot = document
        let generation = writeGeneration, ticket = generation.advance()
        isSaving = true
        pendingSave?.cancel()
        let write: @Sendable () -> Void = { [weak self] in
            guard generation.matches(ticket) else { return }
            let result = Result { try store.save(snapshot) }
            Task { @MainActor in
                guard let self, self.revision == revision else { return }
                self.isSaving = false
                switch result {
                case .success: self.storageError = nil
                case .failure(let error):
                    if error is PersonalDataFileError { self.isReadOnly = true }
                    self.storageError = String(format: NSLocalizedString("Hörfolgen sind noch nicht gesichert: %@", comment: ""), error.localizedDescription)
                }
            }
        }
        let work = DispatchWorkItem(block: write)
        pendingSave = work
        writer.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Beim normalen Beenden darf der letzte gebuendelte Schreibauftrag nicht
    /// verloren gehen. Nur hier wartet die Oberflaeche auf ihren eigenen Writer.
    public func flush() {
        guard !isPersistenceSuspended else { return }
        flushPending()
    }
    private func flushPending() {
        guard isLoaded, !isReadOnly, let store else { return }
        defer { isSaving = false }
        pendingSave?.cancel()
        _ = writeGeneration.advance()
        revision += 1
        let snapshot = document
        do {
            let save: @Sendable () throws -> Void = { try store.save(snapshot) }
            try writer.sync(execute: save)
            storageError = nil
            isSaving = false
        } catch {
            if error is PersonalDataFileError { isReadOnly = true }
            storageError = String(format: NSLocalizedString("Hörfolgen konnten nicht gesichert werden: %@", comment: ""), error.localizedDescription)
        }
    }

    public func suspendForImport() async throws {
        await ready()
        guard !isReadOnly, !isPersistenceSuspended else { throw PersonalDataFileError.readOnly }
        isPersistenceSuspended = true
        flushPending()
        guard storageError == nil, !isReadOnly else {
            isPersistenceSuspended = false
            throw PersonalDataFileError.readOnly
        }
    }
    public func verifyImportedDocument(_ expected: ListeningLibraryDocument) async throws {
        guard isPersistenceSuspended, let store else { throw PersonalDataFileError.readOnly }
        let loaded = try await Task.detached(priority: .utility) { try store.load() }.value
        guard loaded == expected else { throw PersonalDataFileError.externalChange }
    }
    public func importSnapshotBytes() async throws -> Data? {
        guard isPersistenceSuspended, let store else { throw PersonalDataFileError.readOnly }
        return try await Task.detached(priority: .utility) { try store.snapshotBytes() }.value
    }
    public func acceptImportedDocument(_ value: ListeningLibraryDocument) {
        guard isPersistenceSuspended else { return }
        document = value; revision += 1; storageError = nil; isSaving = false
    }
    public func resumeAfterImport() { isPersistenceSuspended = false }
}
#endif
