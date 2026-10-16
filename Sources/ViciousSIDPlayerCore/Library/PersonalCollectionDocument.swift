import Foundation

public enum PersonalCollectionError: Error, LocalizedError {
    case unsupportedVersion, invalidData, capacityExceeded
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return NSLocalizedString("Dieses Format persönlicher Sammlungsdaten wird nicht unterstützt. Vorhandene Daten bleiben unverändert.", comment: "")
        case .invalidData: return NSLocalizedString("Die persönlichen Sammlungsdaten enthalten ungültige Einträge.", comment: "")
        case .capacityExceeded: return NSLocalizedString("Die persönlichen Sammlungsdaten überschreiten die zulässige Größe.", comment: "")
        }
    }
}

public struct PersonalCollectionReference: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let md5: String?
    public let subtune: Int?
    public init(path: String, md5: String? = nil, subtune: Int? = nil) {
        self.path = path; self.md5 = md5?.lowercased(); self.subtune = subtune
    }
    var isValid: Bool {
        Self.validPath(path) && (md5.map(Self.validMD5) ?? true)
            && (subtune.map { (0..<256).contains($0) } ?? true)
    }
    static func validPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let windowsDrive = components.first.map { $0.count == 2 && $0.last == ":" } ?? false
        return !path.isEmpty && path.count <= 8192 && !path.hasPrefix("/")
            && !windowsDrive
            && !path.contains("\\") && !path.contains("\0")
            && !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
            && path.lowercased().hasSuffix(".sid")
    }
    static func validMD5(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validDate(_ date: Date) -> Bool {
        (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970)
    }
    func native(libraryID: String) -> ListeningPersonalReference? {
        md5.map { ListeningPersonalReference(libraryID: libraryID, trackID: path, md5: $0, subtune: subtune) }
    }
}

public struct PersonalCollectionEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reference: PersonalCollectionReference
    public init(id: UUID = UUID(), reference: PersonalCollectionReference) { self.id = id; self.reference = reference }
}

public struct PersonalCollectionList: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: SavedListeningList.Kind
    public let entries: [PersonalCollectionEntry]
    public init(id: UUID = UUID(), name: String, kind: SavedListeningList.Kind = .regular,
                entries: [PersonalCollectionEntry]) {
        self.id = id; self.name = name; self.kind = kind; self.entries = entries
    }
}

public struct PersonalCollectionBookmark: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reference: PersonalCollectionReference
    public let name: String
    public let position: Double
    public let updatedAt: Date
    public init(id: UUID = UUID(), reference: PersonalCollectionReference, name: String, position: Double, updatedAt: Date = Date()) {
        self.id = id; self.reference = reference; self.name = name; self.position = position; self.updatedAt = updatedAt
    }
    var isValid: Bool {
        guard reference.isValid, let native = reference.native(libraryID: "portable") else { return false }
        return PersonalCollectionReference.validDate(updatedAt) && ListeningBookmark(id: id, reference: native, name: name, position: position, updatedAt: updatedAt).isValid
    }
}

public struct PersonalCollectionNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reference: PersonalCollectionReference
    public let text: String
    public let updatedAt: Date
    public init(id: UUID = UUID(), reference: PersonalCollectionReference, text: String, updatedAt: Date = Date()) {
        self.id = id; self.reference = reference; self.text = text; self.updatedAt = updatedAt
    }
    var contentKey: String { "\(reference.md5 ?? ""):\(reference.subtune.map(String.init) ?? "file")" }
    var isValid: Bool {
        guard reference.isValid, let native = reference.native(libraryID: "portable") else { return false }
        return PersonalCollectionReference.validDate(updatedAt) && ListeningNote(id: id, reference: native, text: text, updatedAt: updatedAt).isValid
    }
}

public struct PersonalCollectionEndTime: Codable, Equatable, Sendable {
    public let md5: String
    public let subtune: Int
    public let seconds: Double
    public init(md5: String, subtune: Int, seconds: Double) { self.md5 = md5.lowercased(); self.subtune = subtune; self.seconds = seconds }
    var key: String { "\(md5):\(subtune)" }
    var isValid: Bool {
        PersonalCollectionReference.validMD5(md5) && (0..<256).contains(subtune)
            && seconds.isFinite && seconds > 0 && seconds <= WavRenderer.maximumDurationSeconds
    }
}

