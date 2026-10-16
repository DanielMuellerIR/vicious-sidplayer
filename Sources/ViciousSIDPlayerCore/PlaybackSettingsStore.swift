import Foundation

public final class PlaybackSettingsStore: @unchecked Sendable {
    public static let fileName = "playback-options.json"
    public let fileURL: URL
    private let file: PersonalDataFile

    public init(fileURL: URL) {
        self.fileURL = fileURL
        file = PersonalDataFile(url: fileURL)
    }

    public func load() throws -> PlaybackSettingsDocument {
        try file.load { data in
            try data.map { try JSONDecoder().decode(PlaybackSettingsDocument.self, from: $0).validated() }
                ?? PlaybackSettingsDocument()
        }
    }

    public func save(_ document: PlaybackSettingsDocument) throws {
        try file.write(JSONEncoder().encode(document.validated()))
    }
    public func snapshotBytes() throws -> Data? { try file.snapshot() }
}
