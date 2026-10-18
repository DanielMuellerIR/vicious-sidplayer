import Foundation
import ViciousSIDPlayerCore

extension AppModel {
    func makeAudioExportPresentation() -> AudioExportPresentation? {
        guard let id = currentTrackID, let url = trackURL(for: id) else {
            errorMessage = String(localized: "Kein Titel für den Audio-Export ausgewählt.")
            return nil
        }
        func sources(_ entries: [ListeningEntry]) -> [AudioExportSource] {
            entries.compactMap { entry in
                entry.url(relativeTo: libraryRoot).map { AudioExportSource(url: $0, subtune: entry.subtune) }
            }
        }
        var choices = [
            AudioExportChoice(id: 0, title: String(localized: "Aktueller Subtune"),
                sources: [AudioExportSource(url: url, subtune: coordinator.currentSubtune)], slice: coordinator.playbackLoop.range),
            AudioExportChoice(id: 1, title: String(localized: "Alle Subtunes dieses Titels"), sources: [AudioExportSource(url: url)])
        ]
        if let queue = listening.queue, !queue.items.isEmpty {
            choices.append(AudioExportChoice(id: 2, title: String(localized: "Hörfolge"), sources: sources(queue.items)))
        }
        let visible = listeningEntries(scope: .visible(searchText: searchText, favoritesOnly: favoritesOnly))
        if !visible.isEmpty { choices.append(AudioExportChoice(id: 3, title: String(localized: "Sichtbare Bibliothek"), sources: sources(visible))) }
        return AudioExportPresentation(choices: choices,
            durations: AudioExportDurationContext(resolver: lengthResolver, database: songlengthDB,
                settings: playbackOptions.document, clockMode: coordinator.clockMode),
            options: AudioExportOptions(modelOverride: coordinator.modelOverride, clockMode: coordinator.clockMode,
                filterEnabled: coordinator.filterEnabled, fadeOutSeconds: playbackOptions.document.fadeOutSeconds),
            analysisMix: coordinator.analysisMix)
    }
}
