import XCTest
@testable import ViciousSIDPlayerCore

private final class FailingResetFileManager: FileManager, @unchecked Sendable {
    var failMoveAt: Int?
    var moveCount = 0
    var failCleanup = false
    override func moveItem(at source: URL, to destination: URL) throws {
        moveCount += 1
        if moveCount == failMoveAt { throw CocoaError(.fileWriteNoPermission) }
        try super.moveItem(at: source, to: destination)
    }
    override func removeItem(at url: URL) throws {
        if failCleanup && url.lastPathComponent.hasPrefix(".vicious-reset-") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

final class LibraryResetTransactionTests: XCTestCase {
    private func fixture(_ fm: FileManager) throws -> (MusicLibrary, URL) {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = MusicLibrary(root: base.appendingPathComponent("Music"),
                                   supportDirectory: base.appendingPathComponent("Support"), fileManager: fm)
        try Data([1]).write(to: library.root.appendingPathComponent("a.sid"))
        try Data([2]).write(to: library.root.appendingPathComponent("b.sid"))
        try library.refresh()
        try Data([3]).write(to: library.supportDirectory.appendingPathComponent(LibraryReset.cacheFileNames[0]))
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (library, base)
    }

    func testEachFailedMoveRestoresEveryFileIndexAndFavorites() throws {
        for failure in 1...4 {
            let fm = FailingResetFileManager()
            let (library, _) = try fixture(fm)
            let index = try Data(contentsOf: library.indexFileURL)
            let entries = library.entries
            var cleared = false
            fm.failMoveAt = failure
            XCTAssertThrowsError(try LibraryReset.run(library: library) { cleared = true })
            XCTAssertFalse(cleared)
            XCTAssertEqual(library.entries, entries)
            XCTAssertEqual(try Data(contentsOf: library.indexFileURL), index)
            XCTAssertEqual(try Data(contentsOf: library.root.appendingPathComponent("a.sid")), Data([1]))
            XCTAssertEqual(try Data(contentsOf: library.root.appendingPathComponent("b.sid")), Data([2]))
            XCTAssertEqual(try Data(contentsOf: library.supportDirectory.appendingPathComponent(LibraryReset.cacheFileNames[0])), Data([3]))
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: library.root.path).sorted(), ["a.sid", "b.sid"])
        }
    }

    func testUnsafeLaterEntryFailsBeforeAnyFileIsMoved() throws {
        let fm = FailingResetFileManager()
        let (library, base) = try fixture(fm)
        let outside = base.appendingPathComponent("outside.sid")
        try Data([4]).write(to: outside)
        try fm.createSymbolicLink(at: library.root.appendingPathComponent("z.sid"), withDestinationURL: outside)
        XCTAssertThrowsError(try LibraryReset.run(library: library))
        XCTAssertEqual(fm.moveCount, 0)
        XCTAssertEqual(library.entries.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: library.root.appendingPathComponent("a.sid").path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([4]))
    }

    func testCommittedResetReportsRetainedStorageWithoutReindexingIt() throws {
        let fm = FailingResetFileManager()
        let (library, _) = try fixture(fm)
        fm.failCleanup = true
        let report = try LibraryReset.run(library: library)
        XCTAssertEqual(report.retainedCleanupDirectories.count, 2)
        XCTAssertTrue(library.isEmpty)
        try library.refresh()
        XCTAssertTrue(library.isEmpty)
        XCTAssertTrue(report.retainedCleanupDirectories.allSatisfy { fm.fileExists(atPath: $0.path) })
    }
}
