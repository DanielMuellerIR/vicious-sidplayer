import SwiftUI
import ViciousSIDPlayerCore

// Analysewerkzeuge: einzelne Stimmen stummschalten, den SID-Filter ueberbruecken
// und das Chipmodell erzwingen. Dieselben drei Schalter hat auch die Mac-App.
//
// Zwei Dinge, die man dabei wissen sollte (beides steht so in AGENTS.md):
//
//  - Stummschalten entfernt nur den Beitrag der Stimme zum Mix. Die Emulation
//    laeuft unveraendert weiter, sonst kaeme die Stimme beim Wiedereinschalten
//    an der falschen Stelle zurueck.
//  - „Filter aus" ist ein Analysewerkzeug, kein Klangregler: der Filterzustand
//    bleibt warm, gefilterte Stimmen laufen nur voruebergehend ungefiltert.
struct AnalysisControlsView: View {
    @ObservedObject var coordinator: ViciousCoordinator
    let palette: PlayerPalette
    /// `nil` = Auto (die Datei entscheidet), sonst 6581 oder 8580.
    let onModelChange: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Analyse")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { voice in
                    voiceButton(voice)
                }
            }

            // Der Filterschalter steht bewusst in einer eigenen Zeile: neben den
            // drei Stimmknoepfen bliebe fuer „Filter aus" so wenig Platz, dass
            // die Beschriftung umbricht.
            HStack {
                Button {
                    coordinator.toggleFilterEnabled()
                } label: {
                    // Bewusst zwei getrennte `Text`-Zweige statt eines
                    // Bedingungsausdrucks mit zwei Literalen: Letzterer landet
                    // leicht bei der nicht uebersetzten String-Ueberladung.
                    HStack(spacing: 4) {
                        Image(systemName: coordinator.filterEnabled ? "waveform.path.ecg" : "waveform.path")
                        if coordinator.filterEnabled {
                            Text("Filter an")
                        } else {
                            Text("Filter aus")
                        }
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(coordinator.filterEnabled ? .accentColor : .orange)
                .accessibilityLabel(Text("SID-Filter"))
                .accessibilityValue(coordinator.filterEnabled ? Text("An") : Text("Aus"))
            }

            Picker(selection: Binding(
                get: { coordinator.modelOverride ?? 0 },
                set: { onModelChange($0 == 0 ? nil : $0) }
            )) {
                Text("SID: Auto").tag(0)
                // Chipbezeichnungen sind Produktnamen und werden nicht uebersetzt.
                Text(verbatim: "6581").tag(6581)
                Text(verbatim: "8580").tag(8580)
            } label: {
                Text("SID-Chipmodell")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Auto folgt der Angabe in der Datei. Viele Stücke klingen nur auf dem Chip richtig, für den sie geschrieben wurden.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Ein Knopf je SID-Stimme, eingefaerbt wie ihre Kurve im Oszilloskop —
    /// so ist auf einen Blick klar, welcher Knopf zu welcher Linie gehoert.
    private func voiceButton(_ voice: Int) -> some View {
        let isMuted = coordinator.voiceMuted[voice]
        return Button {
            coordinator.toggleVoiceMuted(voice)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.footnote)
                Text(verbatim: "V\(voice + 1)")
                    .font(.caption2.monospaced())
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isMuted ? .red : palette.traceColors[voice])
        .accessibilityLabel(Text("Stimme \(voice + 1)"))
        .accessibilityValue(isMuted ? Text("Stumm") : Text("Hörbar"))
    }
}
