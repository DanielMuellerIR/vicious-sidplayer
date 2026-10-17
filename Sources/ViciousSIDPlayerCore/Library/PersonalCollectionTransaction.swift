import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum PersonalCollectionFile: String, Codable, CaseIterable, Sendable {
    case listeningLibrary = "listening-library.json"
    case playbackSettings = "playback-options.json"
    case listeningHistory = "listening-history.json"
}

public struct PersonalCollectionFileChange: Sendable {
    public let file: PersonalCollectionFile
    public let expected: Data?
    public let replacement: Data

    public init(file: PersonalCollectionFile, expected: Data?, replacement: Data) {
        self.file = file; self.expected = expected; self.replacement = replacement
    }
}

public enum PersonalCollectionRecovery: Equatable, Sendable {
    case none, rolledBack, committed(favorites: Set<String>)
}

public enum PersonalCollectionTransactionError: Error, LocalizedError {
    case pendingRecovery, invalidJournal, externalChange, recoveryRequired

    public var errorDescription: String? {
        switch self {
        case .pendingRecovery: return NSLocalizedString("Eine frühere Datenübernahme muss zuerst abgeschlossen werden.", comment: "")
        case .invalidJournal: return NSLocalizedString("Die gesicherte Datenübernahme ist nicht lesbar. Vorhandene Dateien bleiben erhalten.", comment: "")
        case .externalChange: return NSLocalizedString("Persönliche Daten wurden inzwischen geändert. Bitte die Vorschau neu erstellen.", comment: "")
        case .recoveryRequired: return NSLocalizedString("Die Datenübernahme konnte nicht vollständig zurückgesetzt werden. Sicherungen und vorhandene Dateien bleiben für die Wiederherstellung erhalten.", comment: "")
        }
    }
}

/// Nur die drei bekannten persönlichen Ablagen dürfen ausgetauscht werden.
/// Der Aufrufer hält ihre Writer an und übernimmt Favoriten erst nach Commit.
public struct PersonalCollectionTransaction: Sendable {
    let supportURL: URL
    var stagingURL: URL { supportURL.appendingPathComponent(".personal-collection-import", isDirectory: true) }
    private var journalURL: URL { stagingURL.appendingPathComponent("journal.json") }
    private var markerURL: URL { stagingURL.appendingPathComponent("committed") }

    private struct Journal: Codable {
        struct Entry: Codable { let file: PersonalCollectionFile; let beforeMD5: String?; let afterMD5: String }
        let version: Int
        let entries: [Entry]
        let oldFavorites: Set<String>
        let newFavorites: Set<String>
    }

    public init(supportURL: URL) { self.supportURL = supportURL }

