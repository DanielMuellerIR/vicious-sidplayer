import Foundation

@MainActor
public final class PersonalCollectionFavoritesStore {
    private let defaults: UserDefaults?
    private let key: String
    private var file: PersonalDataFile?
    private var values: Set<String> = []
    public private(set) var storageError: String?
    public init(defaults: UserDefaults, key: String) { self.defaults = defaults; self.key = key }
    /// Linux benötigt keine CFPreferences. Die Datei hat denselben Schutz vor
    /// beschädigten oder zwischenzeitlich extern veränderten Daten wie Listen.
    public init(fileURL: URL) {
        defaults = nil; key = ""; file = PersonalDataFile(url: fileURL)
        do { values = try file!.load { data in Set(try data.map { try JSONDecoder().decode([String].self, from: $0) } ?? []) } }
        catch { storageError = error.localizedDescription }
    }
    public func read() -> Set<String> {
        if let defaults { return Set(defaults.stringArray(forKey: key) ?? []) }
        return values
    }
    public func write(_ values: Set<String>) {
        do { try persist(values) } catch { storageError = error.localizedDescription }
    }
    public func persist(_ values: Set<String>) throws {
        if let defaults { defaults.set(values.sorted(), forKey: key); return }
        guard storageError == nil, let file else { throw PersonalDataFileError.readOnly }
        try file.write(JSONEncoder().encode(values.sorted()))
        self.values = values
    }
    public func replace(_ expected: Set<String>, with values: Set<String>) throws {
        guard read() == expected || read() == values else { throw PersonalCollectionTransactionError.externalChange }
        try persist(values)
    }
}

public actor PersonalCollectionStartup {
    private let supportURL: URL?
    private let favorites: PersonalCollectionFavoritesStore
    private var task: Task<Void, Error>?
    public init(supportURL: URL?, favorites: PersonalCollectionFavoritesStore) {
        self.supportURL = supportURL; self.favorites = favorites
    }
    public func ready() async throws {
        if let task { return try await task.value }
        let task = Task { try await recover() }
        self.task = task
        try await task.value
    }
    private func recover() async throws {
        guard let supportURL else { throw ListeningLibraryError.unavailableLocation }
        let transaction = PersonalCollectionTransaction(supportURL: supportURL)
        let current = await favorites.read()
        if case .committed(let values) = try transaction.recover(currentFavorites: current) {
            try await favorites.replace(current, with: values)
            try transaction.finish(currentFavorites: await favorites.read())
        }
    }
}

/// Entwertet auch verzögerte GCD-Aufträge, die erst nach dem Import ankommen.
final class PersonalPersistenceGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func advance() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func matches(_ ticket: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == ticket }
}
