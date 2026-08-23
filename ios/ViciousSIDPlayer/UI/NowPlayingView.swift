import SwiftUI
import ViciousSIDPlayerCore

// „Now Playing" — der Wiedergabe-Tab.
//
// Aufbau von oben nach unten: Titelangaben, Oszilloskop, Subtune-Auswahl,
// Positionsleiste, Transport, Wiedergabeoptionen, Analysewerkzeuge, Export.
//
// Der Bildschirm ist bewusst in kleine Unteransichten zerlegt. Das ist kein
// Selbstzweck: der Koordinator meldet waehrend der Wiedergabe rund 50-mal pro
// Sekunde neue Werte. SwiftUI zeichnet daraufhin genau die Ansichten neu, die
// ihn beobachten. Waere alles eine einzige grosse View, wuerde bei jedem dieser
// Ticks der komplette Bildschirm samt Reglern und Knoepfen neu berechnet.
struct NowPlayingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var systemScheme

    private var palette: PlayerPalette {
        PlayerPalette(themeMode: model.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TrackHeaderView(coordinator: model.coordinator)

                    OscilloscopeView(coordinator: model.coordinator,
                                     palette: palette,
                                     isSceneActive: model.isSceneActive)
                        .frame(height: 200)

                    SubtuneSelectorView(coordinator: model.coordinator) { index in
                        model.setSubtune(index)
                    }

                    ScrubberView(coordinator: model.coordinator,
                                 duration: model.currentDuration) { seconds in
                        model.seek(to: seconds)
                    }

                    TransportControlsView(coordinator: model.coordinator,
                                          accent: palette.accent)

                    PlaybackOptionsView()

                    AnalysisControlsView(coordinator: model.coordinator,
                                         palette: palette) { override in
                        model.setModelOverride(override)
                    }

                    STILNotesView()

                    WAVExportButton()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Titelangaben

/// Titel, Autor und Info-Zeile aus dem PSID-Header der Datei.
private struct TrackHeaderView: View {
    @ObservedObject var coordinator: ViciousCoordinator

    var body: some View {
        VStack(spacing: 4) {
            Text(coordinator.trackName)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(coordinator.composer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
            Text(coordinator.info)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
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
                        .font(.title3)
                }
                .accessibilityLabel("Vorheriger Subtune")

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
                        .font(.title3)
                }
                .accessibilityLabel("Nächster Subtune")
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
                Text(AppModel.formatTime(duration))
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
        HStack(spacing: 28) {
            Button {
                model.playPrevious()
            } label: {
                Image(systemName: "backward.end.fill").font(.title2)
            }
            .accessibilityLabel("Vorheriger Titel")

            Button {
                model.skip(by: -10)
            } label: {
                Image(systemName: "gobackward.10").font(.title3)
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
                Image(systemName: "goforward.10").font(.title3)
            }
            .accessibilityLabel("10 Sekunden vor")

            Button {
                model.playNext()
            } label: {
                Image(systemName: "forward.end.fill").font(.title2)
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

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Toggle(isOn: $model.shuffle) {
                    Label("Zufall", systemImage: "shuffle")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Zufallswiedergabe")

                Toggle(isOn: $model.autoNext) {
                    Label("Auto-Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .toggleStyle(.button)
                .accessibilityLabel("Am Songende automatisch weiter")

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $model.volume, in: 0...1)
                    .accessibilityLabel("Lautstärke")
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - WAV-Export

/// Rendert den laufenden Subtune in eine WAV-Datei und uebergibt sie an den
/// System-Teilen-Dialog (Dateien, AirDrop, Mail …).
private struct WAVExportButton: View {
    @EnvironmentObject private var model: AppModel

    @State private var isExporting = false
    @State private var exportedFile: ExportedFile?

    var body: some View {
        Button {
            startExport()
        } label: {
            HStack(spacing: 8) {
                if isExporting {
                    ProgressView()
                    Text("WAV wird gerendert …")
                } else {
                    Image(systemName: "square.and.arrow.up")
                    Text("Als WAV exportieren")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        // Waehrend des Renderns gesperrt, und ohne geladenen Titel gibt es
        // nichts zu exportieren.
        .disabled(isExporting || model.currentTrackID == nil)
        .sheet(item: $exportedFile) { file in
            ShareSheet(url: file.url)
        }
    }

    private func startExport() {
        isExporting = true
        Task {
            let url = await model.exportCurrentTrackAsWAV()
            isExporting = false
            if let url {
                exportedFile = ExportedFile(url: url)
            }
            // Schlaegt der Export fehl, meldet das Modell den Fehler ueber
            // `errorMessage`; die Wurzel-View zeigt ihn an.
        }
    }
}

#Preview {
    NowPlayingView()
        .environmentObject(AppModel())
}
