import Foundation

public enum CollectionAuditRepair {
    /// Nur ausdrücklich gewählte, weiterhin eindeutige MD5-Treffer ändern
    /// persönliche Pfade. Inhalt, Kennungen, Reihenfolge und Zeiten bleiben gleich.
    public static func preview(_ source: PersonalCollectionSnapshot, report: CollectionAuditReport,
                               selected: Set<String>) throws -> PersonalCollectionSnapshot {
        let chosen = report.repairs.filter { selected.contains($0.id) }
        guard Set(chosen.map(\.id)) == selected else { throw PersonalCollectionError.invalidData }
        var changes: [PersonalCollectionReference: String] = [:]
        let resolver = try report.catalog.resolver
        for issue in chosen {
            guard let ref = issue.reference, let path = issue.proposedPath,
                  try resolver.resolve(ref) == .moved(path) else { throw PersonalCollectionError.invalidData }
            changes[ref] = path
        }
        guard occurrences(source, report: report, selected: Set(changes.keys))
            == occurrences(report.baseline, report: report, selected: Set(changes.keys)) else {
            throw CollectionAuditRepairError.changedReferences
        }
        var result = source
        func mapped(_ ref: ListeningPersonalReference) -> ListeningPersonalReference {
            guard ref.libraryID == report.catalog.libraryID,
                  let path = changes[.init(path: ref.trackID, md5: ref.md5, subtune: ref.subtune)] else { return ref }
            return .init(libraryID: ref.libraryID, trackID: path, md5: ref.md5, subtune: ref.subtune)
        }
        func mappedPath(_ path: String, subtune: Int?) -> String {
            guard let md5 = report.knownContents[path] else { return path }
            return changes[.init(path: path, md5: md5, subtune: subtune)] ?? path
        }
        result.favorites = Set(source.favorites.map { mappedPath($0, subtune: nil) })
        for index in result.listening.lists.indices where result.listening.lists[index].libraryID == report.catalog.libraryID {
            result.listening.lists[index].entries = result.listening.lists[index].entries.map {
                ListeningEntry(id: $0.id, trackID: mappedPath($0.trackID, subtune: $0.subtune), subtune: $0.subtune)
            }
        }
        // Die laufende Folge bleibt ein eigener Schnappschuss. Sie wird nach
        // einer Reparatur nicht neu gestartet oder umsortiert.
        let history = source.history
        result.history = try ListeningHistoryDocument(events: history.events.map {
            ListeningHistoryEvent(id: $0.id, reference: mapped($0.reference), title: $0.title, startedAt: $0.startedAt,
                lastHeardAt: $0.lastHeardAt, heardSeconds: $0.heardSeconds, lastPosition: $0.lastPosition)
        }, heardMD5s: history.heardMD5s, bookmarks: history.bookmarks.map {
            ListeningBookmark(id: $0.id, reference: mapped($0.reference), name: $0.name, position: $0.position, updatedAt: $0.updatedAt)
        }, notes: history.notes.map {
            ListeningNote(id: $0.id, reference: mapped($0.reference), text: $0.text, updatedAt: $0.updatedAt)
        })
        try result.listening.validate()
        return result
    }

    private static func occurrences(_ source: PersonalCollectionSnapshot, report: CollectionAuditReport,
                                    selected: Set<PersonalCollectionReference>) -> Set<String> {
        var result: Set<String> = []
        func matches(_ path: String, _ md5: String?, _ subtune: Int?) -> Bool {
            selected.contains(.init(path: path, md5: md5, subtune: subtune))
        }
        for path in source.favorites where matches(path, report.knownContents[path], nil) { result.insert("favorite:" + path) }
        for list in source.listening.lists where list.libraryID == report.catalog.libraryID {
            for entry in list.entries where matches(entry.trackID, report.knownContents[entry.trackID], entry.subtune) {
                result.insert("list:\(list.id):\(entry.id)")
            }
        }
        func add(_ id: UUID, _ ref: ListeningPersonalReference, _ kind: String) {
            if ref.libraryID == report.catalog.libraryID, matches(ref.trackID, ref.md5, ref.subtune) {
                result.insert(kind + ":" + id.uuidString)
            }
        }
        for item in source.history.events { add(item.id, item.reference, "event") }
        for item in source.history.bookmarks { add(item.id, item.reference, "bookmark") }
        for item in source.history.notes { add(item.id, item.reference, "note") }
        return result
    }
}

public enum CollectionAuditRepairError: Error, LocalizedError {
    case changedReferences
    public var errorDescription: String? {
        NSLocalizedString("Persönliche Verweise wurden seit der Vorschau geändert. Bitte die Sammlung erneut prüfen.", comment: "")
    }
}