    public func prepare(_ changes: [PersonalCollectionFileChange],
                        oldFavorites: Set<String>, newFavorites: Set<String>) throws {
        guard supportURL.isFileURL, !changes.isEmpty || oldFavorites != newFavorites,
              Set(changes.map(\.file)).count == changes.count else { throw PersonalCollectionTransactionError.invalidJournal }
        guard !FileManager.default.fileExists(atPath: stagingURL.path) else { throw PersonalCollectionTransactionError.pendingRecovery }
        let journal = Journal(version: 1, entries: changes.map {
            .init(file: $0.file, beforeMD5: $0.expected.map { SonglengthDB.md5Hex(of: $0) },
                  afterMD5: SonglengthDB.md5Hex(of: $0.replacement))
        },
                              oldFavorites: oldFavorites, newFavorites: newFavorites)
        try validate(journal)
        for change in changes {
            guard change.replacement.count <= PersonalDataFile.maximumBytes,
                  (change.expected?.count ?? 0) <= PersonalDataFile.maximumBytes else { throw PersonalDataFileError.capacityExceeded }
            try validateReplacement(change.replacement, file: change.file)
            if let expected = change.expected { try validateReplacement(expected, file: change.file) }
            guard try read(change.file, stagedSuffix: nil) == change.expected else { throw PersonalCollectionTransactionError.externalChange }
        }
        let journalBytes = try JSONEncoder().encode(journal)
        guard journalBytes.count <= PersonalDataFile.maximumBytes else { throw PersonalDataFileError.capacityExceeded }
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        let preparingURL = supportURL.appendingPathComponent(".personal-collection-prepare-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: preparingURL, withIntermediateDirectories: false)
        do {
            try Data("vicioussid.personal-collection:1".utf8).write(to: preparingURL.appendingPathComponent("owner"), options: .atomic)
            for change in changes {
                if let original = change.expected { try original.write(to: preparingURL.appendingPathComponent(change.file.rawValue + ".before"), options: .atomic) }
                try change.replacement.write(to: preparingURL.appendingPathComponent(change.file.rawValue + ".after"), options: .atomic)
            }
            try journalBytes.write(to: preparingURL.appendingPathComponent("journal.json"), options: .atomic)
            // Recovery sieht erst den vollständigen Ordner. Ein Prozessende
            // während der Vorbereitung darf den nächsten Appstart nicht sperren.
            try FileManager.default.moveItem(at: preparingURL, to: stagingURL)
        } catch {
            try? FileManager.default.removeItem(at: preparingURL)
            throw error
        }
    }

    @discardableResult
    public func commit(currentFavorites: Set<String>) throws -> Set<String> {
        try commit(currentFavorites: currentFavorites, beforeReplace: { _ in })
    }

    func commit(currentFavorites: Set<String>, beforeReplace: (Int) throws -> Void) throws -> Set<String> {
        let journal = try loadJournal()
        guard !FileManager.default.fileExists(atPath: markerURL.path) else { throw PersonalCollectionTransactionError.pendingRecovery }
        // Vor dem ersten Austausch darf ein veralteter Entwurf folgenlos weg.
        do {
            guard currentFavorites == journal.oldFavorites else { throw PersonalCollectionTransactionError.externalChange }
            for entry in journal.entries {
                guard try read(entry.file, stagedSuffix: nil) == original(entry) else { throw PersonalCollectionTransactionError.externalChange }
                _ = try replacement(entry)
            }
        } catch {
            // Ein erneuter Commit nach Prozessende darf die Sicherung eines
            // bereits teilweise ausgeführten Austauschs nicht beseitigen.
            let unapplied = (try? journal.entries.allSatisfy { entry in
                let current = try read(entry.file, stagedSuffix: nil)
                let before = try original(entry), after = try replacement(entry)
                return current != after || before == after
            }) ?? false
            if unapplied { try? FileManager.default.removeItem(at: stagingURL) }
            throw error
        }
        do {
            for (index, entry) in journal.entries.enumerated() {
                try beforeReplace(index)
                guard try read(entry.file, stagedSuffix: nil) == original(entry) else { throw PersonalCollectionTransactionError.externalChange }
                try replacement(entry).write(to: supportURL.appendingPathComponent(entry.file.rawValue), options: .atomic)
            }
            try Data("1".utf8).write(to: markerURL, options: .atomic)
            return journal.newFavorites
        } catch {
            do { _ = try recover(currentFavorites: currentFavorites) }
            catch { throw PersonalCollectionTransactionError.recoveryRequired }
            throw error
        }
    }

    /// Vor dem Laden der Controller aufrufen. Ein vollständiger Commit wartet
    /// auf das idempotente Setzen der Favoriten und den anschließenden Abschluss.
    public func recover(currentFavorites: Set<String>) throws -> PersonalCollectionRecovery {
        guard FileManager.default.fileExists(atPath: stagingURL.path) else { return .none }
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            // Ältere Versionen konnten vor dem owner-Schreiben einen leeren
            // Ordner hinterlassen. rmdir schützt inzwischen abgelegte Inhalte
            // und Symlinks, statt sie rekursiv zu entfernen.
            if rmdir(stagingURL.path) == 0 { return .rolledBack }
            let owner = try Data(contentsOf: stagingURL.appendingPathComponent("owner"))
            guard owner == Data("vicioussid.personal-collection:1".utf8) else { throw PersonalCollectionTransactionError.invalidJournal }
            try FileManager.default.removeItem(at: stagingURL)
            return .rolledBack
        }
        let journal = try loadJournal()
        let committed = FileManager.default.fileExists(atPath: markerURL.path)
        if committed {
            guard try Data(contentsOf: markerURL) == Data("1".utf8),
                  currentFavorites == journal.oldFavorites || currentFavorites == journal.newFavorites else {
                throw PersonalCollectionTransactionError.externalChange
            }
        }
        // Alle Dateien prüfen, bevor eine einzige zurückgeschrieben wird.
        // Fremde Änderungen machen die Wiederherstellung ausdrücklich offen.
        for entry in journal.entries {
            let current = try read(entry.file, stagedSuffix: nil)
            let after = try replacement(entry)
            let before = try original(entry)
            guard committed ? current == after : current == before || current == after else {
                throw PersonalCollectionTransactionError.externalChange
            }
        }
        if committed { return .committed(favorites: journal.newFavorites) }
        for entry in journal.entries {
            let before = try original(entry)
            let current = try read(entry.file, stagedSuffix: nil)
            if current == before { continue }
            guard try current == replacement(entry) else { throw PersonalCollectionTransactionError.externalChange }
            let url = supportURL.appendingPathComponent(entry.file.rawValue)
            if let before { try before.write(to: url, options: .atomic) }
            else { try FileManager.default.removeItem(at: url) }
        }
        try FileManager.default.removeItem(at: stagingURL)
        return .rolledBack
    }

