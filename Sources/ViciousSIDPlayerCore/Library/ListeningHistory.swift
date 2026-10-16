import Foundation

public enum ListeningHistoryError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidData, capacityExceeded, readOnly, externalChange
}

public struct ListeningPersonalReference: Codable, Equatable, Sendable {
    public let libraryID: String
    public let trackID: String
    public let md5: String
    public let subtune: Int?

    public init(libraryID: String, trackID: String, md5: String, subtune: Int? = nil) {
        self.libraryID = libraryID; self.trackID = trackID
        self.md5 = md5.lowercased(); self.subtune = subtune
    }

    public var contentKey: String { "\(md5):\(subtune.map(String.init) ?? "file")" }
    var isValid: Bool {
        !libraryID.isEmpty && libraryID.count <= 2048 && !libraryID.contains("\0")
            && trackID.count <= 8192 && ListeningEntry(trackID: trackID, subtune: subtune).isValid
            && validHistoryMD5(md5)
    }
}

public struct ListeningHistoryEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reference: ListeningPersonalReference
    public let title: String
    public let startedAt: Date
    public var lastHeardAt: Date
    public var heardSeconds: Double
    public var lastPosition: Double

    public init(id: UUID = UUID(), reference: ListeningPersonalReference, title: String,
                startedAt: Date, lastHeardAt: Date, heardSeconds: Double, lastPosition: Double) {
        self.id = id; self.reference = reference; self.title = title; self.startedAt = startedAt
        self.lastHeardAt = lastHeardAt; self.heardSeconds = heardSeconds; self.lastPosition = lastPosition
    }
    var isValid: Bool {
        reference.isValid && reference.subtune != nil && title.count <= 1024 && !title.contains("\0")
            && startedAt.timeIntervalSinceReferenceDate.isFinite && lastHeardAt.timeIntervalSinceReferenceDate.isFinite
            && lastHeardAt >= startedAt && heardSeconds.isFinite && heardSeconds >= 1
            && lastPosition.isFinite && lastPosition >= 0
    }
}

public struct ListeningBookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reference: ListeningPersonalReference
    public var name: String
    public var position: Double
    public var updatedAt: Date

    public init(id: UUID = UUID(), reference: ListeningPersonalReference, name: String,
                position: Double, updatedAt: Date = Date()) {
        self.id = id; self.reference = reference; self.name = name
        self.position = position; self.updatedAt = updatedAt
    }
    var isValid: Bool {
        reference.isValid && reference.subtune != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 200 && !name.contains("\0") && position.isFinite && position >= 0
            && updatedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

public struct ListeningNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reference: ListeningPersonalReference
    public var text: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), reference: ListeningPersonalReference, text: String, updatedAt: Date = Date()) {
        self.id = id; self.reference = reference; self.text = text; self.updatedAt = updatedAt
    }
    var isValid: Bool {
        reference.isValid && text.count <= 16_000 && !text.contains("\0")
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && updatedAt.timeIntervalSinceReferenceDate.isFinite
    }
}

public struct ListeningHistoryRetention: Equatable, Sendable {
    public var maximumEvents: Int
    public var maximumAgeDays: Int
    public init(maximumEvents: Int = 2000, maximumAgeDays: Int = 180) {
        self.maximumEvents = maximumEvents; self.maximumAgeDays = maximumAgeDays
    }
    var isValid: Bool { (1...20_000).contains(maximumEvents) && (1...3650).contains(maximumAgeDays) }
}

public struct ListeningHistoryDocument: Codable, Equatable, Sendable {
    public var version = 1
    public private(set) var events: [ListeningHistoryEvent] = []
    /// Die Aufbewahrung kuerzt Ereignisse, nicht die Aussage „schon gehoert“.
    public private(set) var heardMD5s: Set<String> = []
    public private(set) var bookmarks: [ListeningBookmark] = []
    public private(set) var notes: [ListeningNote] = []
    public init() {}

    public func hasHeard(md5: String) -> Bool { heardMD5s.contains(md5.lowercased()) }
    public func note(for reference: ListeningPersonalReference) -> ListeningNote? {
        notes.first { $0.reference.contentKey == reference.contentKey }
    }

