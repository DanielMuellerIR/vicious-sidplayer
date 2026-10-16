import Foundation

public struct PersonalCollectionContext: Sendable {
    public let libraryID: String
    public let name: String
    public let library: MusicLibrary
    public let openedFiles: [PlaylistTrack]
    public init(libraryID: String, name: String, library: MusicLibrary, openedFiles: [PlaylistTrack] = []) {
        self.libraryID = libraryID; self.name = name; self.library = library; self.openedFiles = openedFiles
    }
}

public struct PersonalCollectionCatalog: Equatable, Sendable {
    public let libraryID: String
    public let root: URL
    public let name: String
    public let contents: [String: String]
    public let tracks: [PersonalCollectionCatalogTrack]
    public var resolver: PersonalCollectionResolver { get throws { try .init(tracks: tracks) } }

    public static func read(_ context: PersonalCollectionContext) throws -> Self {
        _ = try context.library.refresh()
        let root = context.library.root.resolvingSymlinksInPath().standardizedFileURL
        var contents: [String: String] = [:], tracks: [PersonalCollectionCatalogTrack] = []
        func metadata(_ url: URL) -> LibraryMetadata? {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= PersonalCollectionCodec.maximumBytes,
                  let bytes = try? Data(contentsOf: url), bytes.count <= PersonalCollectionCodec.maximumBytes else { return nil }
            return try? LibraryMetadata(data: bytes)
        }
        for entry in context.library.entries {
            if Task.isCancelled { throw CancellationError() }
            let resolved = entry.url(relativeTo: root).resolvingSymlinksInPath().standardizedFileURL
            let data = resolved.path.hasPrefix(root.path + "/") ? metadata(resolved) : nil
            contents[entry.id] = data?.md5
            tracks.append(.init(path: entry.id, md5: data?.md5, subtuneCount: data?.subtunes, unavailable: data == nil))
        }
        for track in context.openedFiles where PlaylistTrackID.isExternal(track.id) {
            if Task.isCancelled { throw CancellationError() }
            contents[track.id] = metadata(track.url)?.md5
        }
        _ = try PersonalCollectionResolver(tracks: tracks)
        return .init(libraryID: context.libraryID, root: root, name: context.name, contents: contents, tracks: tracks)
    }
}
