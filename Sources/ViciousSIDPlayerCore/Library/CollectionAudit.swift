import Foundation

public enum CollectionAuditKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case damaged, unsupported, duplicate, missingSTIL, missingLength, missing, moved, ambiguous, changed, unverified
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .damaged: return NSLocalizedString("Beschädigt oder nicht lesbar", comment: "")
        case .unsupported: return NSLocalizedString("Nicht unterstützt", comment: "")
        case .duplicate: return NSLocalizedString("Identischer Dateiinhalt", comment: "")
        case .missingSTIL: return NSLocalizedString("Keine STIL-Zuordnung", comment: "")
        case .missingLength: return NSLocalizedString("Unbekannte Spieldauer", comment: "")
        case .missing: return NSLocalizedString("Nicht wiedergefunden", comment: "")
        case .moved: return NSLocalizedString("Wiedergefunden", comment: "")
        case .ambiguous: return NSLocalizedString("Mehrdeutige Zuordnung", comment: "")
        case .changed: return NSLocalizedString("Dateiinhalt geändert", comment: "")
        case .unverified: return NSLocalizedString("Dateiidentität unbekannt", comment: "")
        }
    }
}

public struct CollectionAuditIssue: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: CollectionAuditKind
    public let paths: [String]
    public let detail: String
    public let reference: PersonalCollectionReference?
    public let proposedPath: String?
    public let canRepair: Bool
}

public struct CollectionAuditMetadata: Sendable {
    public var stil: STILDatabase?
    public var stilRoot: URL?
    public var lengths: SonglengthDB?
    public var cache: SongLengthCache?
    public var resolver: SongLengthResolver?
    public var clockMode: SidClockMode
    public var knownContents: [String: String]
    public init(stil: STILDatabase? = nil, stilRoot: URL? = nil, lengths: SonglengthDB? = nil,
                cache: SongLengthCache? = nil, resolver: SongLengthResolver? = nil,
                clockMode: SidClockMode = .auto, knownContents: [String: String] = [:]) {
        self.stil = stil; self.stilRoot = stilRoot; self.lengths = lengths; self.cache = cache
        self.clockMode = clockMode; self.knownContents = knownContents
        self.resolver = resolver
    }
}

public struct CollectionAuditReport: Sendable {
    public let catalog: PersonalCollectionCatalog
    public let issues: [CollectionAuditIssue]
    public let fileCount: Int
    public let validCount: Int
    public let hasSTIL: Bool
    public let hasLengths: Bool
    public let inventoryWarning: String?
    public let knownContents: [String: String]
    public let baseline: PersonalCollectionSnapshot
    public var repairs: [CollectionAuditIssue] { issues.filter(\.canRepair) }
}

/// Die Inventur liest Dateien erneut; ein alter Index allein belegt weder
/// Duplikate noch eine verschobene Datei. Musikdateien bleiben unangetastet.
public enum CollectionAudit {
    public static let maximumFileBytes = 32 * 1024 * 1024
    private struct Inventory: Codable { var version = 1; let contents: [String: String] }

    public static func exportReport(_ report: CollectionAuditReport) throws -> Data {
        struct Document: Encodable {
            let format = "vicioussid.collection-audit", version = 1
            let createdAt: Date, collectionName: String, fileCount: Int, validCount: Int
            let hasSTIL: Bool, hasLengths: Bool
            let issues: [CollectionAuditIssue]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Document(createdAt: Date(), collectionName: report.catalog.name,
            fileCount: report.fileCount, validCount: report.validCount, hasSTIL: report.hasSTIL,
            hasLengths: report.hasLengths, issues: report.issues))
    }

