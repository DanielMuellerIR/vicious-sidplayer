import Foundation

public struct PersonalCollectionCatalogTrack: Equatable, Sendable {
    public let path: String
    public let md5: String?
    public let subtuneCount: Int?
    public let unavailable: Bool
    public init(path: String, md5: String?, subtuneCount: Int? = nil, unavailable: Bool = false) {
        self.path = path; self.md5 = md5?.lowercased(); self.subtuneCount = subtuneCount; self.unavailable = unavailable
    }
}

public enum PersonalCollectionResolution: Equatable, Hashable, Sendable {
    case exact(String), moved(String), unverified(String), missing, changed, ambiguous
    case unavailableSubtune(String, Int)
    case unavailable(String)
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
                  && ($0.md5.map(PersonalCollectionReference.validMD5) ?? true)
                  && ($0.subtuneCount.map { (1...256).contains($0) } ?? true) }) else { throw PersonalCollectionError.invalidData }
        self.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.path, $0) })
        self.pathsByMD5 = Dictionary(grouping: tracks.filter { $0.md5 != nil }, by: { $0.md5! }).mapValues { $0.map(\.path).sorted() }
    }
    public func label(forMD5 md5: String) -> String { pathsByMD5[md5]?.first ?? md5 }

    public func resolve(_ reference: PersonalCollectionReference) throws -> PersonalCollectionResolution {
        guard reference.isValid else { throw PersonalCollectionError.invalidData }
        let atPath = tracks[reference.path]
        guard let md5 = reference.md5 else {
            if atPath?.unavailable == true { return .unavailable(reference.path) }
            if let sub = reference.subtune, let count = atPath?.subtuneCount, sub >= count {
                return .unavailableSubtune(reference.path, count)
            }
            return atPath == nil ? .missing : .unverified(reference.path)
        }
        func confirmed(_ path: String, moved: Bool) -> PersonalCollectionResolution {
            if let sub = reference.subtune, let count = tracks[path]?.subtuneCount, sub >= count { return .unavailableSubtune(path, count) }
            return moved ? .moved(path) : .exact(path)
        }
        if atPath?.md5 == md5 { return confirmed(reference.path, moved: false) }
        let matches = pathsByMD5[md5] ?? []
        if matches.count == 1 { return confirmed(matches[0], moved: true) }
        if matches.count > 1 { return .ambiguous }
        guard let atPath else { return .missing }
        if atPath.unavailable { return .unavailable(reference.path) }
        return atPath.md5 == nil ? .unverified(reference.path) : .changed
    }
}
