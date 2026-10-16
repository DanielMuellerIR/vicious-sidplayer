import Foundation

public struct PersonalCollectionCatalogTrack: Equatable, Sendable {
    public let path: String
    public let md5: String?
    public init(path: String, md5: String?) { self.path = path; self.md5 = md5?.lowercased() }
}

public enum PersonalCollectionResolution: Equatable, Hashable, Sendable {
    case exact(String), moved(String), unverified(String), missing, changed, ambiguous
    public var confirmedPath: String? {
        switch self { case .exact(let path), .moved(let path): return path; default: return nil }
    }
}

public struct PersonalCollectionResolver: Sendable {
    private let tracks: [String: PersonalCollectionCatalogTrack]
    private let pathsByMD5: [String: [String]]

    public init(tracks: [PersonalCollectionCatalogTrack]) throws {
        guard Set(tracks.map(\.path)).count == tracks.count,
              tracks.allSatisfy({ PersonalCollectionReference.validPath($0.path)
                  && ($0.md5.map(PersonalCollectionReference.validMD5) ?? true) }) else { throw PersonalCollectionError.invalidData }
        self.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.path, $0) })
        self.pathsByMD5 = Dictionary(grouping: tracks.filter { $0.md5 != nil }, by: { $0.md5! }).mapValues { $0.map(\.path) }
    }

    public func resolve(_ reference: PersonalCollectionReference) throws -> PersonalCollectionResolution {
        guard reference.isValid else { throw PersonalCollectionError.invalidData }
        let atPath = tracks[reference.path]
        guard let md5 = reference.md5 else { return atPath == nil ? .missing : .unverified(reference.path) }
        if atPath?.md5 == md5 { return .exact(reference.path) }
        let matches = pathsByMD5[md5] ?? []
        if matches.count == 1 { return .moved(matches[0]) }
        if matches.count > 1 { return .ambiguous }
        guard let atPath else { return .missing }
        return atPath.md5 == nil ? .unverified(reference.path) : .changed
    }
}