    public static func run(context: PersonalCollectionContext, snapshot: PersonalCollectionSnapshot,
                           metadata: CollectionAuditMetadata = .init(),
                           progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> CollectionAuditReport {
        try Task.checkCancellation()
        let root = context.library.root.resolvingSymlinksInPath().standardizedFileURL
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw MusicLibraryError.scanFailed(NSLocalizedString("Der Sammlungsordner ist nicht erreichbar.", comment: ""))
        }
        let entries = try context.library.scan()
        let inventoryURL = context.library.supportDirectory.appendingPathComponent("audit-" + context.library.indexFileName)
        var previous = metadata.knownContents.filter {
            PersonalCollectionReference.validPath($0.key) && PersonalCollectionReference.validMD5($0.value)
        }, warning: String?, canSave = true
        if FileManager.default.fileExists(atPath: inventoryURL.path) {
            do {
                let document = try JSONDecoder().decode(Inventory.self, from: readBounded(inventoryURL))
                guard document.version == 1, document.contents.count <= 200_000,
                      document.contents.allSatisfy({ PersonalCollectionReference.validPath($0.key)
                          && PersonalCollectionReference.validMD5($0.value) }) else { throw PersonalCollectionError.invalidData }
                previous = document.contents.merging(previous, uniquingKeysWith: { _, latest in latest })
            } catch is CancellationError { throw CancellationError() }
            catch {
                warning = NSLocalizedString("Die frühere Prüfinventur ist nicht lesbar und bleibt erhalten. Wiederfinden nutzt nur belegte Dateiidentitäten.", comment: "")
                canSave = false
            }
        }
        var issues: [CollectionAuditIssue] = [], tracks: [PersonalCollectionCatalogTrack] = []
        var contents: [String: String] = [:], allDigests: [String: [String]] = [:]
        func issue(_ kind: CollectionAuditKind, _ paths: [String], _ detail: String, suffix: String = "") {
            issues.append(.init(id: kind.rawValue + ":" + (paths.first ?? "") + suffix, kind: kind,
                paths: paths, detail: detail, reference: nil, proposedPath: nil, canRepair: false))
        }
        progress(0, entries.count)
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let url = entry.url(relativeTo: root).resolvingSymlinksInPath().standardizedFileURL
            var parsed: LibraryMetadata?
            do {
                guard LibraryPath.isContained(url, in: root) else { throw PersonalCollectionError.invalidData }
                let bytes = try readBounded(url)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard bytes.count == entry.fileSize, values.fileSize == entry.fileSize,
                      values.contentModificationDate == entry.modificationDate else {
                    throw ReadError.changedFile
                }
                let digest = SonglengthDB.md5Hex(of: bytes)
                allDigests[digest, default: []].append(entry.id)
                parsed = try LibraryMetadata(data: bytes)
                contents[entry.id] = digest
                if let stil = metadata.stil,
                   stil.resolvedPath(forFileURL: url, hvscRoot: metadata.stilRoot, relativePath: entry.id) == nil {
                    issue(.missingSTIL, [entry.id], NSLocalizedString("Kein eindeutiger STIL-Pfad gefunden. Anmerkungen sind nicht für jeden Titel vorhanden.", comment: ""))
                }
                if let parsed {
                    let unknown = (0..<parsed.subtunes).filter { subtune in
                        let personal = snapshot.playback.endTime(md5: digest, subtune: subtune)
                        return (metadata.resolver?.knownDuration(md5: digest, subtune: subtune,
                            databaseLengths: metadata.lengths?.lengths(forMD5: digest), clockMode: metadata.clockMode, personalDuration: personal)
                            ?? SongLengthSelection.knownDuration(databaseLengths: metadata.lengths?.lengths(forMD5: digest), subtune: subtune,
                            computed: metadata.cache?.length(md5: digest, subtune: subtune, clockMode: metadata.clockMode),
                            personalDuration: personal)) == nil
                    }
                    if !unknown.isEmpty {
                        issue(.missingLength, [entry.id], String(format: NSLocalizedString("Für %d von %d Subtunes ist nur die Fallback-Dauer verfügbar.", comment: ""), unknown.count, parsed.subtunes))
                    }
                }
            } catch is CancellationError { throw CancellationError() }
            catch SidParser.ParserError.invalidVersion {
                issue(.unsupported, [entry.id], NSLocalizedString("Diese PSID-/RSID-Version wird vom Player nicht unterstützt.", comment: ""))
            } catch PersonalCollectionError.capacityExceeded {
                issue(.unsupported, [entry.id], NSLocalizedString("SID-Dateien über 32 MiB werden nicht eingelesen.", comment: ""))
            } catch {
                issue(.damaged, [entry.id], NSLocalizedString("Die Datei ist kein lesbarer SID-Titel oder wurde während der Prüfung geändert.", comment: ""))
            }
            tracks.append(.init(path: entry.id, md5: parsed?.md5, subtuneCount: parsed?.subtunes, unavailable: parsed == nil))
            if index.isMultiple(of: 128) || index == entries.count - 1 { progress(index + 1, entries.count) }
        }
        for (digest, paths) in allDigests where paths.count > 1 {
            issue(.duplicate, paths.sorted(), NSLocalizedString("Die vollständigen Dateiinhalte sind identisch. Alle Dateien bleiben erhalten.", comment: ""), suffix: digest)
        }
        let resolver = try PersonalCollectionResolver(tracks: tracks)
        let references = references(snapshot, libraryID: context.libraryID, knownContents: previous)
        let personalReferences = Self.references(snapshot, libraryID: context.libraryID, knownContents: previous, includeInventory: false)
        for reference in references {
            try Task.checkCancellation()
            let resolution = try resolver.resolve(reference)
            let kind: CollectionAuditKind, proposed: String?
            switch resolution {
            case .exact: continue
            case .unverified: continue
            case .moved(let path): kind = .moved; proposed = path
            case .ambiguous: kind = .ambiguous; proposed = nil
            case .changed: kind = .changed; proposed = nil
            case .missing: kind = reference.md5 == nil ? .unverified : .missing; proposed = nil
            case .unavailable, .unavailableSubtune: kind = .missing; proposed = nil
            }
            let key = reference.path + ":" + (reference.md5 ?? "") + ":" + String(reference.subtune ?? -1)
            issues.append(.init(id: "reference:" + key, kind: kind, paths: [reference.path],
                detail: proposed.map { NSLocalizedString("Identischer Dateiinhalt gefunden: ", comment: "") + $0 }
                    ?? NSLocalizedString("Persönlicher Verweis oder frühere Inventur; keine automatische Zuordnung.", comment: ""),
                reference: reference, proposedPath: proposed, canRepair: proposed != nil && personalReferences.contains(reference)))
        }
        try Task.checkCancellation()
        if canSave {
            do {
                let needed = Set(snapshot.favorites).union(snapshot.listening.lists
                    .filter { $0.libraryID == context.libraryID }.flatMap { $0.entries.map(\.trackID) })
                let retained = previous.filter { needed.contains($0.key) && contents[$0.key] == nil }
                let inventory = retained.merging(contents, uniquingKeysWith: { _, current in current })
                guard inventory.count <= 200_000 else { throw PersonalCollectionError.capacityExceeded }
                let data = try JSONEncoder().encode(Inventory(contents: inventory))
                guard data.count <= maximumFileBytes else { throw PersonalCollectionError.capacityExceeded }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: inventoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: inventoryURL, options: .atomic)
            } catch is CancellationError { throw CancellationError() }
            catch { warning = NSLocalizedString("Die Prüfinventur konnte nicht gespeichert werden. Der Bericht ist vollständig; Musikdateien bleiben erhalten.", comment: "") }
        }
        let catalog = PersonalCollectionCatalog(libraryID: context.libraryID, root: root, name: context.name, contents: contents, tracks: tracks)
        return .init(catalog: catalog, issues: issues.sorted { $0.id < $1.id }, fileCount: entries.count,
            validCount: contents.count, hasSTIL: metadata.stil != nil, hasLengths: metadata.lengths != nil,
            inventoryWarning: warning, knownContents: previous, baseline: snapshot)
    }

    static func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw PersonalCollectionError.invalidData }
        guard let size = values.fileSize, size <= maximumFileBytes else { throw PersonalCollectionError.capacityExceeded }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            guard result.count <= maximumFileBytes - chunk.count else { throw PersonalCollectionError.capacityExceeded }
            result.append(chunk)
        }
        return result
    }

    static func references(_ source: PersonalCollectionSnapshot, libraryID: String, knownContents: [String: String], includeInventory: Bool = true) -> Set<PersonalCollectionReference> {
        var result = Set((includeInventory ? knownContents : [:]).filter { PersonalCollectionReference.validPath($0.key) }.map {
            PersonalCollectionReference(path: $0.key, md5: $0.value)
        })
        for path in source.favorites where PersonalCollectionReference.validPath(path) {
            result.insert(.init(path: path, md5: knownContents[path]))
        }
        for list in source.listening.lists where list.libraryID == libraryID {
            for entry in list.entries where PersonalCollectionReference.validPath(entry.trackID) {
                result.insert(.init(path: entry.trackID, md5: knownContents[entry.trackID], subtune: entry.subtune))
            }
        }
        for reference in (source.history.events.map(\.reference) + source.history.bookmarks.map(\.reference) + source.history.notes.map(\.reference))
            where reference.libraryID == libraryID && PersonalCollectionReference.validPath(reference.trackID) {
            result.insert(.init(path: reference.trackID, md5: reference.md5, subtune: reference.subtune))
        }
        return result
    }

    private enum ReadError: Error { case changedFile }
}
