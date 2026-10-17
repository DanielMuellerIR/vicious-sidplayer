import Foundation

public struct PersonalCollectionSnapshot: Equatable, Sendable {
    public var favorites: Set<String>
    public var listening: ListeningLibraryDocument
    public var history: ListeningHistoryDocument
    public var playback: PlaybackSettingsDocument
    public init(favorites: Set<String>, listening: ListeningLibraryDocument, history: ListeningHistoryDocument,
                playback: PlaybackSettingsDocument) {
        self.favorites = favorites; self.listening = listening; self.history = history; self.playback = playback
    }
}

public struct PersonalCollectionExportResult: Sendable {
    public let document: PersonalCollectionDocument
    public let unverifiedReferences: Set<PersonalCollectionReference>
    public let omittedEndTimeCount: Int
}

public enum PersonalCollectionExport {
    public static func make(_ snapshot: PersonalCollectionSnapshot, libraryID: String, name: String,
                            contents: [String: String], includeHistory: Bool = false, now: Date = Date()) throws -> PersonalCollectionExportResult {
        try snapshot.listening.validate(); _ = try snapshot.history.validated(); _ = try snapshot.playback.validated()
        var document = PersonalCollectionDocument(name: name, createdAt: now)
        var unverified: Set<PersonalCollectionReference> = []
        func reference(_ trackID: String, md5: String?, subtune: Int?) throws -> PersonalCollectionReference {
            let path = PlaylistTrackID.isExternal(trackID) ? (trackID as NSString).lastPathComponent : trackID
            let ref = PersonalCollectionReference(path: path, md5: md5, subtune: subtune)
            guard ref.isValid else { throw PersonalCollectionError.invalidData }
            if md5 == nil { unverified.insert(ref) }
            return ref
        }
        document.favorites = try Array(Set(snapshot.favorites.map { try reference($0, md5: contents[$0], subtune: nil) })).sorted {
            $0.path != $1.path ? $0.path < $1.path : ($0.md5 ?? "") < ($1.md5 ?? "")
        }
        document.lists = try snapshot.listening.lists.filter { $0.libraryID == libraryID }.map { list in
            PersonalCollectionList(id: list.id, name: list.name, kind: list.kind, entries: try list.entries.map {
                .init(id: $0.id, reference: try reference($0.trackID, md5: contents[$0.trackID], subtune: $0.subtune))
            })
        }
        let md5s = Set(contents.values)
        func belongs(_ ref: ListeningPersonalReference) -> Bool { ref.libraryID == libraryID || md5s.contains(ref.md5) }
        document.bookmarks = try snapshot.history.bookmarks.filter { belongs($0.reference) }.map {
            .init(id: $0.id, reference: try reference($0.reference.trackID, md5: $0.reference.md5, subtune: $0.reference.subtune),
                  name: $0.name, position: $0.position, updatedAt: $0.updatedAt)
        }
        document.notes = try snapshot.history.notes.filter { belongs($0.reference) }.map {
            .init(id: $0.id, reference: try reference($0.reference.trackID, md5: $0.reference.md5, subtune: $0.reference.subtune),
                  text: $0.text, updatedAt: $0.updatedAt)
        }
        let knownMD5s = md5s.union(document.bookmarks.compactMap { $0.reference.md5 }).union(document.notes.compactMap { $0.reference.md5 })
        document.endTimes = snapshot.playback.endTimes.sorted(by: { $0.key < $1.key }).compactMap { key, seconds in
            let parts = key.split(separator: ":")
            guard parts.count == 2, knownMD5s.contains(String(parts[0])), let subtune = Int(parts[1]) else { return nil }
            return .init(md5: String(parts[0]), subtune: subtune, seconds: seconds)
        }
        if includeHistory {
            let events = try snapshot.history.events.filter { belongs($0.reference) }.map { event in
                PersonalCollectionEvent(id: event.id,
                    reference: try reference(event.reference.trackID, md5: event.reference.md5, subtune: event.reference.subtune),
                    title: event.title, startedAt: event.startedAt, lastHeardAt: event.lastHeardAt,
                    heardSeconds: event.heardSeconds, lastPosition: event.lastPosition)
            }
            // Der unabhängige Gehört-Index hat keine Root-Zuordnung. Sein
            // ausdrücklicher Export umfasst daher alle Kennzeichnungen.
            document.history = .init(events: events, heardMD5s: snapshot.history.heardMD5s)
        }
        try document.validate()
        return .init(document: document, unverifiedReferences: unverified,
                     omittedEndTimeCount: snapshot.playback.endTimes.count - document.endTimes.count)
    }
}