public struct PersonalCollectionEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let reference: PersonalCollectionReference
    public let title: String
    public let startedAt: Date
    public let lastHeardAt: Date
    public let heardSeconds: Double
    public let lastPosition: Double
    public init(id: UUID = UUID(), reference: PersonalCollectionReference, title: String, startedAt: Date,
                lastHeardAt: Date, heardSeconds: Double, lastPosition: Double) {
        self.id = id; self.reference = reference; self.title = title; self.startedAt = startedAt
        self.lastHeardAt = lastHeardAt; self.heardSeconds = heardSeconds; self.lastPosition = lastPosition
    }
    var isValid: Bool {
        guard reference.isValid, let native = reference.native(libraryID: "portable") else { return false }
        return PersonalCollectionReference.validDate(startedAt) && PersonalCollectionReference.validDate(lastHeardAt) && ListeningHistoryEvent(id: id, reference: native, title: title, startedAt: startedAt,
            lastHeardAt: lastHeardAt, heardSeconds: heardSeconds, lastPosition: lastPosition).isValid
    }
}

public struct PersonalCollectionHistory: Codable, Equatable, Sendable {
    public let events: [PersonalCollectionEvent]
    public let heardMD5s: Set<String>
    public init(events: [PersonalCollectionEvent], heardMD5s: Set<String>) { self.events = events; self.heardMD5s = heardMD5s }
    private enum CodingKeys: String, CodingKey { case events, heardMD5s }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(events, forKey: .events)
        try container.encode(heardMD5s.sorted(), forKey: .heardMD5s)
    }
}

public struct PersonalCollectionDocument: Codable, Equatable, Sendable {
    public var format = "vicioussid.personal-collection"
    public var version = 1
    public var name: String
    public var createdAt: Date
    public var favorites: [PersonalCollectionReference] = []
    public var lists: [PersonalCollectionList] = []
    public var bookmarks: [PersonalCollectionBookmark] = []
    public var notes: [PersonalCollectionNote] = []
    public var endTimes: [PersonalCollectionEndTime] = []
    public var history: PersonalCollectionHistory?
    public init(name: String, createdAt: Date = Date()) { self.name = name; self.createdAt = createdAt }

    public func validate() throws {
        guard format == "vicioussid.personal-collection", version == 1 else { throw PersonalCollectionError.unsupportedVersion }
        guard favorites.count <= 200_000, lists.count <= 5000, lists.reduce(0, { $0 + $1.entries.count }) <= 200_000,
              bookmarks.count <= 20_000, notes.count <= 20_000, endTimes.count <= 200_000,
              (history?.events.count ?? 0) <= 20_000, (history?.heardMD5s.count ?? 0) <= 200_000 else {
            throw PersonalCollectionError.capacityExceeded
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 200, !name.contains("\0"),
              PersonalCollectionReference.validDate(createdAt),
              favorites.allSatisfy({ $0.isValid && $0.subtune == nil }), Set(favorites).count == favorites.count,
              Set(lists.map(\.id)).count == lists.count,
              lists.filter({ $0.kind == .subtuneFavorites }).count <= 1,
              lists.allSatisfy({ list in
                  !list.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && list.name.count <= 200 && !list.name.contains("\0")
                      && Set(list.entries.map(\.id)).count == list.entries.count
                      && list.entries.allSatisfy { $0.reference.isValid && (list.kind != .subtuneFavorites || $0.reference.subtune != nil) }
              }), Set(bookmarks.map(\.id)).count == bookmarks.count, bookmarks.allSatisfy(\.isValid),
              Set(notes.map(\.id)).count == notes.count, Set(notes.map(\.contentKey)).count == notes.count, notes.allSatisfy(\.isValid),
              Set(endTimes.map(\.key)).count == endTimes.count, endTimes.allSatisfy(\.isValid) else { throw PersonalCollectionError.invalidData }
        if let history {
            guard Set(history.events.map(\.id)).count == history.events.count, history.events.allSatisfy(\.isValid),
                  history.heardMD5s.allSatisfy(PersonalCollectionReference.validMD5),
                  Set(history.events.compactMap { $0.reference.md5 }).isSubset(of: history.heardMD5s) else { throw PersonalCollectionError.invalidData }
        }
    }
}

public enum PersonalCollectionCodec {
    public static let maximumBytes = 32 * 1024 * 1024
    public static func encode(_ document: PersonalCollectionDocument) throws -> Data {
        try document.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let milliseconds = (date.timeIntervalSince1970 * 1000).rounded() / 1000
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: Date(timeIntervalSince1970: milliseconds)))
        }
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw PersonalCollectionError.capacityExceeded }
        return data
    }
    public static func decode(_ data: Data) throws -> PersonalCollectionDocument {
        guard data.count <= maximumBytes else { throw PersonalCollectionError.capacityExceeded }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer(), text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: text)
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = fractional ?? formatter.date(from: text) else { throw PersonalCollectionError.invalidData }
            return date
        }
        struct Header: Decodable { let format: String; let version: Int }
        let header = try decoder.decode(Header.self, from: data)
        guard header.format == "vicioussid.personal-collection", header.version == 1 else { throw PersonalCollectionError.unsupportedVersion }
        let document = try decoder.decode(PersonalCollectionDocument.self, from: data)
        try document.validate()
        return document
    }
}
