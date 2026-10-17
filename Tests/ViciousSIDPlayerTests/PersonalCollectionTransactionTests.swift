import XCTest
@testable import ViciousSIDPlayerCore

final class PersonalCollectionTransactionTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let changes: [PersonalCollectionFileChange]
        var transaction: PersonalCollectionTransaction { .init(supportURL: root) }
    }

    private func fixture(firstExists: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lists = try JSONEncoder().encode(ListeningLibraryDocument())
        let importedLists = try JSONEncoder().encode(ListeningLibraryDocument(lists: [SavedListeningList(libraryID: "target", name: "Imported")]))
        let settings = try JSONEncoder().encode(PlaybackSettingsDocument())
        var imported = PlaybackSettingsDocument()
        try imported.setEndTime(125.25, md5: String(repeating: "a", count: 32), subtune: 2)
        if firstExists { try lists.write(to: root.appendingPathComponent(PersonalCollectionFile.listeningLibrary.rawValue)) }
        try settings.write(to: root.appendingPathComponent(PersonalCollectionFile.playbackSettings.rawValue))
        return Fixture(root: root, changes: [
            .init(file: .listeningLibrary, expected: firstExists ? lists : nil, replacement: importedLists),
            .init(file: .playbackSettings, expected: settings, replacement: try JSONEncoder().encode(imported))
        ])
    }

    private func assertOriginals(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        for change in fixture.changes {
            let url = fixture.root.appendingPathComponent(change.file.rawValue)
            if let original = change.expected { XCTAssertEqual(try Data(contentsOf: url), original, file: file, line: line) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), file: file, line: line) }
        }
    }

    func testSecondWriteFailureRestoresOriginalBytesAndRemovesNewFiles() throws {
        enum Failure: Error { case secondFile }
        for firstExists in [true, false] {
            let f = try fixture(firstExists: firstExists); defer { try? FileManager.default.removeItem(at: f.root) }
            try f.transaction.prepare(f.changes, oldFavorites: ["Old.sid"], newFavorites: ["Old.sid", "Imported.sid"])
            XCTAssertThrowsError(try f.transaction.commit(currentFavorites: ["Old.sid"], beforeReplace: { index in
                if index == 1 { throw Failure.secondFile }
            }))
            try assertOriginals(f)
            XCTAssertEqual(try f.transaction.recover(currentFavorites: ["Old.sid"]), .none)
        }
    }

    func testRestartBeforeOwnershipWasWrittenRecoversOnlyAnEmptyLegacyDirectory() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.transaction.stagingURL, withIntermediateDirectories: false)
        XCTAssertEqual(try f.transaction.recover(currentFavorites: []), .rolledBack)
        try assertOriginals(f)
        try f.transaction.prepare(f.changes, oldFavorites: [], newFavorites: [])
        XCTAssertEqual(try f.transaction.recover(currentFavorites: []), .rolledBack)
        try assertOriginals(f)
    }

    func testOwnerlessContentsAndUnpublishedPreparationRemainProtected() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let preparing = f.root.appendingPathComponent(".personal-collection-prepare-interrupted")
        try FileManager.default.createDirectory(at: preparing, withIntermediateDirectories: false)
        XCTAssertEqual(try f.transaction.recover(currentFavorites: []), .none)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparing.path))
        try FileManager.default.createDirectory(at: f.transaction.stagingURL, withIntermediateDirectories: false)
        let unknown = f.transaction.stagingURL.appendingPathComponent("unknown"), bytes = Data("preserve".utf8)
        try bytes.write(to: unknown)
        XCTAssertThrowsError(try f.transaction.recover(currentFavorites: []))
        XCTAssertEqual(try Data(contentsOf: unknown), bytes)
        try assertOriginals(f)
    }

    func testRestartBetweenFileReplacementsRollsBackWithoutChangingFavorites() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.transaction.prepare(f.changes, oldFavorites: ["Old.sid"], newFavorites: ["Imported.sid"])
        // Zustand eines Prozessendes nach dem ersten atomaren Dateitausch.
        try f.changes[0].replacement.write(to: f.root.appendingPathComponent(f.changes[0].file.rawValue), options: .atomic)
        let restarted = PersonalCollectionTransaction(supportURL: f.root)
        XCTAssertThrowsError(try restarted.commit(currentFavorites: ["Old.sid"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restarted.stagingURL.path))
        XCTAssertEqual(try restarted.recover(currentFavorites: ["Old.sid"]), .rolledBack)
        try assertOriginals(f)
        XCTAssertEqual(try restarted.recover(currentFavorites: ["Old.sid"]), .none)
    }

    func testCommittedRestartFinishesFavoritesIdempotentlyBeforeRemovingBackups() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old: Set<String> = ["Old.sid"], new: Set<String> = ["Old.sid", "Imported.sid"]
        try f.transaction.prepare(f.changes, oldFavorites: old, newFavorites: new)
        XCTAssertEqual(try f.transaction.commit(currentFavorites: old), new)
        let restarted = PersonalCollectionTransaction(supportURL: f.root)
        XCTAssertEqual(try restarted.recover(currentFavorites: old), .committed(favorites: new))
        XCTAssertThrowsError(try restarted.finish(currentFavorites: old))
        XCTAssertEqual(try restarted.recover(currentFavorites: new), .committed(favorites: new))
        for change in f.changes {
            XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(change.file.rawValue)), change.replacement)
        }
        try restarted.finish(currentFavorites: new)
        XCTAssertEqual(try restarted.recover(currentFavorites: new), .none)
    }

    func testExternalChangeBeforeCommitCancelsWithoutReplacingFiles() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.transaction.prepare(f.changes, oldFavorites: [], newFavorites: [])
        let external = Data("external edit".utf8), url = f.root.appendingPathComponent(f.changes[1].file.rawValue)
        try external.write(to: url)
        XCTAssertThrowsError(try f.transaction.commit(currentFavorites: []))
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(f.changes[0].file.rawValue)), f.changes[0].expected)
        XCTAssertEqual(try f.transaction.recover(currentFavorites: []), .none)
    }

    func testExternalChangeDuringInterruptedImportPreservesAllDataForRecovery() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.transaction.prepare(f.changes, oldFavorites: [], newFavorites: [])
        try f.changes[0].replacement.write(to: f.root.appendingPathComponent(f.changes[0].file.rawValue))
        let external = Data("external edit".utf8), url = f.root.appendingPathComponent(f.changes[1].file.rawValue)
        try external.write(to: url)
        XCTAssertThrowsError(try f.transaction.recover(currentFavorites: []))
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertEqual(try Data(contentsOf: f.root.appendingPathComponent(f.changes[0].file.rawValue)), f.changes[0].replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.transaction.stagingURL.path))
    }

    func testCorruptBackupAndUnknownJournalTargetArePreserved() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.transaction.prepare(f.changes, oldFavorites: [], newFavorites: [])
        let backup = f.transaction.stagingURL.appendingPathComponent(f.changes[0].file.rawValue + ".before")
        let corrupt = Data("broken backup".utf8); try corrupt.write(to: backup)
        XCTAssertThrowsError(try f.transaction.recover(currentFavorites: []))
        try assertOriginals(f)
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        let journalURL = f.transaction.stagingURL.appendingPathComponent("journal.json")
        let text = try String(contentsOf: journalURL, encoding: .utf8).replacingOccurrences(of: "playback-options.json", with: "../outside.json")
        try Data(text.utf8).write(to: journalURL)
        XCTAssertThrowsError(try f.transaction.recover(currentFavorites: []))
        try assertOriginals(f)
    }

    func testFutureOrBrokenTargetsCannotBeOverwrittenEvenWithMatchingExpectedBytes() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.root.appendingPathComponent(PersonalCollectionFile.listeningLibrary.rawValue)
        for bytes in [Data("{broken".utf8), Data("{\"version\":99,\"lists\":[]}".utf8)] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try f.transaction.prepare([
                .init(file: .listeningLibrary, expected: bytes, replacement: f.changes[0].replacement)
            ], oldFavorites: [], newFavorites: []))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.transaction.stagingURL.path))
        }
    }

    func testFavoritesOnlyTransactionAndExternalFavoritesConflict() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.transaction.prepare([], oldFavorites: ["Old.sid"], newFavorites: ["Imported.sid"])
        XCTAssertThrowsError(try f.transaction.commit(currentFavorites: ["External.sid"]))
        try assertOriginals(f)
        try f.transaction.prepare([], oldFavorites: ["Old.sid"], newFavorites: ["Imported.sid"])
        _ = try f.transaction.commit(currentFavorites: ["Old.sid"])
        XCTAssertThrowsError(try f.transaction.recover(currentFavorites: ["External.sid"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.transaction.stagingURL.path))
    }
}