    public func finish(currentFavorites: Set<String>) throws {
        guard case .committed(let favorites) = try recover(currentFavorites: currentFavorites),
              favorites == currentFavorites else { throw PersonalCollectionTransactionError.pendingRecovery }
        try FileManager.default.removeItem(at: stagingURL)
    }

    private func loadJournal() throws -> Journal {
        guard let bytes = try boundedRead(journalURL) else { throw PersonalCollectionTransactionError.invalidJournal }
        let journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: bytes) }
        catch { throw PersonalCollectionTransactionError.invalidJournal }
        try validate(journal)
        return journal
    }

    private func validate(_ journal: Journal) throws {
        func validFavorites(_ values: Set<String>) -> Bool {
            values.count <= 200_000 && values.allSatisfy { !$0.isEmpty && $0.count <= 8192 && !$0.contains("\0") }
        }
        func validMD5(_ value: String) -> Bool {
            value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard journal.version == 1, journal.entries.count <= PersonalCollectionFile.allCases.count,
              Set(journal.entries.map(\.file)).count == journal.entries.count,
              journal.entries.allSatisfy({ validMD5($0.afterMD5) && ($0.beforeMD5.map(validMD5) ?? true) }),
              validFavorites(journal.oldFavorites), validFavorites(journal.newFavorites) else {
            throw PersonalCollectionTransactionError.invalidJournal
        }
    }

    private func validateReplacement(_ data: Data, file: PersonalCollectionFile) throws {
        switch file {
        case .listeningLibrary: try JSONDecoder().decode(ListeningLibraryDocument.self, from: data).validate()
        case .playbackSettings: _ = try JSONDecoder().decode(PlaybackSettingsDocument.self, from: data).validated()
        case .listeningHistory: _ = try JSONDecoder().decode(ListeningHistoryDocument.self, from: data).validated()
        }
    }

    private func staged(_ file: PersonalCollectionFile, _ suffix: String) -> URL {
        stagingURL.appendingPathComponent(file.rawValue + "." + suffix)
    }
    private func requiredStaged(_ file: PersonalCollectionFile, _ suffix: String) throws -> Data {
        guard let data = try read(file, stagedSuffix: suffix) else { throw PersonalCollectionTransactionError.invalidJournal }
        return data
    }
    private func original(_ entry: Journal.Entry) throws -> Data? {
        guard let checksum = entry.beforeMD5 else {
            guard try read(entry.file, stagedSuffix: "before") == nil else { throw PersonalCollectionTransactionError.invalidJournal }
            return nil
        }
        let data = try requiredStaged(entry.file, "before")
        guard SonglengthDB.md5Hex(of: data) == checksum else { throw PersonalCollectionTransactionError.invalidJournal }
        try validateReplacement(data, file: entry.file)
        return data
    }
    private func replacement(_ entry: Journal.Entry) throws -> Data {
        let data = try requiredStaged(entry.file, "after")
        guard SonglengthDB.md5Hex(of: data) == entry.afterMD5 else { throw PersonalCollectionTransactionError.invalidJournal }
        try validateReplacement(data, file: entry.file)
        return data
    }
    private func read(_ file: PersonalCollectionFile, stagedSuffix: String?) throws -> Data? {
        try boundedRead(stagedSuffix.map { staged(file, $0) } ?? supportURL.appendingPathComponent(file.rawValue))
    }
    private func boundedRead(_ url: URL) throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(PersonalDataFile.maximumBytes) else {
            throw PersonalDataFileError.capacityExceeded
        }
        let data = try Data(contentsOf: url)
        guard data.count <= PersonalDataFile.maximumBytes else { throw PersonalDataFileError.capacityExceeded }
        return data
    }
}
