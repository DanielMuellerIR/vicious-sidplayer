import XCTest
@testable import ViciousSIDPlayerCore

final class FileFavoritesTests: XCTestCase {
    @MainActor
    func testFileFavoritesRoundTripAndExternalChangeProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("favorites.json")
        let store = PersonalCollectionFavoritesStore(fileURL: url)
        try store.persist(["Composer/Track.sid", "Other/Track.sid"])
        let reopened = PersonalCollectionFavoritesStore(fileURL: url)
        XCTAssertEqual(reopened.read(), ["Composer/Track.sid", "Other/Track.sid"])
        let external = Data("[\"External.sid\"]".utf8)
        try external.write(to: url)
        XCTAssertThrowsError(try reopened.replace(reopened.read(), with: ["Replacement.sid"]))
        XCTAssertEqual(try Data(contentsOf: url), external)
    }

    @MainActor
    func testDamagedFavoritesRemainUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("favorites.json"), bytes = Data("not-json".utf8)
        try bytes.write(to: url)
        let store = PersonalCollectionFavoritesStore(fileURL: url)
        XCTAssertNotNil(store.storageError)
        XCTAssertThrowsError(try store.persist(["Track.sid"]))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
}
