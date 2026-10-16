import Foundation

public enum LibraryChipModel: Int, Codable, Sendable, CaseIterable {
    case unknown = 0, mos6581, mos8580, either
}

/// Dateimetadaten enthalten keine Wiedergabe-Overrides. Unbekannte Headerfelder
/// bleiben unbekannt, auch wenn der Emulator dafuer einen Fallback verwendet.
public struct LibraryMetadata: Codable, Equatable, Sendable {
    public let title: String?
    public let author: String?
    public let released: String?
    public let chipModels: [LibraryChipModel]
    public let subtunes: Int
    public let md5: String
    let normalizedTitle: String
    let normalizedAuthor: String
    let normalizedReleased: String
    public var chipCount: Int { chipModels.count }

    public init(data: Data) throws {
        let bytes = data.startIndex == 0 ? data : Data(data)
        let sid = try SidParser.parse(data: bytes)
        func text(_ range: Range<Int>, parsed: String) -> String? {
            let raw = bytes[range].prefix { $0 != 0 }
            return raw.allSatisfy { $0 == 32 || $0 == 9 } ? nil : parsed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        title = text(0x16..<0x36, parsed: sid.metadata.title)
        author = text(0x36..<0x56, parsed: sid.metadata.author)
        released = text(0x56..<0x76, parsed: sid.metadata.info)
        let flags = bytes.count >= 0x7C && bytes[5] >= 2 ? Int(bytes[0x76]) << 8 | Int(bytes[0x77]) : 0
        var models = [LibraryChipModel(rawValue: (flags >> 4) & 3)!]
        if sid.secondSidAddress != 0 { models.append(LibraryChipModel(rawValue: (flags >> 6) & 3)!) }
        if sid.thirdSidAddress != 0 { models.append(LibraryChipModel(rawValue: (flags >> 8) & 3)!) }
        chipModels = models
        subtunes = sid.subtuneAmount
        md5 = SonglengthDB.md5Hex(of: bytes)
        normalizedTitle = LibrarySearchText.normalize(title ?? "")
        normalizedAuthor = LibrarySearchText.normalize(author ?? "")
        normalizedReleased = LibrarySearchText.normalize(released ?? "")
    }

    /// Dauer von Subtune 1. Das Fallback ist keine bekannte Musiklaenge.
    public func firstSubtuneDuration(database: SonglengthDB?, cache: SongLengthCache?, clockMode: SidClockMode = .auto, personalDuration: Double? = nil) -> Double? {
        SongLengthSelection.knownDuration(databaseLengths: database?.lengths(forMD5: md5), subtune: 0,
            computed: cache?.length(md5: md5, subtune: 0, clockMode: clockMode), personalDuration: personalDuration)
    }

    public var modelDescription: String {
        chipModels.map { model in
            switch model {
            case .unknown: return NSLocalizedString("Modell unbekannt", comment: "")
            case .mos6581: return "6581"
            case .mos8580: return "8580"
            case .either: return "6581/8580"
            }
        }.joined(separator: " + ")
    }

    public static func durationDescription(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return NSLocalizedString("Dauer unbekannt", comment: "") }
        guard seconds < Double(Int.max) else { return String(format: "%.3g s", seconds) }
        return "\(Int(seconds) / 60):" + String(format: "%02d", Int(seconds) % 60)
    }
}

public struct LibraryMetadataRecord: Codable, Equatable, Sendable {
    public let fileSize: Int
    public let modificationDate: Date
    public let metadata: LibraryMetadata?
    public let unavailable: Bool
    let normalizedName: String
    let normalizedFolderPath: String
    public init(fileSize: Int, modificationDate: Date, metadata: LibraryMetadata?, unavailable: Bool = false,
                name: String = "", folderPath: String = "") {
        self.fileSize = fileSize; self.modificationDate = modificationDate; self.metadata = metadata; self.unavailable = unavailable
        normalizedName = LibrarySearchText.normalize(name); normalizedFolderPath = LibrarySearchText.normalize(folderPath)
    }
    public func matches(_ entry: MusicLibraryEntry) -> Bool {
        fileSize == entry.fileSize && modificationDate == entry.modificationDate
    }
}

/// Ein Cache je Bibliothekswurzel; der Actor serialisiert Lesen und Schreiben.
/// Die Dateiliste bleibt sofort verfuegbar, waehrend dieser Cache ergaenzt wird.
public actor LibraryMetadataCache {
    private struct Document: Codable {
        var version = 1
        var records: [String: LibraryMetadataRecord]
    }
    public let root: URL
    public let fileURL: URL
    private let rootComponents: [String]
    private var records: [String: LibraryMetadataRecord]?
    public private(set) var storageError: String?
    private var needsSave = false

    public init(root: URL, supportDirectory: URL, indexFileName: String? = nil) {
        self.root = root
        rootComponents = LibraryPath.normalizedComponents(root)
        let key = indexFileName ?? MusicLibrary.indexFileName(forRoot: root)
        fileURL = supportDirectory.appendingPathComponent("metadata-" + key)
    }

    public func cachedRecords(for entries: [MusicLibraryEntry]) -> [String: LibraryMetadataRecord] {
        if records == nil {
            let document = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Document.self, from: $0) }
            records = document?.version == 1 ? document?.records : [:]
        }
        let source = records ?? [:]
        return Dictionary(entries.compactMap { entry in
            guard isValid(entry), let record = source[entry.id], record.matches(entry), !record.unavailable else { return nil }
            return (entry.id, record)
        }, uniquingKeysWith: { first, _ in first })
    }

    public func refresh(entries: [MusicLibraryEntry], progress: @Sendable (Int) -> Void = { _ in }) throws -> [String: LibraryMetadataRecord] {
        var next = cachedRecords(for: entries)
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            guard isValid(entry) else { continue }
            if next[entry.id] == nil {
                let url = entry.url(relativeTo: root)
                guard LibraryPath.relativePath(of: url, underRootComponents: rootComponents) != nil else { continue }
                let data = try? Data(contentsOf: url)
                if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                   values.fileSize != entry.fileSize || values.contentModificationDate != entry.modificationDate { continue }
                let metadata = data.flatMap { try? LibraryMetadata(data: $0) }
                next[entry.id] = LibraryMetadataRecord(fileSize: entry.fileSize, modificationDate: entry.modificationDate, metadata: metadata,
                    unavailable: data == nil, name: entry.displayName, folderPath: entry.folderPath)
            }
            if index.isMultiple(of: 512) { progress(index + 1) }
        }
        try Task.checkCancellation()
        if next != records || needsSave {
            records = next
            do {
                let data = try JSONEncoder().encode(Document(records: next))
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                storageError = nil; needsSave = false
            } catch {
                storageError = error.localizedDescription; needsSave = true
            }
        }
        progress(entries.count)
        return next
    }

    private func isValid(_ entry: MusicLibraryEntry) -> Bool {
        let path = entry.relativePath
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && path.lowercased().hasSuffix("." + SidFileType.fileExtension)
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            && entry.fileSize >= 0 && entry.modificationDate.timeIntervalSinceReferenceDate.isFinite
    }
}
