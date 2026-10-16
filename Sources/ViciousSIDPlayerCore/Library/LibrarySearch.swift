import Foundation

enum LibrarySearchText {
    // Ein festes Locale macht gespeicherte Suchansichten auf beiden nativen
    // Plattformen gleich; Headertexte werden nur beim Indexaufbau gefaltet.
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
}

/// Begriffe werden UND-verknuepft. Anfuehrungszeichen erhalten Leerzeichen in
/// Feldwerten; unbekannte Felder sind Fehler statt unbemerkte leere Treffer.
public struct LibrarySearchQuery: Equatable, Sendable {
    private enum Field: String, Sendable { case any, title, author, released, chips, model, min, max, duration, metadata }
    private struct Term: Equatable, Sendable {
        let field: Field
        let value: String
        let number: Double?
        let normalizedValue: String
    }
    private let terms: [Term]
    public let error: String?
    public var isEmpty: Bool { terms.isEmpty && error == nil }
    public var requiresDuration: Bool { terms.contains { [.min, .max, .duration].contains($0.field) } }

    public init(_ text: String) {
        var tokens: [String] = [], token = "", quoted = false, escaped = false
        for char in text {
            if escaped { token.append(char); escaped = false }
            else if char == "\\", quoted { escaped = true }
            else if char == "\"" { quoted.toggle() }
            else if char.isWhitespace && !quoted {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else { token.append(char) }
        }
        if !token.isEmpty { tokens.append(token) }
        var parsed: [Term] = [], message: String?
        if quoted || escaped { message = NSLocalizedString("Anführungszeichen schließen.", comment: "") }
        for token in tokens where message == nil {
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field: Field
            let value: String
            if parts.count == 2 {
                guard let known = Field(rawValue: parts[0].lowercased()) else { message = String(format: NSLocalizedString("Unbekanntes Suchfeld: %@", comment: ""), String(parts[0])); break }
                field = known; value = String(parts[1])
            } else { field = .any; value = token }
            var number: Double?
            guard !value.isEmpty else { message = String(format: NSLocalizedString("Leerer Wert für Suchfeld: %@", comment: ""), field.rawValue); break }
            switch field {
            case .chips:
                number = Double(value)
                if ![1.0, 2.0, 3.0].contains(number ?? 0) { message = NSLocalizedString("chips erwartet 1, 2 oder 3.", comment: "") }
            case .model:
                if !["6581", "8580", "unknown"].contains(value.lowercased()) { message = NSLocalizedString("model erwartet 6581, 8580 oder unknown.", comment: "") }
            case .duration, .metadata:
                if !["known", "unknown"].contains(value.lowercased()) { message = String(format: NSLocalizedString("%@ erwartet known oder unknown.", comment: ""), field.rawValue) }
            case .min, .max:
                let clock = value.split(separator: ":", omittingEmptySubsequences: false)
                if clock.count == 1 { number = Double(value) }
                else if clock.count == 2, let minutes = Double(clock[0]), let seconds = Double(clock[1]),
                        minutes.rounded() == minutes, minutes >= 0, seconds >= 0, seconds < 60 { number = minutes * 60 + seconds }
                if number == nil || !number!.isFinite || number! < 0 { message = NSLocalizedString("min/max erwartet Sekunden oder m:ss.", comment: "") }
            default: break
            }
            parsed.append(Term(field: field, value: value, number: number, normalizedValue: LibrarySearchText.normalize(value)))
        }
        if let minimum = parsed.filter({ $0.field == .min }).compactMap(\.number).max(),
           let maximum = parsed.filter({ $0.field == .max }).compactMap(\.number).min(), minimum > maximum { message = NSLocalizedString("Die Mindestdauer liegt über der Höchstdauer.", comment: "") }
        terms = parsed; error = message
    }

    public func matches(name: String, folderPath: String, metadata: LibraryMetadata?, duration: Double? = nil,
                        normalizedName: String? = nil, normalizedFolderPath: String? = nil) -> Bool {
        guard error == nil else { return false }
        func contains(_ text: String?, _ value: String) -> Bool { text?.range(of: value, options: .literal) != nil }
        return terms.allSatisfy { term in
            switch term.field {
            case .any:
                return contains(normalizedName ?? LibrarySearchText.normalize(name), term.normalizedValue)
                    || contains(normalizedFolderPath ?? LibrarySearchText.normalize(folderPath), term.normalizedValue)
                    || contains(metadata?.normalizedTitle, term.normalizedValue)
                    || contains(metadata?.normalizedAuthor, term.normalizedValue)
                    || contains(metadata?.normalizedReleased, term.normalizedValue)
            case .title: return contains(metadata?.normalizedTitle, term.normalizedValue)
            case .author: return contains(metadata?.normalizedAuthor, term.normalizedValue)
            case .released: return contains(metadata?.normalizedReleased, term.normalizedValue)
            case .chips: return metadata?.chipCount == Int(term.number!)
            case .model:
                if term.value.lowercased() == "unknown" { return metadata == nil || metadata!.chipModels.contains(.unknown) }
                return metadata?.chipModels.contains { $0 == .either || $0 == (term.value == "6581" ? .mos6581 : .mos8580) } == true
            case .min: return duration.map { $0 >= term.number! } ?? false
            case .max: return duration.map { $0 <= term.number! } ?? false
            case .duration: return (duration != nil) == (term.value.lowercased() == "known")
            case .metadata: return (metadata != nil) == (term.value.lowercased() == "known")
            }
        }
    }
}

public struct SavedLibrarySearch: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var query: String
    public var favoritesOnly: Bool
    public init(id: UUID = UUID(), name: String, query: String, favoritesOnly: Bool = false) {
        self.id = id; self.name = name; self.query = query; self.favoritesOnly = favoritesOnly
    }
}

