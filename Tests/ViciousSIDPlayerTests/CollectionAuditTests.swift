import XCTest
@testable import ViciousSIDPlayerCore

final class CollectionAuditTests: XCTestCase {
    private func sid(_ marker: UInt8 = 0, subtunes: Int = 2) -> Data {
        var bytes = Data(repeating: 0, count: 0x7C)
        bytes.replaceSubrange(0..<4, with: Array("PSID".utf8))
        for (offset, value) in [(4, 2), (6, 0x7C), (8, 0x1000), (10, 0x1000), (12, 0x1001), (14, subtunes), (16, 1)] {
            bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(value & 255)
        }
        bytes.append(contentsOf: [0x60, 0x60, marker]); return bytes
    }
    private func fixture() throws -> (URL, PersonalCollectionContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = MusicLibrary(root: root.appendingPathComponent("Music"), supportDirectory: root.appendingPathComponent("Support"))
        return (root, .init(libraryID: "test", name: "Test collection", library: library))
    }
    private func write(_ bytes: Data, _ path: String, _ context: PersonalCollectionContext) throws {
        let url = context.library.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
    private func snapshot(path: String = "Old/Tune.sid", bytes: Data) throws -> PersonalCollectionSnapshot {
        let digest = SonglengthDB.md5Hex(of: bytes), now = Date(timeIntervalSince1970: 1_792_000_000)
        let ref = ListeningPersonalReference(libraryID: "test", trackID: path, md5: digest, subtune: 1)
        var listening = ListeningLibraryDocument()
        listening.lists = [.init(libraryID: "test", name: "Keep order", entries: [.init(trackID: path), .init(trackID: path, subtune: 1)])]
        listening.queue = .init(libraryID: "test", name: "Keep queue", entries: listening.lists[0].entries)
        let history = try ListeningHistoryDocument(events: [.init(reference: ref, title: "Tune", startedAt: now,
            lastHeardAt: now.addingTimeInterval(2), heardSeconds: 2, lastPosition: 1.5)], heardMD5s: [digest],
            bookmarks: [.init(reference: ref, name: "Mark", position: 1.25, updatedAt: now)],
            notes: [.init(reference: ref, text: "Keep my text", updatedAt: now)])
        return .init(favorites: [path], listening: listening, history: history, playback: .init())
    }

    func testDamagedUnsupportedDuplicatesAndEqualNamesRemainSeparateWithoutMusicOrIndexWrites() throws {
        let (root, context) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = sid(), other = sid(1)
        try write(bytes, "A/Tune.sid", context); try write(other, "B/Tune.sid", context)
        try write(bytes, "Duplicate.sid", context); try write(Data([1, 2, 3]), "Broken.sid", context)
        var future = bytes; future[5] = 6; try write(future, "Future.sid", context)
        _ = try context.library.refresh()
        let indexURL = context.library.supportDirectory.appendingPathComponent(context.library.indexFileName)
        let index = try Data(contentsOf: indexURL), source = try snapshot(bytes: bytes)
        let result = try CollectionAudit.run(context: context, snapshot: source)
        XCTAssertEqual(result.fileCount, 5); XCTAssertEqual(result.validCount, 3)
        XCTAssertEqual(result.issues.filter { $0.kind == .damaged }.map(\.paths), [["Broken.sid"]])
        XCTAssertEqual(result.issues.filter { $0.kind == .unsupported }.map(\.paths), [["Future.sid"]])
        XCTAssertEqual(result.issues.filter { $0.kind == .duplicate }.map(\.paths), [["A/Tune.sid", "Duplicate.sid"]])
        XCTAssertEqual(result.issues.filter { $0.kind == .ambiguous }.count, 1)
        XCTAssertTrue(result.repairs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: indexURL), index)
        XCTAssertEqual(try Data(contentsOf: context.library.root.appendingPathComponent("A/Tune.sid")), bytes)
        XCTAssertEqual(try Data(contentsOf: context.library.root.appendingPathComponent("B/Tune.sid")), other)
    }

