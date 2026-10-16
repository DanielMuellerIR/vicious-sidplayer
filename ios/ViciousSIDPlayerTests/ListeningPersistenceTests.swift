import XCTest
import ViciousSIDPlayerCore

@MainActor
final class ListeningPersistenceTests: XCTestCase {
    func testDebouncedListeningSaveRunsWithoutAnExplicitFlush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("listening.json"), controller = ListeningLibraryController(fileURL: url)
        for _ in 0..<100 where !controller.isLoaded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(controller.isLoaded)
        controller.activateLibrary("fixture", tracks: [])
        XCTAssertNotNil(controller.createList(name: "Delayed", entries: []))
        for _ in 0..<150 where controller.isSaving || !FileManager.default.fileExists(atPath: url.path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(controller.isSaving)
        XCTAssertEqual(try ListeningLibraryStore(fileURL: url).load().lists.first?.name, "Delayed")
    }
}
