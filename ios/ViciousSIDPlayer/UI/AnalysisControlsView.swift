import SwiftUI
import ViciousSIDPlayerCore

// Analysewerkzeuge: einzelne Stimmen stummschalten, den SID-Filter ueberbruecken
// und das Chipmodell erzwingen. Mute und Solo gelten getrennt je Chip/Stimme.
//
// Zwei Dinge, die man dabei wissen sollte (beides steht so in AGENTS.md):
//
//  - Stummschalten entfernt nur den Beitrag der Stimme zum Mix. Die Emulation
//    laeuft unveraendert weiter, sonst kaeme die Stimme beim Wiedereinschalten
//    an der falschen Stelle zurueck.
//  - „Filter aus" ist ein Analysewerkzeug, kein Klangregler: der Filterzustand
//    bleibt warm, gefilterte Stimmen laufen nur voruebergehend ungefiltert.
struct AnalysisControlsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var coordinator: ViciousCoordinator
    let palette: PlayerPalette
    /// `nil` = Auto (die Datei entscheidet), sonst 6581 oder 8580.
    let onModelChange: (Int?) -> Void
    let onClockChange: (SidClockMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Analyse")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(coordinator.activeSIDChips, id: \.self) { chip in
                VStack(alignment: .leading, spacing: 8) {
                    chipHeaderLayout {
                        Text(verbatim: "SID \(chip + 1) · \(coordinator.modelForChip(chip))")
                            .font(.footnote.weight(.semibold))
                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                        Button { coordinator.toggleChipMuted(chip) } label: {
                            Label("Chip stumm", systemImage: coordinator.analysisMix.chipMuted[chip] ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.footnote)
                                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(coordinator.analysisMix.chipMuted[chip] ? .red : .accentColor)
                        .accessibilityLabel(Text("SID \(chip + 1) Chip stumm"))
                        .accessibilityValue(coordinator.analysisMix.chipMuted[chip] ? Text("An") : Text("Aus"))
                    }
                    voiceLayout {
                        ForEach(0..<3, id: \.self) { voice in voiceControls(chip: chip, voice: voice) }
                    }
                }
            }
            Button { coordinator.clearSolos() } label: {
                Text("Solos aufheben").frame(minHeight: 32)
            }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .disabled(coordinator.analysisMix.soloChannels.isEmpty)
            Text("Mehrere Solos wirken gemeinsam. Stimmen- und Chip-Mute haben Vorrang.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            // Der globale Filter-Bypass bleibt außerhalb der Chipgruppen.
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
                    .frame(maxWidth: .infinity, minHeight: 44)
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

            Picker("C64-Takt", selection: Binding(
                get: { coordinator.clockMode }, set: { onClockChange($0) }
            )) {
                Text("Auto").tag(SidClockMode.auto)
                Text(verbatim: "PAL").tag(SidClockMode.pal)
                Text(verbatim: "NTSC").tag(SidClockMode.ntsc)
            }
            .pickerStyle(.segmented)

            Text("Takt: \(coordinator.effectiveClock.label) · Datei: \(coordinator.clockPreference.label)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Auto folgt der Angabe in der Datei. Viele Stücke klingen nur auf dem Chip richtig, für den sie geschrieben wurden.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voiceLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 6))
    }

    private var chipHeaderLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout())
    }

    private func voiceControls(chip: Int, voice: Int) -> some View {
        let channel = chip * 3 + voice
        let muted = coordinator.analysisMix.channelMuted[channel]
        let solo = coordinator.analysisMix.soloChannels.contains(channel)
        return VStack(spacing: 5) {
            Text(verbatim: "V\(voice + 1)").font(.caption.monospaced())
                .foregroundStyle(coordinator.effectiveChannelMuted[channel] ? Color.secondary : palette.traceColors[voice])
            HStack(spacing: 4) {
                Button { coordinator.toggleChannelMuted(channel) } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(maxWidth: .infinity, minHeight: 32)
                }
                .frame(minWidth: 44, minHeight: 44)
                .tint(muted ? .red : palette.traceColors[voice])
                .accessibilityLabel(Text("SID \(chip + 1), Stimme \(voice + 1) stummschalten"))
                .accessibilityValue(muted ? Text("An") : Text("Aus"))
                Button { coordinator.toggleChannelSolo(channel) } label: { Text("S").frame(maxWidth: .infinity, minHeight: 32) }
                    .frame(minWidth: 44, minHeight: 44)
                    .tint(solo ? .orange : .secondary)
                    .accessibilityLabel(Text("SID \(chip + 1), Stimme \(voice + 1) Solo"))
                    .accessibilityValue(solo ? Text("An") : Text("Aus"))
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }
}
