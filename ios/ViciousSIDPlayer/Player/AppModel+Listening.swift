import Foundation
import OSLog
import ViciousSIDPlayerCore

private let queueLogger = Logger(subsystem: "com.viben.ViciousSIDPlayer", category: "Playback")

extension AppModel {
    func activateListeningLibrary(removeMissing: Bool = false) {
        listening.activateLibrary(Self.listeningCollectionID,
            tracks: listeningPlaylist.tracks.map { ListeningEntry(trackID: $0.id) }, removeMissing: removeMissing)
    }

    func listeningEntries(scope: ListeningScope) -> [ListeningEntry] {
        LibrarySearchSelection.entries(in: listeningPlaylist, scope: scope, favorites: PlaylistFavorites(ids: favorites),
            records: metadataIndex.records, duration: knownLibraryDuration, heard: { history.hasHeard(md5: $0.md5) })
    }

    func makeDefaultListeningQueue(trackID: String) {
        let entries = listeningEntries(scope: .library)
        let index = entries.firstIndex { $0.trackID == trackID } ?? 0
        listening.setQueue(ListeningQueue(libraryID: Self.listeningCollectionID, name: String(localized: "Bibliothek"),
            kind: .library, entries: entries, startingAt: index, shuffled: shuffle, wraps: entries.count > 1))
    }

    func ensureListeningQueue() {
        if listening.queue == nil, let currentTrackID { makeDefaultListeningQueue(trackID: currentTrackID) }
    }

    func startListeningScope(_ scope: ListeningScope, name: String) {
        let entries = listeningEntries(scope: scope)
        let start = shuffle && !entries.isEmpty ? Int.random(in: entries.indices) : 0
        startListeningQueue(ListeningQueue(libraryID: Self.listeningCollectionID, name: name,
            kind: scope == .library ? .library : .selection, entries: entries, startingAt: start,
            shuffled: shuffle, wraps: scope == .library && entries.count > 1))
    }

    func startSavedListeningList(_ list: SavedListeningList, entryID: UUID? = nil) {
        guard list.libraryID == Self.listeningCollectionID else { return }
        let start = entryID.flatMap { id in list.entries.firstIndex { $0.id == id } }
            ?? (shuffle && !list.entries.isEmpty ? Int.random(in: list.entries.indices) : 0)
        startListeningQueue(ListeningQueue(libraryID: Self.listeningCollectionID, name: list.name,
            kind: .savedList, entries: list.entries, startingAt: start, shuffled: shuffle))
    }

    func startListeningQueue(_ proposed: ListeningQueue) {
        guard !collectionTransfer.isApplying else { return }
        playbackOptions.acknowledgeManualPlayback()
        guard !proposed.items.isEmpty else { errorMessage = String(localized: "Diese Auswahl enthält keine Titel."); return }
        var queue = proposed
        for _ in 0..<queue.items.count {
            if let entry = queue.current, loadListeningEntry(entry, autoplay: true) {
                listening.setQueue(queue)
                saveSessionState()
                return
            }
            guard queue.next() != nil else { break }
        }
        errorMessage = String(localized: "Kein Eintrag dieser Hörfolge ist abspielbar.")
    }

    @discardableResult
    func loadListeningEntry(_ entry: ListeningEntry, autoplay: Bool) -> Bool {
        loadTrack(id: entry.trackID, autoplay: autoplay, subtune: entry.subtune ?? 0, updateListeningQueue: false)
    }

    func selectListeningEntry(_ id: UUID) {
        guard !collectionTransfer.isApplying else { return }
        guard var queue = listening.queue, let entry = queue.items.first(where: { $0.id == id }) else { return }
        playbackOptions.acknowledgeManualPlayback()
        if loadListeningEntry(entry, autoplay: true) { queue.select(id); listening.setQueue(queue); saveSessionState() }
    }

