import SwiftUI
import ViciousSIDPlayerCore

// „Now Playing" — der Wiedergabe-Tab.
//
// Die tägliche Bedienung passt kompakt über die Tab-Leiste. Seltene
// Analysewerkzeuge und ausführliche Anmerkungen bleiben ausklappbar.
//
// Die schnellen Stimmenwerte werden beim Zeichnen gelesen und nicht publiziert.
// Die Unteransichten beobachten nur Titel- und Transportzustand; Layout und
// Bedienung bleiben unabhängig vom Zeichentakt der Kurven.
struct NowPlayingView: View {
    let isVisible: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var optionsPresentation: PlaybackOptionsPresentation?
    @State private var showsDetails = false

    private var palette: PlayerPalette {
        PlayerPalette(themeMode: model.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 4) {
                        TrackHeaderView(coordinator: model.coordinator)
                        OscilloscopeView(coordinator: model.coordinator, palette: palette,
                                         isSceneActive: model.isSceneActive && isVisible)
                            .frame(height: scopeHeight(available: geometry.size.height))
                        SubtuneSelectorView(coordinator: model.coordinator) { model.setSubtune($0) }
                        ScrubberView(coordinator: model.coordinator, duration: model.currentDuration,
                                     isFallback: model.currentDurationResolution.source == .fallback) { model.seek(to: $0) }
                        TransportControlsView(coordinator: model.coordinator, accent: palette.accent)
                        PlaybackOptionsView()
                        AnalysisControlsView(coordinator: model.coordinator,
                                             onModelChange: model.setModelOverride, onClockChange: model.setClockMode)
                        DisclosureGroup(isExpanded: $showsDetails) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Abschnitt wiederholen").font(.subheadline.weight(.semibold))
                                PlaybackLoopControls(coordinator: model.coordinator)
                                if !model.coordinator.info.isEmpty {
                                    Text(model.coordinator.info).font(.footnote).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                STILNotesView()
                                AudioExportButton()
                            }
                            .padding(.top, 8)
                        } label: {
                            Label(model.coordinator.playbackLoop.isEnabled
                                  ? String(localized: "Abschnitt-Schleife aktiv") : String(localized: "Werkzeuge und Details"),
                                  systemImage: model.coordinator.playbackLoop.isEnabled ? "repeat" : "wrench.and.screwdriver")
                                .font(.footnote).frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("playback-details")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .navigationTitle("Wiedergabe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { optionsPresentation = PlaybackOptionsPresentation(target: model.playbackEndTimeTarget) }
                        label: { Label("Wiedergabeoptionen", systemImage: "slider.horizontal.3") }
                        .accessibilityIdentifier("playback-options")
                }
            }
            .sheet(item: $optionsPresentation) { presentation in
                AdvancedPlaybackOptionsView(controller: model.playbackOptions, target: presentation.target)
            }
        }
    }
    private func scopeHeight(available: CGFloat) -> CGFloat {
        // Die Kurven sind zugleich die Mute-Flächen; Solo liegt am rechten Rand darüber.
        let controlsHeight: CGFloat = 3 * 60 + 44 + 6
        let minimum = controlsHeight + (model.coordinator.activeSIDChips.count > 1 ? 44 : 0)
        if verticalSizeClass == .compact { return minimum }
        return min(320, max(minimum, available * 0.43 - (model.coordinator.subtunesCount > 1 ? 24 : 0)))
    }

}

private struct PlaybackOptionsPresentation: Identifiable {
    let id = UUID()
    let target: PlaybackEndTimeTarget?
}

// MARK: - Titelangaben

/// Titel und Autor; weitere Headerangaben stehen in den ausklappbaren Details.
private struct TrackHeaderView: View {
    @ObservedObject var coordinator: ViciousCoordinator
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.trackName).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(coordinator.composer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let id = model.currentTrackID {
                let favorite = model.listening.isSubtuneFavorite(trackID: id, subtune: coordinator.currentSubtune)
                Button { model.listening.toggleSubtuneFavorite(trackID: id, subtune: coordinator.currentSubtune) } label: {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .font(.system(size: 22)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favorite ? Text("Subtune gemerkt") : Text("Subtune merken"))
                .disabled(model.listening.isReadOnly || !model.listening.isLoaded)
            }
        }
    }
}

// MARK: - Titel-Anmerkungen (STIL)

