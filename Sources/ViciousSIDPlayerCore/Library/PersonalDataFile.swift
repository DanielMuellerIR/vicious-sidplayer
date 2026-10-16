import Foundation

enum PersonalDataFileError: Error, LocalizedError {
    case readOnly, externalChange, capacityExceeded

    var errorDescription: String? {
        switch self {
        case .readOnly: return NSLocalizedString("Die persönlichen Daten sind schreibgeschützt. Vorhandene Daten bleiben erhalten.", comment: "")
        case .externalChange: return NSLocalizedString("Die persönlichen Daten wurden außerhalb der App geändert. Vorhandene Daten bleiben erhalten; bitte neu laden.", comment: "")
        case .capacityExceeded: return NSLocalizedString("Die persönlichen Daten überschreiten die zulässige Dateigröße. Vorhandene Daten bleiben erhalten.", comment: "")
        }
    }
}

/// Die Vergleichsbasis entsteht erst nach erfolgreichem Dekodieren. Ein späterer
/// Flush darf weder fremde Änderungen noch eine neuere Dateiversion ersetzen.
final class PersonalDataFile: @unchecked Sendable {
    static let maximumBytes = 32 * 1024 * 1024
    let url: URL
    private let lock = NSLock()
    private var loaded = false
    private var writable = false
    private var previousData: Data?

    init(url: URL) { self.url = url }

    func load<Value>(_ decode: (Data?) throws -> Value) throws -> Value {
        lock.lock(); defer { lock.unlock() }
        loaded = true; writable = false
        let data = try readData()
        let value = try decode(data)
        previousData = data; writable = true
        return value
    }

    func write(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= Self.maximumBytes else { throw PersonalDataFileError.capacityExceeded }
        let current = try readData()
        if !loaded {
            // Bestehende Aufrufer dürfen eine neue Ablage direkt anlegen,
            // eine vorhandene aber niemals ohne vorheriges Lesen ersetzen.
            loaded = true
            writable = current == nil
        }
        guard writable else { throw PersonalDataFileError.readOnly }
        guard current == previousData else {
            writable = false
            throw PersonalDataFileError.externalChange
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        previousData = data
    }

    func snapshot() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard loaded, writable else { throw PersonalDataFileError.readOnly }
        guard try readData() == previousData else {
            writable = false
            throw PersonalDataFileError.externalChange
        }
        return previousData
    }

    private func readData() throws -> Data? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(Self.maximumBytes) else {
            throw PersonalDataFileError.capacityExceeded
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumBytes else { throw PersonalDataFileError.capacityExceeded }
        return data
    }
}