public enum PersonalCollectionMergeChoice: String, Sendable { case keepExisting, useImported }
public struct PersonalCollectionConflict: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let canUseImported: Bool
    public let existingValue: String
    public let importedValue: String
    public let explanation: String?
    fileprivate let existingList: SavedListeningList?
    fileprivate let importedList: SavedListeningList?
}
public struct PersonalCollectionUnresolved: Equatable, Hashable, Sendable {
    public let reference: PersonalCollectionReference
    public let resolution: PersonalCollectionResolution
}
public struct PersonalCollectionMergeResult: Sendable {
    public let snapshot: PersonalCollectionSnapshot
    public let conflicts: [PersonalCollectionConflict]
    public let unresolved: [PersonalCollectionUnresolved]
    public let additions: Int
    public let duplicates: Int
    public let updates: Int
    public let skippedPathEntries: Int
    public let heardAddedCount: Int
    public let hasChanges: Bool
}

public enum PersonalCollectionMerge {
    private static func listValue(_ list: SavedListeningList) -> String {
        let entries = list.entries.enumerated().map { index, entry in
            let subtune = entry.subtune.map { "Subtune \($0 + 1)" } ?? "Dateieintrag"
            return "\(index + 1). \(entry.trackID) · \(subtune)"
        }
        return (["\(list.name) · \(list.entries.count) Einträge"] + entries).joined(separator: "\n")
    }

