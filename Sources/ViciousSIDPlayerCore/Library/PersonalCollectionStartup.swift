import Foundation

@MainActor
public final class PersonalCollectionFavoritesStore {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults, key: String) { self.defaults = defaults; self.key = key }
    public func read() -> Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    public func write(_ values: Set<String>) { defaults.set(values.sorted(), forKey: key) }
    public func replace(_ expected: Set<String>, with values: Set<String>) throws {
        guard read() == expected || read() == values else { throw PersonalCollectionTransactionError.externalChange }
        write(values)
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
