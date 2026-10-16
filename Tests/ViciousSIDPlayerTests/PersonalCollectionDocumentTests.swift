import XCTest
@testable import ViciousSIDPlayerCore

final class PersonalCollectionDocumentTests: XCTestCase {
    private let md5 = String(repeating: "a", count: 32)
    private let otherMD5 = String(repeating: "b", count: 32)
    private let now = Date(timeIntervalSince1970: 1_792_152_000.123)

    private func completeDocument() -> PersonalCollectionDocument {
        let file = PersonalCollectionReference(path: "Composer/Tune.sid", md5: md5)
        let sub = PersonalCollectionReference(path: file.path, md5: md5, subtune: 2)
        var doc = PersonalCollectionDocument(name: "Test collection", createdAt: now)
        doc.favorites = [file]
        doc.lists = [.init(name: "Repeated entries", entries: [.init(reference: sub), .init(reference: sub)])]
        doc.bookmarks = [.init(reference: sub, name: "Long mark", position: 1500.125, updatedAt: now)]
        doc.notes = [.init(reference: file, text: "Whole file <script>literal</script>", updatedAt: now),
                     .init(reference: sub, text: "Subtune\nMehrzeilig 🎵", updatedAt: now)]
        doc.endTimes = [.init(md5: md5, subtune: 2, seconds: 120.5)]
        doc.history = .init(events: [.init(reference: sub, title: "Tune", startedAt: now,
            lastHeardAt: now.addingTimeInterval(20), heardSeconds: 20, lastPosition: 1500.125)], heardMD5s: [md5, otherMD5])
        return doc
    }

    func testCompletePortableRoundTripKeepsFractionalPositionsAndISODateWithoutRuntimeState() throws {
        let doc = completeDocument(), bytes = try PersonalCollectionCodec.encode(doc)
        let decoded = try PersonalCollectionCodec.decode(bytes)
        XCTAssertEqual(decoded.bookmarks[0].position, 1500.125)
        XCTAssertEqual(decoded.endTimes, doc.endTimes)
        XCTAssertEqual(decoded.notes.map(\.text), doc.notes.map(\.text))
        XCTAssertEqual(decoded.lists[0].entries.map(\.id), doc.lists[0].entries.map(\.id))
        XCTAssertEqual(decoded.history?.heardMD5s, [md5, otherMD5])
        XCTAssertEqual(decoded.createdAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try PersonalCollectionCodec.encode(decoded), bytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertTrue((object["createdAt"] as? String)?.contains("T") == true)
        for key in ["queue", "libraryID", "root", "music", "volume", "sleepTimer"] { XCTAssertNil(object[key]) }
        var wrapped = Data([1, 2, 3]); wrapped.append(bytes)
        XCTAssertEqual(try PersonalCollectionCodec.decode(wrapped[3...]), decoded)
    }

    func testHistoryIsAbsentByDefaultAndVersionsAndOversizeAreRejected() throws {
        let bytes = try PersonalCollectionCodec.encode(PersonalCollectionDocument(name: "Empty", createdAt: now))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(object["history"])
        for version in [0, 2, 99] {
            var future = object; future["version"] = version
            XCTAssertThrowsError(try PersonalCollectionCodec.decode(JSONSerialization.data(withJSONObject: future)))
        }
        XCTAssertThrowsError(try PersonalCollectionCodec.decode(Data("{broken".utf8)))
        XCTAssertThrowsError(try PersonalCollectionCodec.decode(Data(repeating: 32, count: PersonalCollectionCodec.maximumBytes + 1)))
    }

    func testTraversalAbsolutePathsInvalidDatesAndDuplicatePersonalKeysAreRejected() throws {
        for path in ["/private/Tune.sid", "../Tune.sid", "a/../Tune.sid", "a/./Tune.sid", "a//Tune.sid", "C:/Tune.sid", "a\\Tune.sid", "a\0.sid"] {
            var doc = completeDocument(); doc.favorites = [.init(path: path, md5: md5)]
            XCTAssertThrowsError(try PersonalCollectionCodec.encode(doc), path)
        }
        var doc = completeDocument(); doc.createdAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertThrowsError(try PersonalCollectionCodec.encode(doc))
        doc = completeDocument(); doc.bookmarks.append(doc.bookmarks[0])
        XCTAssertThrowsError(try PersonalCollectionCodec.encode(doc))
        doc = completeDocument(); doc.notes.append(.init(reference: doc.notes[0].reference, text: "Conflicting file note"))
        XCTAssertThrowsError(try PersonalCollectionCodec.encode(doc))
        doc = completeDocument(); doc.endTimes.append(doc.endTimes[0])
        XCTAssertThrowsError(try PersonalCollectionCodec.encode(doc))
        doc = completeDocument(); doc.favorites = [.init(path: "Good.sid", md5: md5, subtune: 1)]
        XCTAssertThrowsError(try PersonalCollectionCodec.encode(doc))
    }

    func testTwoRootsResolveMovedContentWithoutTrustingNamesOrDuplicateFingerprints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("First collection"), target = root.appendingPathComponent("Other container")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let content = Data("first synthetic content".utf8), other = Data("different synthetic content".utf8)
        try content.write(to: source.appendingPathComponent("Tune.sid"))
        try other.write(to: target.appendingPathComponent("Tune.sid"))
        try content.write(to: target.appendingPathComponent("Moved.sid"))
        let fingerprint = SonglengthDB.md5Hex(of: try Data(contentsOf: source.appendingPathComponent("Tune.sid")))
        let catalog = try ["Tune.sid", "Moved.sid"].map { path in
            PersonalCollectionCatalogTrack(path: path, md5: SonglengthDB.md5Hex(of: try Data(contentsOf: target.appendingPathComponent(path))))
        }
        let resolver = try PersonalCollectionResolver(tracks: catalog)
        XCTAssertEqual(try resolver.resolve(.init(path: "Tune.sid", md5: fingerprint)), .moved("Moved.sid"))
        XCTAssertEqual(try resolver.resolve(.init(path: "Tune.sid")), .unverified("Tune.sid"))
        XCTAssertEqual(try resolver.resolve(.init(path: "Missing.sid", md5: md5)), .missing)
        XCTAssertEqual(try resolver.resolve(.init(path: "Tune.sid", md5: md5)), .changed)
        let duplicates = try PersonalCollectionResolver(tracks: catalog + [.init(path: "Copy.sid", md5: fingerprint)])
        XCTAssertEqual(try duplicates.resolve(.init(path: "Old.sid", md5: fingerprint)), .ambiguous)
        XCTAssertEqual(try duplicates.resolve(.init(path: "Moved.sid", md5: fingerprint)), .exact("Moved.sid"))
        let unknown = try PersonalCollectionResolver(tracks: [.init(path: "Tune.sid", md5: nil)])
        XCTAssertEqual(try unknown.resolve(.init(path: "Tune.sid", md5: fingerprint)), .unverified("Tune.sid"))
    }
}
