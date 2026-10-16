#if canImport(Combine)
import Foundation
import Combine

@MainActor
public final class LibraryMetadataController: ObservableObject {
    @Published public private(set) var records: [String: LibraryMetadataRecord] = [:]
    @Published public private(set) var isIndexing = false
    @Published public private(set) var indexedCount = 0
    @Published public private(set) var totalCount = 0
    @Published public private(set) var storageError: String?
    private var cache: LibraryMetadataCache?
    private var root: URL?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var libraryRecords: [String: LibraryMetadataRecord] = [:]
    private var openedRecords: [String: LibraryMetadataRecord] = [:]
    private var openedTask: Task<Void, Never>?
    private var openedGeneration = 0

    public init() {}

    public func refresh(library: MusicLibrary) {
        task?.cancel(); generation &+= 1
        let current = generation, entries = library.entries
        if root != library.root {
            libraryRecords = [:]; publishRecords(); root = library.root
            cache = LibraryMetadataCache(root: library.root, supportDirectory: library.supportDirectory, indexFileName: library.indexFileName)
        }
        guard let cache else { return }
        isIndexing = true; indexedCount = 0; totalCount = entries.count
        task = Task { [weak self] in
            let cached = await cache.cachedRecords(for: entries)
            guard let self, !Task.isCancelled, self.generation == current else { return }
            self.libraryRecords = cached; self.publishRecords(); self.indexedCount = cached.count
            do {
                let result = try await cache.refresh(entries: entries) { [weak self] count in
                    Task { @MainActor in
                        guard let self, self.generation == current, self.isIndexing else { return }
                        self.indexedCount = max(self.indexedCount, count)
                    }
                }
                guard !Task.isCancelled, self.generation == current else { return }
                self.libraryRecords = result; self.publishRecords(); self.storageError = await cache.storageError
                self.indexedCount = entries.count; self.isIndexing = false; self.task = nil
            } catch {
                guard self.generation == current else { return }
                self.isIndexing = false; self.task = nil
            }
        }
    }

    public func cancel(clear: Bool = false) {
        task?.cancel(); task = nil; generation &+= 1; isIndexing = false
        openedTask?.cancel(); openedTask = nil; openedGeneration &+= 1
        if clear { libraryRecords = [:]; openedRecords = [:]; publishRecords(); indexedCount = 0; totalCount = 0 }
    }

    public func suspend() async {
        let running = task, opened = openedTask
        cancel()
        await running?.value; await opened?.value
    }

    public func refreshOpenedFiles(_ tracks: [PlaylistTrack]) {
        openedTask?.cancel(); openedGeneration &+= 1
        let current = openedGeneration, previous = openedRecords
        openedTask = Task.detached(priority: .utility) { [weak self] in
            var next: [String: LibraryMetadataRecord] = [:]
            for track in tracks {
                if Task.isCancelled { return }
                guard let values = try? track.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize, let date = values.contentModificationDate else { continue }
                if let record = previous[track.id], record.fileSize == size, record.modificationDate == date, !record.unavailable { next[track.id] = record }
                else {
                    let data = try? Data(contentsOf: track.url)
                    next[track.id] = LibraryMetadataRecord(fileSize: size, modificationDate: date,
                        metadata: data.flatMap { try? LibraryMetadata(data: $0) }, unavailable: data == nil, name: track.name, folderPath: track.folderPath)
                }
            }
            guard !Task.isCancelled else { return }
            await self?.acceptOpenedFiles(next, generation: current)
        }
    }

    private func acceptOpenedFiles(_ value: [String: LibraryMetadataRecord], generation: Int) {
        guard generation == openedGeneration else { return }
        openedRecords = value; publishRecords(); openedTask = nil
    }
    private func publishRecords() {
        let merged = libraryRecords.merging(openedRecords, uniquingKeysWith: { first, _ in first })
        if records != merged { records = merged }
    }
}

/// Suchansichten sind klein und sammlungsuebergreifend verwendbar. Defekte oder
/// neuere persoenliche Daten werden schreibgeschuetzt statt ersetzt.
@MainActor
public final class SavedLibrarySearchController: ObservableObject {
    @Published public private(set) var document = SavedLibrarySearchDocument()
    @Published public private(set) var isLoaded = false
    @Published public private(set) var isReadOnly = false
    @Published public private(set) var error: String?
    private let fileURL: URL?
    private let writer = DispatchQueue(label: "ViciousSIDPlayer.saved-searches", qos: .utility)
    private var revision = 0

    public init(fileURL: URL? = MusicLibraryLocation.support()?.appendingPathComponent("saved-searches.json")) {
        self.fileURL = fileURL
        Task { [weak self] in
            guard let self else { return }
            guard let fileURL else { isReadOnly = true; error = NSLocalizedString("Speicherort für Suchansichten nicht verfügbar.", comment: ""); isLoaded = true; return }
            let loaded = await Task.detached(priority: .utility) {
                Result { () throws -> SavedLibrarySearchDocument in
                    guard FileManager.default.fileExists(atPath: fileURL.path) else { return SavedLibrarySearchDocument() }
                    return try JSONDecoder().decode(SavedLibrarySearchDocument.self, from: Data(contentsOf: fileURL)).validated()
                }
            }.value
            switch loaded {
            case .success(let document): self.document = document
            case .failure: isReadOnly = true; error = NSLocalizedString("Gespeicherte Suchansichten sind nicht lesbar. Die vorhandene Datei bleibt erhalten.", comment: "")
            }
            isLoaded = true
        }
    }

    public func save(name: String, query: String, favoritesOnly: Bool) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !isReadOnly, !name.isEmpty, LibrarySearchQuery(query).error == nil else { return }
        document.searches.append(SavedLibrarySearch(name: name, query: query, favoritesOnly: favoritesOnly))
        persist()
    }
    public func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLoaded, !isReadOnly, !name.isEmpty, let index = document.searches.firstIndex(where: { $0.id == id }) else { return }
        document.searches[index].name = name; persist()
    }
    public func remove(_ id: UUID) {
        guard isLoaded, !isReadOnly else { return }
        document.searches.removeAll { $0.id == id }; persist()
    }
    public func retrySave() { guard isLoaded, !isReadOnly else { return }; persist() }
    public func flush() { writer.sync {} }
    private func persist() {
        guard let fileURL else { return }
        let snapshot = document; revision += 1; let current = revision
        writer.async { [weak self] in
            let result = Result {
                let data = try JSONEncoder().encode(snapshot.validated())
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            }
            Task { @MainActor in
                guard let self, self.revision == current else { return }
                self.error = result.failure.map { _ in NSLocalizedString("Suchansichten konnten nicht gesichert werden.", comment: "") }
            }
        }
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}
#endif