    public static func preview(_ document: PersonalCollectionDocument, into source: PersonalCollectionSnapshot,
                               libraryID: String, resolver: PersonalCollectionResolver,
                               choices: [String: PersonalCollectionMergeChoice] = [:],
                               acceptedPaths: Set<PersonalCollectionReference> = [], now: Date = Date()) throws -> PersonalCollectionMergeResult {
        guard !libraryID.isEmpty, libraryID.count <= 2048, !libraryID.contains("\0"),
              PersonalCollectionReference.validDate(now) else { throw PersonalCollectionError.invalidData }
        try document.validate(); try source.listening.validate(); _ = try source.history.validated(); _ = try source.playback.validated()
        var result = source, conflicts: [PersonalCollectionConflict] = [], unresolved: [PersonalCollectionUnresolved] = []
        var knownUnresolved: Set<PersonalCollectionUnresolved> = []
        var listIndices = Dictionary(uniqueKeysWithValues: result.listening.lists.enumerated().map { ($0.element.id, $0.offset) })
        var additions = 0, duplicates = 0, updates = 0, skippedPathEntries = 0
        func useImport(_ id: String, _ label: String, existing: String, imported: String, allowed: Bool = true,
                       existingList: SavedListeningList? = nil, importedList: SavedListeningList? = nil) -> Bool {
            conflicts.append(.init(id: id, label: label, canUseImported: allowed, existingValue: existing, importedValue: imported,
                explanation: allowed ? nil : NSLocalizedString("Eine andere Sammlung oder Listenart verwendet dieselbe Kennung. Der vorhandene Eintrag bleibt erhalten.", comment: ""),
                existingList: existingList, importedList: importedList))
            return allowed && choices[id] == .useImported
        }
        func resolvedPath(_ ref: PersonalCollectionReference, required: Bool) throws -> String? {
            let resolution = try resolver.resolve(ref)
            if let path = resolution.confirmedPath { return path }
            let issue = PersonalCollectionUnresolved(reference: ref, resolution: resolution)
            if knownUnresolved.insert(issue).inserted { unresolved.append(issue) }
            if case .unverified(let path) = resolution, acceptedPaths.contains(ref) { return path }
            if required { skippedPathEntries += 1; return nil }
            return ref.path
        }
        func personal(_ ref: PersonalCollectionReference) throws -> ListeningPersonalReference {
            guard let path = try resolvedPath(ref, required: false), let md5 = ref.md5 else { throw PersonalCollectionError.invalidData }
            return .init(libraryID: libraryID, trackID: path, md5: md5, subtune: ref.subtune)
        }
        for favorite in document.favorites {
            guard let path = try resolvedPath(favorite, required: true) else { continue }
            if result.favorites.insert(path).inserted { additions += 1 } else { duplicates += 1 }
        }
        for list in document.lists {
            let entries = try list.entries.compactMap { entry -> ListeningEntry? in
                guard let path = try resolvedPath(entry.reference, required: true) else { return nil }
                return .init(id: entry.id, trackID: path, subtune: entry.reference.subtune)
            }
            if list.kind == .subtuneFavorites,
               let index = result.listening.lists.firstIndex(where: { $0.libraryID == libraryID && $0.kind == .subtuneFavorites }) {
                var keys = Set(result.listening.lists[index].entries.map { "\($0.trackID):\($0.subtune ?? -1)" })
                var ids = Set(result.listening.lists[index].entries.map(\.id))
                for entry in entries {
                    if !keys.insert("\(entry.trackID):\(entry.subtune ?? -1)").inserted { duplicates += 1 }
                    else {
                        let id = ids.contains(entry.id) ? reassignedID(entry.id, key: "\(entry.trackID):\(entry.subtune ?? -1)", occupied: ids) : entry.id
                        ids.insert(id)
                        result.listening.lists[index].entries.append(.init(id: id, trackID: entry.trackID, subtune: entry.subtune)); additions += 1
                    }
                }
                continue
            }
            let mapped = SavedListeningList(id: list.id, libraryID: libraryID, name: list.name, entries: entries, kind: list.kind)
            if let index = listIndices[list.id] {
                if result.listening.lists[index] == mapped { duplicates += 1 }
                else if useImport("list:\(list.id)", list.name,
                                  existing: listValue(result.listening.lists[index]), imported: listValue(mapped),
                                  allowed: result.listening.lists[index].libraryID == libraryID && result.listening.lists[index].kind == list.kind,
                                  existingList: result.listening.lists[index], importedList: mapped) {
                    result.listening.lists[index] = mapped
                    updates += 1
                }
            } else {
                listIndices[list.id] = result.listening.lists.count
                result.listening.lists.append(mapped); additions += 1
            }
        }
        var bookmarks = source.history.bookmarks, notes = source.history.notes, events = source.history.events
        var bookmarkIndices = Dictionary(uniqueKeysWithValues: bookmarks.enumerated().map { ($0.element.id, $0.offset) })
        var noteIndices = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($0.element.reference.contentKey, $0.offset) })
        var noteIDs = Set(notes.map(\.id))
        var eventIndices = Dictionary(uniqueKeysWithValues: events.enumerated().map { ($0.element.id, $0.offset) })
        var heard = source.history.heardMD5s
        for bookmark in document.bookmarks {
            let mapped = ListeningBookmark(id: bookmark.id, reference: try personal(bookmark.reference),
                name: bookmark.name, position: bookmark.position, updatedAt: bookmark.updatedAt)
            if let index = bookmarkIndices[mapped.id] {
                let old = bookmarks[index]
                if old.reference.contentKey == mapped.reference.contentKey && old.name == mapped.name && old.position == mapped.position { duplicates += 1 }
                else if useImport("bookmark:\(mapped.id)", mapped.name,
                    existing: "\(old.name) · \(PlaytimeFormat.string(old.position)) · \(old.reference.trackID)",
                    imported: "\(mapped.name) · \(PlaytimeFormat.string(mapped.position)) · \(mapped.reference.trackID)") { bookmarks[index] = mapped; updates += 1 }
            } else { bookmarkIndices[mapped.id] = bookmarks.count; bookmarks.append(mapped); additions += 1 }
        }
        for note in document.notes {
            let ref = try personal(note.reference)
            if let index = noteIndices[ref.contentKey] {
                if notes[index].text == note.text { duplicates += 1 }
                else if useImport("note:\(ref.contentKey)", "\(ref.trackID) · \(ref.subtune.map { "Subtune \($0 + 1)" } ?? "ganze Datei")",
                    existing: notes[index].text, imported: note.text) {
                    notes[index] = .init(id: notes[index].id, reference: ref, text: note.text, updatedAt: note.updatedAt)
                    updates += 1
                }
            } else if noteIDs.contains(note.id) {
                if useImport("note-id:\(note.id)", ref.trackID,
                    existing: NSLocalizedString("Die Kennung gehört bereits zu einer anderen Notiz; diese bleibt erhalten.", comment: ""), imported: note.text) {
                    let added = ListeningNote(id: reassignedID(note.id, key: ref.contentKey, occupied: noteIDs),
                                              reference: ref, text: note.text, updatedAt: note.updatedAt)
                    noteIndices[ref.contentKey] = notes.count; noteIDs.insert(added.id)
                    notes.append(added); additions += 1
                }
            } else {
                noteIndices[ref.contentKey] = notes.count; noteIDs.insert(note.id)
                notes.append(.init(id: note.id, reference: ref, text: note.text, updatedAt: note.updatedAt)); additions += 1
            }
        }
        for end in document.endTimes {
            if let old = result.playback.endTimes[end.key] {
                if old == end.seconds { duplicates += 1 }
                else if useImport("end:\(end.key)", "\(resolver.label(forMD5: end.md5)) · Subtune \(end.subtune + 1)",
                    existing: PlaybackDurationInput.text(old), imported: PlaybackDurationInput.text(end.seconds)) { result.playback.endTimes[end.key] = end.seconds; updates += 1 }
            } else { result.playback.endTimes[end.key] = end.seconds; additions += 1 }
        }
        if let history = document.history {
            heard.formUnion(history.heardMD5s)
            func milliseconds(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
            for event in history.events {
                let mapped = ListeningHistoryEvent(id: event.id, reference: try personal(event.reference), title: event.title,
                    startedAt: event.startedAt, lastHeardAt: event.lastHeardAt, heardSeconds: event.heardSeconds, lastPosition: event.lastPosition)
                if let index = eventIndices[mapped.id] {
                    let old = events[index]
                    let sameEpisode = old.reference.contentKey == mapped.reference.contentKey && milliseconds(old.startedAt) == milliseconds(mapped.startedAt)
                    if sameEpisode && old.heardSeconds >= mapped.heardSeconds && milliseconds(old.lastHeardAt) >= milliseconds(mapped.lastHeardAt) { duplicates += 1 }
                    else if sameEpisode && mapped.heardSeconds >= old.heardSeconds && milliseconds(mapped.lastHeardAt) >= milliseconds(old.lastHeardAt) { events[index] = mapped; updates += 1 }
                    else if useImport("event:\(mapped.id)", mapped.title,
                        existing: "\(old.reference.trackID) · \(PlaytimeFormat.string(old.heardSeconds)) gehört",
                        imported: "\(mapped.reference.trackID) · \(PlaytimeFormat.string(mapped.heardSeconds)) gehört") { events[index] = mapped; updates += 1 }
                } else { eventIndices[mapped.id] = events.count; events.append(mapped); additions += 1 }
            }
            let cutoff = now.addingTimeInterval(-180 * 86400)
            events = Array(events.filter { $0.lastHeardAt >= cutoff }.sorted {
                $0.lastHeardAt != $1.lastHeardAt ? $0.lastHeardAt > $1.lastHeardAt : $0.id.uuidString < $1.id.uuidString
            }.prefix(2000))
        }
        result.history = try .init(events: events, heardMD5s: heard, bookmarks: bookmarks, notes: notes)
        try result.listening.validate(); _ = try result.playback.validated()
        return .init(snapshot: result, conflicts: conflicts, unresolved: unresolved, additions: additions, duplicates: duplicates,
                     updates: updates, skippedPathEntries: skippedPathEntries, heardAddedCount: heard.count - source.history.heardMD5s.count, hasChanges: result != source)
    }

    private static func reassignedID(_ id: UUID, key: String, occupied: Set<UUID>) -> UUID {
        // Eine Vorschau und ihre erneute Berechnung müssen dieselbe Ersatz-ID
        // liefern, wenn eine fremde UUID schon einen anderen Eintrag bezeichnet.
        var attempt = 0
        while true {
            let h = Array(MD5.hexString(of: Data("\(id.uuidString):\(key):\(attempt)".utf8)))
            let candidate = UUID(uuidString: "\(String(h[0..<8]))-\(String(h[8..<12]))-\(String(h[12..<16]))-\(String(h[16..<20]))-\(String(h[20..<32]))")!
            if !occupied.contains(candidate) { return candidate }
            attempt += 1
        }
    }
}