/// Was die HVSC-Kuratoren zum laufenden Titel und Subtune notiert haben.
///
/// Erscheint nur, wenn es etwas gibt: Ohne importierte STIL-Datei — und bei
/// jedem Titel, den sie nicht eindeutig kennt — bleibt der Block unsichtbar,
/// statt eine leere Karte in die Ansicht zu setzen.
private struct STILNotesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let info = model.currentSTILInfo {
            VStack(alignment: .leading, spacing: 10) {
                Text("ANMERKUNGEN (STIL)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                // Vom Genauen zum Allgemeinen: erst der Subtune, dann die
                // Datei, zuletzt der Ordner. Die Reihenfolge macht der Core.
                ForEach(Array(info.orderedFields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(field.value)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Subtunes

/// Eine SID-Datei kann mehrere Songs („Subtunes") enthalten. Die Auswahl
/// erscheint nur, wenn es tatsaechlich mehr als einen gibt.
private struct SubtuneSelectorView: View {
    @ObservedObject var coordinator: ViciousCoordinator
    let onSelect: (Int) -> Void

    var body: some View {
        if coordinator.subtunesCount > 1 {
            HStack(spacing: 16) {
                Button {
                    let previous = (coordinator.currentSubtune - 1 + coordinator.subtunesCount) % coordinator.subtunesCount
                    onSelect(previous)
                } label: {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 22))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Vorheriger Subtune")
                .accessibilityValue(Text("Subtune \(coordinator.currentSubtune + 1) von \(coordinator.subtunesCount)"))

                VStack(spacing: 0) {
                    Text("Subtune")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // Ueber eine String-Variable, damit „2/5" nicht als
                    // Uebersetzungsschluessel behandelt wird.
                    Text(subtuneLabel)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                .frame(minWidth: 70)

                Button {
                    let next = (coordinator.currentSubtune + 1) % coordinator.subtunesCount
                    onSelect(next)
                } label: {
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 22))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Nächster Subtune")
                .accessibilityValue(Text("Subtune \(coordinator.currentSubtune + 1) von \(coordinator.subtunesCount)"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
    }

    private var subtuneLabel: String {
        "\(coordinator.currentSubtune + 1)/\(coordinator.subtunesCount)"
    }
}

// MARK: - Position

/// Positionsleiste mit verstrichener Zeit und Gesamtdauer.
///
/// Waehrend des Ziehens wird bewusst NICHT gesucht: jeder Sprung baut die
/// Emulation an der Zielstelle neu auf. Gesucht wird erst beim Loslassen, der
/// Regler zeigt bis dahin den lokalen Ziehwert.
private struct ScrubberView: View {
    @ObservedObject var coordinator: ViciousCoordinator
    let duration: Double
    var isFallback = false
    let onSeek: (Double) -> Void

    @State private var dragPosition: Double?

    var body: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { dragPosition ?? min(coordinator.elapsedSeconds, duration) },
                    set: { dragPosition = $0 }
                ),
                // Bei unbekannter Dauer waere der Bereich leer — das ist ein
                // Programmabbruch, deshalb die untere Schranke von einer Sekunde.
                in: 0...max(duration, 1),
                onEditingChanged: { isEditing in
                    if isEditing {
                        dragPosition = min(coordinator.elapsedSeconds, duration)
                    } else if let target = dragPosition {
                        onSeek(target)
                        dragPosition = nil
                    }
                }
            )
            .accessibilityLabel("Position")

            HStack {
                Text(AppModel.formatTime(dragPosition ?? coordinator.elapsedSeconds))
                Spacer()
                Text(isFallback ? String(localized: "Max. ")+AppModel.formatTime(duration) : AppModel.formatTime(duration))
                    .accessibilityLabel(isFallback ? Text("Unbekannte Songlänge, Limit \(AppModel.formatTime(duration))") : Text(AppModel.formatTime(duration)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Transport

/// Zurueck / 10 s zurueck / Wiedergabe / 10 s vor / Weiter.
private struct TransportControlsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var coordinator: ViciousCoordinator
    let accent: Color

    var body: some View {
        HStack(spacing: 16) {
            Button {
                model.playPrevious()
            } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 22))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Vorheriger Titel")

            Button {
                model.skip(by: -10)
            } label: {
                Image(systemName: "gobackward.10").font(.system(size: 20))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("10 Sekunden zurück")

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: coordinator.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(accent)
            }
            // Ausdruecklich als `Text`: bei einem Bedingungsausdruck aus zwei
            // Literalen waehlt Swift sonst die String-Ueberladung, und die wird
            // nicht uebersetzt.
            .accessibilityLabel(coordinator.isPlaying ? Text("Pause") : Text("Abspielen"))

            Button {
                model.skip(by: 10)
            } label: {
                Image(systemName: "goforward.10").font(.system(size: 20))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("10 Sekunden vor")

            Button {
                model.playNext()
            } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 22))
                    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Nächster Titel")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Wiedergabeoptionen

/// Zufallswiedergabe, automatisch weiter und Lautstaerke.
private struct PlaybackOptionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) { toggles; volume }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { toggles; volume }
                VStack(spacing: 8) { toggles; volume }
            }
        }
    }

    private var toggles: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $model.shuffle) { Image(systemName: "shuffle").frame(minWidth: 20, minHeight: 32) }
                .accessibilityLabel("Zufallswiedergabe")
            Toggle(isOn: $model.autoNext) { Text("Auto-Next").font(.footnote).frame(minHeight: 32) }
                .accessibilityLabel("Am Songende automatisch weiter")
        }
        .toggleStyle(.button)
    }

    private var volume: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill").font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: $model.volume, in: 0...1).accessibilityLabel("Lautstärke")
        }
        .frame(minWidth: 120, minHeight: 44)
    }
}

// MARK: - Audio-Export

private struct AudioExportButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var presentation: AudioExportPresentation?

    var body: some View {
        Button { presentation = model.makeAudioExportPresentation() } label: {
            Label("Audio exportieren", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .disabled(model.currentTrackID == nil)
        .sheet(item: $presentation) { presentation in
            AudioExportView(presentation: presentation)
        }
    }
}

#Preview {
    NowPlayingView(isVisible: true)
        .environmentObject(AppModel())
}
