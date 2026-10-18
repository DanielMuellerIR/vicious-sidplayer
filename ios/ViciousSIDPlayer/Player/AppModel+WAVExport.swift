import Foundation
import ViciousSIDPlayerCore

extension AppModel {
    func makeWAVExportPresentation() -> WAVExportPresentation? {
        guard let id = currentTrackID, let url = trackURL(for: id) else {
            errorMessage = String(localized: "Kein Titel für den WAV-Export ausgewählt.")
            return nil
        }
        func sources(_ entries: [ListeningEntry]) -> [WAVExportSource] {
            entries.compactMap { entry in
                entry.url(relativeTo: libraryRoot).map { WAVExportSource(url: $0, subtune: entry.subtune) }
            }
        }
        var choices = [
            WAVExportChoice(id: 0, title: String(localized: "Aktueller Subtune"),
                sources: [WAVExportSource(url: url, subtune: coordinator.currentSubtune)], slice: coordinator.playbackLoop.range),
            WAVExportChoice(id: 1, title: String(localized: "Alle Subtunes dieses Titels"), sources: [WAVExportSource(url: url)])
        ]
        if let queue = listening.queue, !queue.items.isEmpty {
            choices.append(WAVExportChoice(id: 2, title: String(localized: "Hörfolge"), sources: sources(queue.items)))
        }
        let visible = listeningEntries(scope: .visible(searchText: searchText, favoritesOnly: favoritesOnly))
        if !visible.isEmpty { choices.append(WAVExportChoice(id: 3, title: String(localized: "Sichtbare Bibliothek"), sources: sources(visible))) }
        return WAVExportPresentation(choices: choices,
            durations: WAVExportDurationContext(resolver: lengthResolver, database: songlengthDB,
                settings: playbackOptions.document, clockMode: coordinator.clockMode),
            options: WAVExportOptions(modelOverride: coordinator.modelOverride, clockMode: coordinator.clockMode,
                filterEnabled: coordinator.filterEnabled, fadeOutSeconds: playbackOptions.document.fadeOutSeconds),
            analysisMix: coordinator.analysisMix)
    }
}
