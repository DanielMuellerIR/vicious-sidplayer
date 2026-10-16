import Foundation

public struct ListeningEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let trackID: String
    /// nil spielt die weiteren Subtunes der Datei, eine Zahl nur diesen Subtune.
    public var subtune: Int?

    public init(id: UUID = UUID(), trackID: String, subtune: Int? = nil) {
        self.id = id
        self.trackID = trackID
        self.subtune = subtune
    }

    public var title: String {
        ((trackID as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    public var detail: String {
        subtune.map { "Subtune \($0 + 1)" } ?? "Alle Subtunes"
    }

    public func url(relativeTo root: URL?, allowExternal: Bool = false) -> URL? {
        guard isValid else { return nil }
        if PlaylistTrackID.isExternal(trackID) {
            return allowExternal ? URL(fileURLWithPath: trackID) : nil
        }
        guard let root, root.isFileURL else { return nil }
        return root.appendingPathComponent(trackID).standardizedFileURL
    }

    var isValid: Bool {
        !trackID.isEmpty && !trackID.contains("\0")
            && trackID.lowercased().hasSuffix(".sid")
            && !trackID.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
            && (subtune.map { (0..<256).contains($0) } ?? true)
    }
}

public struct SavedListeningList: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case regular
        case subtuneFavorites
    }

    public let id: UUID
    public let libraryID: String
    public var name: String
    public var entries: [ListeningEntry]
    public let kind: Kind

    public init(id: UUID = UUID(), libraryID: String, name: String,
                entries: [ListeningEntry] = [], kind: Kind = .regular) {
        self.id = id
        self.libraryID = libraryID
        self.name = name
        self.entries = entries
        self.kind = kind
    }
}

public enum ListeningScope: Equatable, Sendable {
    case library
    case visible(searchText: String, favoritesOnly: Bool)
    case favorites
    case folder(String)
}

public enum ListeningSelection {
    public static func entries(in playlist: Playlist, scope: ListeningScope,
                               favorites: PlaylistFavorites) -> [ListeningEntry] {
        let tracks: [PlaylistTrack]
        switch scope {
        case .library: tracks = playlist.tracks
        case .visible(let searchText, let favoritesOnly):
            tracks = playlist.visibleIndices(searchText: searchText, favoritesOnly: favoritesOnly,
                                             favorites: favorites).map { playlist.tracks[$0] }
        case .favorites: tracks = playlist.tracks.filter { favorites.contains($0.id) }
        case .folder(let path):
            tracks = playlist.tracks.filter {
                path.isEmpty ? !PlaylistTrackID.isExternal($0.id)
                    : $0.folderPath == path || $0.folderPath.hasPrefix(path + "/")
            }
        }
        return tracks.map { ListeningEntry(trackID: $0.id) }
    }
}

public enum ListeningPlaybackPolicy {
    public static func nextSubtune(entry: ListeningEntry?, current: Int, count: Int) -> Int? {
        guard entry?.subtune == nil, count > 0, current >= 0, current < count,
              current + 1 < count else { return nil }
        return current + 1
    }
}