    public mutating func record(_ event: ListeningHistoryEvent, retention: ListeningHistoryRetention = .init(),
                                now: Date = Date()) throws {
        guard event.isValid, retention.isValid, now.timeIntervalSinceReferenceDate.isFinite else {
            throw ListeningHistoryError.invalidData
        }
        guard heardMD5s.contains(event.reference.md5) || heardMD5s.count < 200_000 else {
            throw ListeningHistoryError.capacityExceeded
        }
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            guard events[index].reference == event.reference, events[index].startedAt == event.startedAt,
                  event.heardSeconds >= events[index].heardSeconds, event.lastHeardAt >= events[index].lastHeardAt else {
                throw ListeningHistoryError.invalidData
            }
            events[index] = event
        } else { events.append(event) }
        heardMD5s.insert(event.reference.md5)
        try prune(retention: retention, now: now)
    }

    public mutating func prune(retention: ListeningHistoryRetention = .init(), now: Date = Date()) throws {
        guard retention.isValid, now.timeIntervalSinceReferenceDate.isFinite else { throw ListeningHistoryError.invalidData }
        let cutoff = now.addingTimeInterval(-Double(retention.maximumAgeDays) * 86400)
        events.removeAll { $0.lastHeardAt < cutoff }
        events.sort {
            if $0.lastHeardAt != $1.lastHeardAt { return $0.lastHeardAt > $1.lastHeardAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        if events.count > retention.maximumEvents { events.removeLast(events.count - retention.maximumEvents) }
    }

    /// Beim bewussten Leeren muss der Aufrufer auch seinen Recorder zuruecksetzen.
    public mutating func clearHistory() { events.removeAll(); heardMD5s.removeAll() }

    public mutating func saveBookmark(_ bookmark: ListeningBookmark) throws {
        guard bookmark.isValid else { throw ListeningHistoryError.invalidData }
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) { bookmarks[index] = bookmark }
        else {
            guard bookmarks.count < 20_000 else { throw ListeningHistoryError.capacityExceeded }
            bookmarks.insert(bookmark, at: 0)
        }
    }
    public mutating func removeBookmark(_ id: UUID) { bookmarks.removeAll { $0.id == id } }

    public mutating func setNote(_ text: String, for reference: ListeningPersonalReference, now: Date = Date()) throws {
        guard reference.isValid, now.timeIntervalSinceReferenceDate.isFinite else { throw ListeningHistoryError.invalidData }
        let index = notes.firstIndex { $0.reference.contentKey == reference.contentKey }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let index { notes.remove(at: index) }
            return
        }
        let note = ListeningNote(id: index.map { notes[$0].id } ?? UUID(), reference: reference, text: text, updatedAt: now)
        guard note.isValid else { throw ListeningHistoryError.invalidData }
        if let index { notes[index] = note }
        else {
            guard notes.count < 20_000 else { throw ListeningHistoryError.capacityExceeded }
            notes.append(note)
        }
    }

    public func validated() throws -> Self {
        guard version == 1 else { throw ListeningHistoryError.unsupportedVersion }
        guard events.count <= 20_000, heardMD5s.count <= 200_000, bookmarks.count <= 20_000, notes.count <= 20_000 else {
            throw ListeningHistoryError.capacityExceeded
        }
        guard events.allSatisfy(\.isValid), bookmarks.allSatisfy(\.isValid), notes.allSatisfy(\.isValid),
              heardMD5s.allSatisfy(validHistoryMD5), Set(events.map(\.id)).count == events.count,
              Set(bookmarks.map(\.id)).count == bookmarks.count, Set(notes.map(\.id)).count == notes.count,
              Set(notes.map { $0.reference.contentKey }).count == notes.count,
              events.allSatisfy({ heardMD5s.contains($0.reference.md5) }) else { throw ListeningHistoryError.invalidData }
        return self
    }
}

