import Foundation
import UIKit
import ViciousSIDPlayerCore

extension AppModel {
    var currentHistoryReference: ListeningPersonalReference? {
        guard let currentTrackID, let currentMD5 else { return nil }
        return ListeningPersonalReference(libraryID: Self.listeningCollectionID, trackID: currentTrackID,
            md5: currentMD5, subtune: coordinator.currentSubtune)
    }

    func observeHistory(force: Bool = false, playing: Bool? = nil,
                        uptime: Double = ProcessInfo.processInfo.systemUptime) {
        let known = personalDuration ?? currentTrackLengths.flatMap {
            $0.indices.contains(coordinator.currentSubtune) && $0[coordinator.currentSubtune] > 0 ? $0[coordinator.currentSubtune] : nil
        } ?? computedLength
        history.observe(reference: currentHistoryReference, title: coordinator.trackName,
            position: coordinator.elapsedSeconds, knownDuration: known,
            isPlaying: (playing ?? coordinator.isPlaying) && !coordinator.isPreparingSeek, force: force, uptime: uptime)
    }

    func playHistoryReference(_ reference: ListeningPersonalReference, position: Double) {
        guard position <= ViciousProcessor.maximumSeekSeconds else {
            errorMessage = "Positionssprünge sind bis 20:00 min möglich. Die gespeicherte Marke bleibt erhalten."; return
        }
        var contents = metadataIndex.records.compactMapValues { $0.metadata?.md5 }
        if let currentHistoryReference { contents[currentHistoryReference.trackID] = currentHistoryReference.md5 }
        switch ListeningReferenceResolver.resolve(reference, libraryID: Self.listeningCollectionID, contents: contents) {
        case .found(let id):
            guard let url = trackURL(for: id), let data = try? Data(contentsOf: url), SonglengthDB.md5Hex(of: data) == reference.md5 else {
                errorMessage = "Der Titel fehlt oder sein Inhalt wurde geändert."; return
            }
            playbackOptions.acknowledgeManualPlayback()
            guard loadTrack(id: id, autoplay: false, subtune: reference.subtune ?? 0) else { return }
            // Eine Marke darf hinter der unbekannten Fallback-Dauer liegen.
            observeHistory(force: true, playing: false)
            coordinator.seek(seconds: position)
            togglePlayPause()
        case .missing: errorMessage = "Der Titel wurde in dieser Sammlung noch nicht gefunden. Den Bibliotheksabgleich abwarten."
        case .ambiguous: errorMessage = "Mehrere Dateien haben denselben Inhalt. Den gewünschten Titel in der Bibliothek auswählen."
        }
    }
}

/// Pausierte Apps koennen sofort suspendiert werden. Der Speicherabschluss
/// erhaelt deshalb eine begrenzte iOS-Hintergrundfrist; Audio laeuft unabhaengig.
@MainActor
final class ListeningHistoryBackgroundSaver {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var generation = 0
    func flush(_ history: ListeningHistoryController) {
        guard identifier == .invalid else { return }
        generation += 1
        let ticket = generation
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Persönliche Musikdaten sichern") { [weak self] in
            Task { @MainActor in self?.finish(ticket) }
        }
        Task { [self] in
            _ = await history.flush()
            finish(ticket)
        }
    }
    private func finish(_ ticket: Int) {
        guard ticket == generation, identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
