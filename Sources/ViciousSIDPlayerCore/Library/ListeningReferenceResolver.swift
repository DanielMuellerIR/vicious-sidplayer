import Foundation

public enum ListeningReferenceResolution: Equatable, Sendable {
    case found(String), missing, ambiguous
}

public enum ListeningReferenceResolver {
    public static func resolve(_ reference: ListeningPersonalReference, libraryID: String,
                               contents: [String: String]) -> ListeningReferenceResolution {
        if reference.libraryID == libraryID, contents[reference.trackID] == reference.md5 {
            return .found(reference.trackID)
        }
        let candidates = contents.filter { $0.value == reference.md5 }.map(\.key)
        if candidates.count == 1 { return .found(candidates[0]) }
        return candidates.isEmpty ? .missing : .ambiguous
    }
}