public enum LibrarySearchSelection {
    public static func indices(in playlist: Playlist, query: LibrarySearchQuery, records: [String: LibraryMetadataRecord],
                               favoritesOnly: Bool, favorites: PlaylistFavorites,
                               duration: (LibraryMetadata) -> Double? = { _ in nil }) -> [Int] {
        if query.isEmpty && !favoritesOnly { return Array(playlist.tracks.indices) }
        return playlist.tracks.indices.filter { index in
            let track = playlist.tracks[index]
            if favoritesOnly && !favorites.contains(track.id) { return false }
            let record = records[track.id], metadata = record?.metadata
            return query.matches(name: track.name, folderPath: track.folderPath, metadata: metadata,
                                 duration: query.requiresDuration ? metadata.flatMap(duration) : nil,
                                 normalizedName: record?.normalizedName.isEmpty == false ? record?.normalizedName : nil,
                                 normalizedFolderPath: record?.normalizedFolderPath)
        }
    }

    public static func entries(in playlist: Playlist, scope: ListeningScope, favorites: PlaylistFavorites,
                               records: [String: LibraryMetadataRecord], duration: (LibraryMetadata) -> Double? = { _ in nil }) -> [ListeningEntry] {
        if case .visible(let text, let favoritesOnly) = scope {
            return indices(in: playlist, query: LibrarySearchQuery(text), records: records, favoritesOnly: favoritesOnly,
                           favorites: favorites, duration: duration).map { ListeningEntry(trackID: playlist.tracks[$0].id) }
        }
        return ListeningSelection.entries(in: playlist, scope: scope, favorites: favorites)
    }
}

public struct SavedLibrarySearchDocument: Codable, Equatable, Sendable {
    public var version = 1
    public var searches: [SavedLibrarySearch] = []
    public init() {}
    public func validated() throws -> Self {
        guard version == 1, Set(searches.map(\.id)).count == searches.count,
              searches.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && LibrarySearchQuery($0.query).error == nil }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return self
    }
}
