#if canImport(Combine)
import Foundation
import Combine

public enum PersonalCollectionImportError: Error, LocalizedError {
    case unavailable, changedPreview, skippedEntries, restartRequired
    public var errorDescription: String? {
        switch self {
        case .unavailable: return NSLocalizedString("Die ausgewählten persönlichen Daten oder die Sammlung sind noch nicht verfügbar oder schreibgeschützt.", comment: "")
        case .changedPreview: return NSLocalizedString("Sammlung oder persönliche Daten wurden seit der Vorschau geändert. Bitte die Vorschau neu laden.", comment: "")
        case .skippedEntries: return NSLocalizedString("Bitte das Auslassen nicht zugeordneter Favoriten- und Listeneinträge bestätigen.", comment: "")
        case .restartRequired: return NSLocalizedString("Die Datenübernahme benötigt einen Neustart. Vorhandene Dateien und Sicherungen bleiben erhalten; bis dahin sind weitere Änderungen gesperrt.", comment: "")
        }
    }
}

@MainActor
public final class PersonalCollectionController: ObservableObject {
    @Published public private(set) var areas = PersonalCollectionArea.standard
    @Published public private(set) var importedDocument: PersonalCollectionDocument?
    @Published public private(set) var preview: PersonalCollectionMergeResult?
    @Published public private(set) var exportData: Data?
    @Published public private(set) var exportReport: PersonalCollectionExportResult?
    @Published public private(set) var choices: [String: PersonalCollectionMergeChoice] = [:]
    @Published public private(set) var acceptedPaths: Set<PersonalCollectionReference> = []
    @Published public var confirmedSkippedEntries = false
    @Published public private(set) var isBusy = false
    @Published public private(set) var isApplying = false
    @Published public private(set) var requiresRestart = false
    @Published public private(set) var error: String?
    @Published public private(set) var completion: String?
    private let listening: ListeningLibraryController
    private let history: ListeningHistoryController
    private let playback: PlaybackOptionsController
    private let favorites: PersonalCollectionFavoritesStore
    private let supportURL: URL?
    private let context: @MainActor () throws -> PersonalCollectionContext
    private let pause: @MainActor () -> Bool
    private let resume: @MainActor () -> Void
    private let didApply: @MainActor () -> Void
    private var catalog: PersonalCollectionCatalog?
    private var baseline: PersonalCollectionSnapshot?
    private var generation = 0

    public init(listening: ListeningLibraryController, history: ListeningHistoryController, playback: PlaybackOptionsController,
                favorites: PersonalCollectionFavoritesStore, supportURL: URL?,
                context: @escaping @MainActor () throws -> PersonalCollectionContext,
                pause: @escaping @MainActor () -> Bool, resume: @escaping @MainActor () -> Void,
                didApply: @escaping @MainActor () -> Void) {
        self.listening = listening; self.history = history; self.playback = playback; self.favorites = favorites
        self.supportURL = supportURL; self.context = context; self.pause = pause; self.resume = resume; self.didApply = didApply
    }

    public var availableAreas: Set<PersonalCollectionArea> {
        var result: Set<PersonalCollectionArea> = [.favorites]
        if listening.isLoaded && !listening.isReadOnly { result.insert(.lists) }
        if history.isLoaded && !history.isReadOnly { result.formUnion([.bookmarks, .notes, .history]) }
        if playback.isLoaded && !playback.isReadOnly { result.insert(.endTimes) }
        return result
    }
    public var canApply: Bool {
        guard !isBusy, !isApplying, !requiresRestart, let preview, preview.hasChanges else { return false }
        return !areas.isEmpty && areas.isSubset(of: availableAreas) && (preview.skippedPathEntries == 0 || confirmedSkippedEntries)
    }
    public func ready() async {
        await listening.ready(); await history.ready(); await playback.ready()
        if importedDocument == nil { areas.formIntersection(availableAreas) }
        objectWillChange.send()
    }
    public func select(_ area: PersonalCollectionArea, enabled: Bool) async {
        guard !isApplying, !requiresRestart else { return }
        if enabled && availableAreas.contains(area) { areas.insert(area) } else { areas.remove(area) }
        confirmedSkippedEntries = false; exportData = nil; exportReport = nil
        await recalculate()
    }
    public func choose(_ choice: PersonalCollectionMergeChoice, for conflictID: String) async {
        guard !isApplying, !requiresRestart else { return }
        choices[conflictID] = choice; await recalculate()
    }
    public func acceptPath(_ reference: PersonalCollectionReference, enabled: Bool) async {
        guard !isApplying, !requiresRestart else { return }
        if enabled { acceptedPaths.insert(reference) } else { acceptedPaths.remove(reference) }
        confirmedSkippedEntries = false; await recalculate()
    }
    public func reset() {
        guard !isApplying, !requiresRestart else { return }
        generation += 1; importedDocument = nil; preview = nil; baseline = nil; catalog = nil
        exportData = nil; exportReport = nil; choices = [:]; acceptedPaths = []; confirmedSkippedEntries = false
        areas = PersonalCollectionArea.standard.intersection(availableAreas); error = nil; completion = nil; isBusy = false
    }
    public func report(_ error: Error) { self.error = error.localizedDescription }