/// Ein ausdruecklicher Schnappschuss der Hoerfolge. Such- und Ordnerfilter
/// beeinflussen ihn nach dem Start nicht mehr. Die laufende Position haengt an
/// einer Eintrags-ID: derselbe Titel darf mehrfach in einer Liste vorkommen.
public struct ListeningQueue: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case library
        case selection
        case savedList
    }

    public let libraryID: String
    public var name: String
    public let kind: Kind
    public private(set) var items: [ListeningEntry]
    public private(set) var currentID: UUID?
    public private(set) var shuffled: Bool
    public let wraps: Bool
    public private(set) var oneShotIDs: Set<UUID> = []

    public init(libraryID: String, name: String, kind: Kind = .selection,
                entries: [ListeningEntry], startingAt index: Int = 0,
                shuffled: Bool = false, wraps: Bool = false) {
        self.libraryID = libraryID
        self.name = name
        self.kind = kind
        self.items = entries
        self.currentID = entries.indices.contains(index) ? entries[index].id : entries.first?.id
        self.shuffled = shuffled
        self.wraps = wraps
        if shuffled, let currentID, let selected = entries.first(where: { $0.id == currentID }) {
            self.items = [selected] + entries.filter { $0.id != currentID }.shuffled()
        }
    }

    public var currentIndex: Int? { items.firstIndex { $0.id == currentID } }
    public var current: ListeningEntry? { currentIndex.map { items[$0] } }

    public mutating func select(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        currentID = id
    }

    public mutating func setShuffle(_ enabled: Bool) {
        guard enabled != shuffled else { return }
        shuffled = enabled
        if enabled { shuffleRemaining() }
    }

    public mutating func shuffleRemaining() {
        let start = currentIndex.map { $0 + 1 } ?? 0
        guard start < items.count else { return }
        let fixed = items[..<start]
        let next = items[start...].filter { oneShotIDs.contains($0.id) }
        let remaining = items[start...].filter { !oneShotIDs.contains($0.id) }.shuffled()
        items = Array(fixed) + next + remaining
    }

    /// Beim Neustart mit Shuffle wird bewusst keine alte Position restauriert.
    public mutating func restart(shuffled: Bool, preservePending: Bool = false) {
        let upcoming = preservePending
            ? Array(items.dropFirst((currentIndex ?? -1) + 1).filter { oneShotIDs.contains($0.id) }) : []
        items.removeAll { oneShotIDs.contains($0.id) }
        oneShotIDs.removeAll()
        self.shuffled = shuffled
        if shuffled { items.shuffle() }
        currentID = items.first?.id
        for entry in upcoming { enqueueNext(entry) }
    }

    public mutating func next() -> ListeningEntry? {
        guard !items.isEmpty else { return nil }
        guard let index = currentIndex else {
            currentID = items.first?.id
            return current
        }
        if index + 1 < items.count {
            currentID = items[index + 1].id
            return current
        }
        guard wraps else { return nil }
        let previous = currentID
        restart(shuffled: shuffled)
        if shuffled, items.count > 1, items.first?.id == previous { items.swapAt(0, 1) }
        currentID = items.first?.id
        return current
    }

    public mutating func previous() -> ListeningEntry? {
        guard let index = currentIndex else { return nil }
        if index > 0 { currentID = items[index - 1].id }
        else if wraps { currentID = items.last?.id }
        else { return nil }
        return current
    }

    public mutating func enqueueNext(_ entry: ListeningEntry) {
        // Mehrere Auftraege bleiben in ihrer Eingabereihenfolge. Sie werden
        // vor der regulaeren Folge gespielt und beim naechsten Durchlauf entfernt.
        let start = currentIndex.map { $0 + 1 } ?? 0
        var insertion = start
        while insertion < items.count && oneShotIDs.contains(items[insertion].id) { insertion += 1 }
        let fresh = ListeningEntry(trackID: entry.trackID, subtune: entry.subtune)
        items.insert(fresh, at: insertion)
        oneShotIDs.insert(fresh.id)
        if currentID == nil { currentID = fresh.id }
    }

    public mutating func move(_ id: UUID, by offset: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(items.count - 1, index + offset))
        guard target != index else { return }
        let entry = items.remove(at: index)
        items.insert(entry, at: target)
    }

    public mutating func remove(_ id: UUID) {
        // Der laufende Eintrag bleibt bis zum Titelwechsel eindeutig zugeordnet.
        guard id != currentID else { return }
        items.removeAll { $0.id == id }
        oneShotIDs.remove(id)
    }

    public mutating func updateExplicitSubtune(_ subtune: Int, trackID: String) {
        guard let index = currentIndex, items[index].trackID == trackID,
              items[index].subtune != nil, (0..<256).contains(subtune) else { return }
        items[index].subtune = subtune
    }

    public mutating func reconcileLibrary(_ tracks: [ListeningEntry], removeMissing: Bool = true) {
        guard kind == .library else { return }
        let oldIDs = items.map(\.id)
        let available = Set(tracks.map(\.trackID))
        items.removeAll { removeMissing && !available.contains($0.trackID) && $0.id != currentID
            && !oneShotIDs.contains($0.id) && !PlaylistTrackID.isExternal($0.trackID) }
        let known = Set(items.map(\.trackID))
        items.append(contentsOf: tracks.filter { !known.contains($0.trackID) })
        if shuffled, items.map(\.id) != oldIDs { shuffleRemaining() }
    }
}

public struct ListeningLibraryDocument: Codable, Equatable, Sendable {
    public let version: Int
    public var lists: [SavedListeningList]
    public var queue: ListeningQueue?

    public init(lists: [SavedListeningList] = [], queue: ListeningQueue? = nil) {
        self.version = 1
        self.lists = lists
        self.queue = queue
    }

    public func validate() throws {
        func validEntries(_ entries: [ListeningEntry]) -> Bool {
            entries.allSatisfy(\.isValid) && Set(entries.map(\.id)).count == entries.count
        }
        guard version == 1 else { throw ListeningLibraryError.unsupportedVersion }
        let favoriteRoots = lists.filter { $0.kind == .subtuneFavorites }.map(\.libraryID)
        guard Set(favoriteRoots).count == favoriteRoots.count else { throw ListeningLibraryError.invalidData }
        guard Set(lists.map(\.id)).count == lists.count,
              lists.allSatisfy({ !$0.libraryID.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && validEntries($0.entries) && ($0.kind != .subtuneFavorites || $0.entries.allSatisfy { $0.subtune != nil }) }) else {
            throw ListeningLibraryError.invalidData
        }
        if let queue {
            guard !queue.libraryID.isEmpty, validEntries(queue.items),
                  queue.currentID == nil || queue.currentIndex != nil,
                  queue.oneShotIDs.isSubset(of: Set(queue.items.map(\.id))) else {
                throw ListeningLibraryError.invalidData
            }
        }
    }
}

public enum ListeningLibraryError: Error, LocalizedError {
    case unsupportedVersion
    case invalidData
    case unavailableLocation

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "Die Hörfolgen-Datei stammt aus einer nicht unterstützten Version. Sie bleibt unverändert."
        case .invalidData: return "Die Hörfolgen-Datei enthält ungültige Einträge. Sie bleibt unverändert."
        case .unavailableLocation: return "Der Speicherort für Hörfolgen ist nicht erreichbar."
        }
    }
}

public final class ListeningLibraryStore: @unchecked Sendable {
    public static let fileName = "listening-library.json"
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func defaultURL(fm: FileManager = .default) -> URL? {
        MusicLibraryLocation.support(fm: fm)?.appendingPathComponent(fileName)
    }

    public func load() throws -> ListeningLibraryDocument {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ListeningLibraryDocument() }
        let document = try JSONDecoder().decode(ListeningLibraryDocument.self, from: Data(contentsOf: fileURL))
        try document.validate()
        return document
    }

    public func save(_ document: ListeningLibraryDocument) throws {
        lock.lock()
        defer { lock.unlock() }
        try document.validate()
        let data = try JSONEncoder().encode(document)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