    func advanceListeningQueue(forward: Bool, autoplay: Bool, repeatSequence: Bool = false) {
        guard !collectionTransfer.isApplying else { return }
        guard var queue = listening.queue else { return }
        for _ in 0..<max(1, queue.items.count) {
            guard let entry = forward ? queue.next(allowCycle: repeatSequence) : queue.previous(allowCycle: repeatSequence) else {
                queueLogger.notice("Hörfolge erreicht ihr Ende; Einträge: \(queue.items.count), Umlauf: \(queue.wraps)")
                listening.setQueue(queue)
                observeHistory(force: true, playing: false)
                if forward { coordinator.stop() } else { coordinator.seek(seconds: 0) }
                saveSessionState(); syncPlaybackLoop(); updateNowPlaying(force: true)
                return
            }
            if loadListeningEntry(entry, autoplay: autoplay) { listening.setQueue(queue); saveSessionState(); return }
        }
        observeHistory(force: true, playing: false)
        coordinator.stop(); syncPlaybackLoop(); saveSessionState(); updateNowPlaying(force: true)
        queueLogger.notice("Kein weiterer Eintrag abspielbar; Einträge: \(queue.items.count)")
        errorMessage = String(localized: "Kein weiterer Eintrag dieser Hörfolge ist abspielbar.")
    }

    func enqueueNext(trackID: String, subtune: Int? = nil) {
        guard !collectionTransfer.isApplying else { return }
        ensureListeningQueue()
        if listening.queue == nil {
            let entry = ListeningEntry(trackID: trackID, subtune: subtune)
            if loadListeningEntry(entry, autoplay: false) {
                listening.setQueue(ListeningQueue(libraryID: Self.listeningCollectionID,
                    name: String(localized: "Als Nächstes"), entries: [entry]))
            }
        } else { listening.enqueueNext(ListeningEntry(trackID: trackID, subtune: subtune)) }
    }

    func saveListeningList(name: String, entries: [ListeningEntry]) -> UUID? {
        listening.createList(name: name, entries: entries)
    }

    func appendCurrentSubtune(to listID: UUID) {
        guard let currentTrackID else { return }
        listening.append(ListeningEntry(trackID: currentTrackID, subtune: coordinator.currentSubtune), to: listID)
    }

    func listeningSubtuneCount(for entry: ListeningEntry) -> Int? {
        guard let url = trackURL(for: entry.trackID), let data = try? Data(contentsOf: url),
              let sid = try? SidParser.parse(data: data) else { return nil }
        return sid.subtuneAmount
    }

    /// Wiederherstellung waehlt nur vor. Shuffle beginnt einen frischen Durchlauf
    /// der gespeicherten Auswahl; der alte Positionsstand wird dabei nicht ersetzt.
    func restoreListeningQueueIfPossible() -> Bool {
        guard sessionRestoreEnabled else { listening.setQueue(nil); return false }
        guard var queue = listening.queue, !queue.items.isEmpty else { return false }
        let keys = [Keys.lastTrackID, Keys.lastSubtune, Keys.lastPosition, Keys.lastListeningEntryID]
        let saved = keys.map { defaults.object(forKey: $0) }
        let savedID = defaults.string(forKey: Keys.lastTrackID)
        let sub = defaults.integer(forKey: Keys.lastSubtune), position = defaults.double(forKey: Keys.lastPosition)
        if shuffle { queue.restart(shuffled: true, preservePending: true) }
        else {
            queue.setShuffle(false)
            if let value = defaults.string(forKey: Keys.lastListeningEntryID), let id = UUID(uuidString: value),
               queue.items.contains(where: { $0.id == id }) { queue.select(id) }
            else if queue.kind == .library, let entry = queue.items.first(where: { $0.trackID == savedID }) { queue.select(entry.id) }
        }
        defer {
            if shuffle {
                for (key, value) in zip(keys, saved) {
                    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
            }
        }
        for _ in 0..<queue.items.count {
            if let entry = queue.current, loadListeningEntry(entry, autoplay: false) {
                listening.setQueue(queue)
                if !shuffle, entry.trackID == savedID {
                    if entry.subtune == nil || playbackOptions.document.repeatMode == .file { coordinator.setSubtune(sub: sub) }
                    if position > 1 { coordinator.seek(seconds: position) }
                    resolveComputedLengthIfNeeded(); saveSessionState(); updateNowPlaying(force: true)
                }
                return true
            }
            guard queue.next() != nil else { break }
        }
        listening.setQueue(queue)
        errorMessage = String(localized: "Kein Eintrag dieser Hörfolge ist abspielbar.")
        return true
    }
}