/// Beobachtet echte Wiedergabezeit. Ein Positionssprung erzeugt keine Hoerzeit;
/// Pause und Subtune-Repeat behalten dieselbe Episode. Lange unbeobachtete
/// Zeitraeume werden nicht nachtraeglich als sicher gehoert ausgegeben.
public struct ListeningHistoryRecorder: Sendable {
    private struct Observation: Sendable {
        let reference: ListeningPersonalReference
        let position: Double
        let uptime: Double
        let isPlaying: Bool
    }
    private var episode: ListeningHistoryEvent?
    private var previous: Observation?
    private var threshold = 10.0
    private var lastPlayingUptime: Double?
    public init() {}
    public mutating func reset() { episode = nil; previous = nil; lastPlayingUptime = nil; threshold = 10 }

    public mutating func observe(reference: ListeningPersonalReference?, title: String, position: Double,
                                 knownDuration: Double?, isPlaying: Bool, uptime: Double,
                                 now: Date = Date()) -> ListeningHistoryEvent? {
        guard position.isFinite, position >= 0, uptime.isFinite, uptime >= 0,
              now.timeIntervalSinceReferenceDate.isFinite else { reset(); return nil }
        if let previous, uptime < previous.uptime { reset() }
        if let previous, previous.isPlaying, var current = episode {
            let delta = uptime - previous.uptime
            if delta > 0 && delta <= 30 {
                current.heardSeconds += delta
                current.lastHeardAt = max(current.lastHeardAt, now)
                if reference == previous.reference && (isPlaying || position >= previous.position) { current.lastPosition = position }
                episode = current; lastPlayingUptime = uptime
            }
        }
        let completed = qualifiedEvent
        guard let reference, reference.isValid, reference.subtune != nil, title.count <= 1024, !title.contains("\0") else {
            reset(); return completed
        }
        let pauseExpired = !isPlaying ? false : lastPlayingUptime.map { uptime - $0 > 900 } ?? false
        if episode?.reference != reference || pauseExpired { episode = nil; lastPlayingUptime = nil }
        if isPlaying {
            if episode == nil {
                episode = ListeningHistoryEvent(reference: reference, title: title, startedAt: now,
                    lastHeardAt: now, heardSeconds: 0, lastPosition: position)
            }
            episode?.lastPosition = position
            lastPlayingUptime = uptime
        }
        if let knownDuration, knownDuration.isFinite, knownDuration > 0 { threshold = min(10, max(1, knownDuration / 2)) }
        else { threshold = 10 }
        previous = Observation(reference: reference, position: position, uptime: uptime, isPlaying: isPlaying)
        return qualifiedEvent ?? completed
    }

    private var qualifiedEvent: ListeningHistoryEvent? {
        guard let episode, episode.heardSeconds >= threshold, episode.isValid else { return nil }
        return episode
    }
}

/// Serialisierte persoenliche Ablage. Vor dem ersten Schreiben laden; eine
/// zwischenzeitlich geaenderte Datei wird bis zum bewussten Neuladen erhalten.
public actor ListeningHistoryStore {
    public static let fileName = "listening-history.json"
    public static let maximumFileBytes = 32 * 1024 * 1024
    public let fileURL: URL
    private var loaded = false
    private var writable = false
    private var previousData: Data?
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> ListeningHistoryDocument {
        loaded = true; writable = false
        let data = try readData()
        let document = try data.map { bytes in
            struct Header: Decodable { let version: Int }
            guard try JSONDecoder().decode(Header.self, from: bytes).version == 1 else {
                throw ListeningHistoryError.unsupportedVersion
            }
            return try JSONDecoder().decode(ListeningHistoryDocument.self, from: bytes).validated()
        } ?? ListeningHistoryDocument()
        previousData = data; writable = true
        return document
    }

    public func save(_ document: ListeningHistoryDocument) throws {
        guard loaded, writable else { throw ListeningHistoryError.readOnly }
        guard try readData() == previousData else { writable = false; throw ListeningHistoryError.externalChange }
        let data = try JSONEncoder().encode(document.validated())
        guard data.count <= Self.maximumFileBytes else { throw ListeningHistoryError.capacityExceeded }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        previousData = data
    }

    private func readData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(Self.maximumFileBytes) else {
            throw ListeningHistoryError.capacityExceeded
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumFileBytes else { throw ListeningHistoryError.capacityExceeded }
        return data
    }
}

private func validHistoryMD5(_ md5: String) -> Bool {
    md5.utf8.count == 32 && md5.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