    func testInventoryKeepsUnappliedMissingReferencesAcrossRerunsAndRepairPreservesRuntimeAndValues() throws {
        let (root, context) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = sid(), source = try snapshot(bytes: bytes)
        try write(bytes, "Old/Tune.sid", context)
        _ = try CollectionAudit.run(context: context, snapshot: source)
        let old = context.library.root.appendingPathComponent("Old/Tune.sid"), new = context.library.root.appendingPathComponent("New/Tune.sid")
        try FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: new)
        try write(sid(1), "Other/Tune.sid", context)
        let first = try CollectionAudit.run(context: context, snapshot: source)
        let report = try CollectionAudit.run(context: context, snapshot: source)
        XCTAssertEqual(first.repairs, report.repairs); XCTAssertEqual(report.repairs.count, 2)
        XCTAssertTrue(report.repairs.allSatisfy { $0.proposedPath == "New/Tune.sid" })
        XCTAssertEqual(try CollectionAuditRepair.preview(source, report: report, selected: []), source)
        let result = try CollectionAuditRepair.preview(source, report: report, selected: Set(report.repairs.map(\.id)))
        XCTAssertEqual(result.favorites, ["New/Tune.sid"])
        XCTAssertEqual(result.listening.lists[0].entries.map(\.trackID), ["New/Tune.sid", "New/Tune.sid"])
        XCTAssertEqual(result.listening.lists[0].entries.map(\.id), source.listening.lists[0].entries.map(\.id))
        XCTAssertEqual(result.history.bookmarks[0].reference.trackID, "New/Tune.sid")
        XCTAssertEqual(result.history.bookmarks[0].position, 1.25)
        XCTAssertEqual(result.history.notes[0].text, source.history.notes[0].text)
        XCTAssertEqual(result.history.events[0].heardSeconds, source.history.events[0].heardSeconds)
        XCTAssertEqual(result.history.heardMD5s, source.history.heardMD5s)
        XCTAssertEqual(result.listening.queue, source.listening.queue); XCTAssertEqual(result.playback, source.playback)
        XCTAssertEqual(try Data(contentsOf: new), bytes)
        let exported = try CollectionAudit.exportReport(report)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual((json["issues"] as? [Any])?.count, report.issues.count)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(root.path))
    }

    func testUnknownIdentityChangedContentAndOutOfRangeSubtuneNeverProposeNameBasedRepair() throws {
        let (root, context) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = sid(), source = try snapshot(bytes: bytes)
        try write(sid(1), "Old/Tune.sid", context)
        try write(sid(2), "New/Tune.sid", context)
        let result = try CollectionAudit.run(context: context, snapshot: source)
        XCTAssertTrue(result.repairs.isEmpty)
        XCTAssertEqual(result.issues.filter { $0.kind == .changed }.count, 1)
        var onlyPaths = source; onlyPaths.favorites.insert("Absent/Tune.sid")
        let paths = try CollectionAudit.run(context: context, snapshot: onlyPaths)
        XCTAssertTrue(paths.issues.contains { $0.kind == .unverified && $0.paths == ["Absent/Tune.sid"] })
        XCTAssertTrue(paths.repairs.isEmpty)
    }

    func testSTILAndEffectiveDurationsRespectAmbiguitySubtunesAndUnloadedDatabases() throws {
        let (root, context) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = sid(), digest = SonglengthDB.md5Hex(of: bytes)
        try write(bytes, "Tune.sid", context)
        var source = try snapshot(bytes: bytes)
        try source.playback.setEndTime(2, md5: digest, subtune: 1)
        let stil = STILDatabase.parse(text: "/A/Tune.sid\nCOMMENT: A\n\n/B/Tune.sid\nCOMMENT: B\n")
        let lengths = SonglengthDB.parse(text: digest + "=0:01\n")
        let loaded = try CollectionAudit.run(context: context, snapshot: source, metadata: .init(stil: stil, lengths: lengths))
        XCTAssertTrue(loaded.hasSTIL); XCTAssertTrue(loaded.hasLengths)
        XCTAssertEqual(loaded.issues.filter { $0.kind == .missingSTIL }.count, 1)
        XCTAssertTrue(loaded.issues.filter { $0.kind == .missingLength }.isEmpty)
        let unloaded = try CollectionAudit.run(context: context, snapshot: source)
        XCTAssertFalse(unloaded.hasSTIL); XCTAssertFalse(unloaded.hasLengths)
        XCTAssertTrue(unloaded.issues.filter { $0.kind == .missingSTIL }.isEmpty)
        XCTAssertEqual(unloaded.issues.filter { $0.kind == .missingLength }.count, 1)
    }

    func testChangedPersonalReferenceOccurrencesInvalidatePreviewButHistoryProgressDoesNot() throws {
        let (root, context) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = sid(), source = try snapshot(bytes: bytes)
        try write(bytes, "New/Tune.sid", context)
        let report = try CollectionAudit.run(context: context, snapshot: source,
            metadata: .init(knownContents: ["Old/Tune.sid": SonglengthDB.md5Hex(of: bytes)]))
        let chosen = Set(report.repairs.map(\.id))
        var changed = source
        changed.listening.lists[0].entries.append(.init(trackID: "Old/Tune.sid", subtune: 1))
        XCTAssertThrowsError(try CollectionAuditRepair.preview(changed, report: report, selected: chosen))
        var events = source.history.events; events[0].heardSeconds += 2; events[0].lastHeardAt.addTimeInterval(2)
        changed = source; changed.history = try .init(events: events, heardMD5s: source.history.heardMD5s,
            bookmarks: source.history.bookmarks, notes: source.history.notes)
        XCTAssertEqual(try CollectionAuditRepair.preview(changed, report: report, selected: chosen).history.events[0].heardSeconds, 4)
        XCTAssertThrowsError(try CollectionAuditRepair.preview(source, report: report, selected: ["invented"]))
    }

    func testCorruptInventoryOversizeAndOutsideSymlinkArePreservedAndMissingRootFails() throws {
        let (root, context) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = sid(); try write(bytes, "Good.sid", context)
        let inventory = context.library.supportDirectory.appendingPathComponent("audit-" + context.library.indexFileName)
        let corrupt = Data("{\"version\":99}".utf8); try corrupt.write(to: inventory)
        let outside = root.appendingPathComponent("Outside.sid"); try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: context.library.root.appendingPathComponent("Link.sid"), withDestinationURL: outside)
        let large = context.library.root.appendingPathComponent("Large.sid")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: UInt64(CollectionAudit.maximumFileBytes + 1)); try handle.close()
        let result = try CollectionAudit.run(context: context, snapshot: snapshot(bytes: bytes))
        XCTAssertNotNil(result.inventoryWarning); XCTAssertEqual(try Data(contentsOf: inventory), corrupt)
        XCTAssertTrue(result.issues.contains { $0.kind == .unsupported && $0.paths == ["Large.sid"] })
        XCTAssertFalse(result.catalog.contents.keys.contains("Link.sid")); XCTAssertEqual(try Data(contentsOf: outside), bytes)
        try FileManager.default.removeItem(at: context.library.root)
        XCTAssertThrowsError(try CollectionAudit.run(context: context, snapshot: snapshot(bytes: bytes)))
    }

    func testCancellationDoesNotPublishInventoryOrPartialReport() async throws {
        let (root, context) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = sid(), source = try snapshot(bytes: bytes)
        try write(bytes, "Good.sid", context)
        let entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let task = Task.detached {
            try CollectionAudit.run(context: context, snapshot: source) { count, _ in
                if count == 0 { entered.signal(); _ = proceed.wait(timeout: .now() + 5) }
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        task.cancel(); proceed.signal()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.library.supportDirectory.appendingPathComponent("audit-" + context.library.indexFileName).path))
        XCTAssertEqual(try Data(contentsOf: context.library.root.appendingPathComponent("Good.sid")), bytes)
    }

    func testExplicitLibraryResetRemovesItsAuditInventoryButKeepsUnrelatedSupportFiles() throws {
        let (root, context) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = sid(); try write(bytes, "Good.sid", context)
        _ = try CollectionAudit.run(context: context, snapshot: snapshot(bytes: bytes))
        let unrelated = context.library.supportDirectory.appendingPathComponent("keep-unrelated.json")
        try Data([1, 2, 3]).write(to: unrelated)
        _ = try LibraryReset.run(library: context.library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.library.supportDirectory.appendingPathComponent("audit-" + context.library.indexFileName).path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([1, 2, 3]))
    }
}