    public func prepareExport() async {
        guard !isBusy, !isApplying, !requiresRestart else { return }
        generation += 1; let current = generation
        isBusy = true; error = nil; completion = nil
        defer { if generation == current { isBusy = false } }
        do {
            await ready()
            guard !areas.isEmpty, areas.isSubset(of: availableAreas) else { throw PersonalCollectionImportError.unavailable }
            let catalog = try await readCatalog(), snapshot = snapshot(), selected = areas
            let result = try await Task.detached(priority: .utility) {
                let report = try PersonalCollectionExport.make(snapshot, libraryID: catalog.libraryID, name: catalog.name,
                    contents: catalog.contents, includeHistory: selected.contains(.history))
                let document = report.document.selecting(selected)
                return (PersonalCollectionExportResult(document: document, unverifiedReferences: report.unverifiedReferences.intersection(document.references),
                    omittedEndTimeCount: selected.contains(.endTimes) ? report.omittedEndTimeCount : 0), try PersonalCollectionCodec.encode(document))
            }.value
            guard generation == current else { return }
            exportReport = result.0; exportData = result.1
        } catch { if generation == current { report(error) } }
    }

    public func readImport(from url: URL) async {
        guard !isApplying, !requiresRestart else { return }
        reset(); isBusy = true; generation += 1; let current = generation
        do {
            let document = try await Task.detached(priority: .utility) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size <= PersonalCollectionCodec.maximumBytes else { throw PersonalCollectionError.capacityExceeded }
                return try PersonalCollectionCodec.decode(Data(contentsOf: url))
            }.value
            await ready()
            guard generation == current else { return }
            importedDocument = document
            areas = Set(PersonalCollectionArea.standard.intersection(availableAreas).filter { document.count(in: $0) > 0 })
            let currentCatalog = try await readCatalog()
            guard generation == current else { return }
            catalog = currentCatalog; baseline = snapshot()
            isBusy = false
            await recalculate()
        } catch { if generation == current { report(error); isBusy = false } }
    }
    public func refreshPreview() async {
        guard importedDocument != nil, !isApplying, !requiresRestart else { return }
        generation += 1; let current = generation
        isBusy = true; error = nil; confirmedSkippedEntries = false
        do {
            let currentCatalog = try await readCatalog()
            guard generation == current else { return }
            catalog = currentCatalog; baseline = snapshot()
            // Entscheidungen gegen den vorigen Bestand gelten nicht für neue Werte.
            choices = [:]; acceptedPaths = []
            isBusy = false; await recalculate()
        } catch { if generation == current { report(error); isBusy = false } }
    }

    private func snapshot() -> PersonalCollectionSnapshot {
        .init(favorites: favorites.read(), listening: listening.document, history: history.document, playback: playback.document)
    }
    private func readCatalog() async throws -> PersonalCollectionCatalog {
        let value = try context()
        return try await Task.detached(priority: .utility) { try PersonalCollectionCatalog.read(value) }.value
    }
    private func recalculate() async {
        guard let importedDocument, let catalog, let baseline else { return }
        generation += 1; let current = generation
        let document = importedDocument.selecting(areas), choices = choices, paths = acceptedPaths
        isBusy = true; error = nil
        do {
            let preview = try await Task.detached(priority: .utility) {
                try PersonalCollectionMerge.preview(document, into: baseline, libraryID: catalog.libraryID,
                    resolver: catalog.resolver, choices: choices, acceptedPaths: paths)
            }.value
            guard generation == current else { return }
            self.preview = preview; isBusy = false
        } catch { if generation == current { report(error); preview = nil; isBusy = false } }
    }

    public func apply() async {
        guard canApply, let importedDocument, let catalog, let baseline, let supportURL else { return }
        let selected = areas, document = importedDocument.selecting(selected)
        let files = Set(selected.filter { document.count(in: $0) > 0 }.compactMap(\.file)), choices = choices, paths = acceptedPaths
        generation += 1; let currentGeneration = generation
        isBusy = true; error = nil; completion = nil
        var suspended: Set<PersonalCollectionFile> = [], wasPlaying = false, didPause = false, committed = false
        do {
            // Der teure Sammlungsabgleich läuft noch bei ungestörter Wiedergabe.
            let currentCatalog = try await readCatalog()
            guard generation == currentGeneration else { return }
            guard currentCatalog == catalog else { throw PersonalCollectionImportError.changedPreview }
            let activeContext = try context()
            guard activeContext.libraryID == catalog.libraryID,
                  activeContext.library.root.resolvingSymlinksInPath().standardizedFileURL == catalog.root else { throw PersonalCollectionImportError.changedPreview }
            guard selectedDataEqual(snapshot(), baseline, areas: selected) else { throw PersonalCollectionImportError.changedPreview }
            isApplying = true; wasPlaying = pause(); didPause = true
            if files.contains(.listeningLibrary) { try await listening.suspendForImport(); suspended.insert(.listeningLibrary) }
            if files.contains(.playbackSettings) { try await playback.suspendForImport(); suspended.insert(.playbackSettings) }
            if files.contains(.listeningHistory) { try await history.suspendForImport(); suspended.insert(.listeningHistory) }
            let current = snapshot()
            guard selectedDataEqual(current, baseline, areas: selected) else { throw PersonalCollectionImportError.changedPreview }
            let merged = try await Task.detached(priority: .utility) {
                try PersonalCollectionMerge.preview(document, into: current, libraryID: catalog.libraryID,
                    resolver: catalog.resolver, choices: choices, acceptedPaths: paths)
            }.value
            if merged.skippedPathEntries > 0 && !confirmedSkippedEntries { throw PersonalCollectionImportError.skippedEntries }
            var changes: [PersonalCollectionFileChange] = []
            if files.contains(.listeningLibrary) {
                changes.append(.init(file: .listeningLibrary, expected: try await listening.importSnapshotBytes(), replacement: try JSONEncoder().encode(merged.snapshot.listening)))
            }
            if files.contains(.playbackSettings) {
                changes.append(.init(file: .playbackSettings, expected: try await playback.importSnapshotBytes(), replacement: try JSONEncoder().encode(merged.snapshot.playback)))
            }
            if files.contains(.listeningHistory) {
                changes.append(.init(file: .listeningHistory, expected: try await history.importSnapshotBytes(), replacement: try JSONEncoder().encode(merged.snapshot.history)))
            }
            let transaction = PersonalCollectionTransaction(supportURL: supportURL), favoriteSnapshot = favorites.read()
            guard favoriteSnapshot == current.favorites else { throw PersonalCollectionImportError.changedPreview }
            try await Task.detached(priority: .utility) {
                try transaction.prepare(changes, oldFavorites: favoriteSnapshot, newFavorites: merged.snapshot.favorites)
                _ = try transaction.commit(currentFavorites: favoriteSnapshot)
            }.value
            committed = true
            try favorites.replace(favoriteSnapshot, with: merged.snapshot.favorites)
            if files.contains(.listeningLibrary) { try await listening.verifyImportedDocument(merged.snapshot.listening) }
            if files.contains(.playbackSettings) { try await playback.verifyImportedDocument(merged.snapshot.playback) }
            if files.contains(.listeningHistory) { try await history.verifyImportedDocument(merged.snapshot.history) }
            if files.contains(.listeningLibrary) { listening.acceptImportedDocument(merged.snapshot.listening) }
            if files.contains(.playbackSettings) { playback.acceptImportedDocument(merged.snapshot.playback) }
            if files.contains(.listeningHistory) { history.acceptImportedDocument(merged.snapshot.history) }
            let savedFavorites = favorites.read()
            try await Task.detached(priority: .utility) { try transaction.finish(currentFavorites: savedFavorites) }.value
            completion = NSLocalizedString("Die ausgewählten persönlichen Daten wurden zusammengeführt.", comment: "")
            preview = nil; self.importedDocument = nil; self.baseline = nil; self.catalog = nil
        } catch {
            if !didPause && generation != currentGeneration { return }
            requiresRestart = committed || error as? PersonalCollectionTransactionError == .recoveryRequired
            self.error = requiresRestart ? PersonalCollectionImportError.restartRequired.localizedDescription : error.localizedDescription
        }
        if !requiresRestart {
            if suspended.contains(.listeningLibrary) { listening.resumeAfterImport() }
            if suspended.contains(.playbackSettings) { playback.resumeAfterImport() }
            if suspended.contains(.listeningHistory) { history.resumeAfterImport() }
            if committed { didApply() }
            playback.refreshSleepTimer()
            if didPause && wasPlaying && !playback.didExpire { resume() }
            isApplying = false
        }
        isBusy = false
    }

    private func selectedDataEqual(_ lhs: PersonalCollectionSnapshot, _ rhs: PersonalCollectionSnapshot,
                                   areas: Set<PersonalCollectionArea>) -> Bool {
        (!areas.contains(.favorites) || lhs.favorites == rhs.favorites)
            && (!areas.contains(.lists) || lhs.listening.lists == rhs.listening.lists)
            && (!areas.contains(.bookmarks) || lhs.history.bookmarks == rhs.history.bookmarks)
            && (!areas.contains(.notes) || lhs.history.notes == rhs.history.notes)
            && (!areas.contains(.endTimes) || lhs.playback.endTimes == rhs.playback.endTimes)
    }
}
#endif
