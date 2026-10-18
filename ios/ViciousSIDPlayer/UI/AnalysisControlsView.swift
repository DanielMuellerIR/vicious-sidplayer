import SwiftUI
import ViciousSIDPlayerCore

// Globale Analyseoptionen; die Stimmenregler stehen direkt neben den Kurven.
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
    /// `nil` = Auto (die Datei entscheidet), sonst 6581 oder 8580.
    let onModelChange: (Int?) -> Void
    let onClockChange: (SidClockMode) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { controls }
            VStack(alignment: .leading, spacing: 8) { controls }
        }
        .font(.footnote)
    }

    @ViewBuilder private var controls: some View {
        Button { coordinator.toggleFilterEnabled() } label: {
            Label(coordinator.filterEnabled ? String(localized: "Filter an") : String(localized: "Filter aus"),
                  systemImage: coordinator.filterEnabled ? "waveform.path.ecg" : "waveform.path")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(coordinator.filterEnabled ? .accentColor : .orange)
        .accessibilityLabel("SID-Filter")
        .accessibilityValue(coordinator.filterEnabled ? Text("An") : Text("Aus"))

        Picker("SID-Chipmodell", selection: Binding(
            get: { coordinator.modelOverride ?? 0 },
            set: { onModelChange($0 == 0 ? nil : $0) }
        )) {
            Text("SID: Auto").tag(0)
            Text(verbatim: "6581").tag(6581)
            Text(verbatim: "8580").tag(8580)
        }
        .pickerStyle(.menu)
        .frame(minHeight: 44)
        .accessibilityIdentifier("sid-model")

        Picker("C64-Takt", selection: Binding(get: { coordinator.clockMode }, set: { onClockChange($0) })) {
            Text("Takt: Auto").tag(SidClockMode.auto)
            Text(verbatim: "PAL").tag(SidClockMode.pal)
            Text(verbatim: "NTSC").tag(SidClockMode.ntsc)
        }
        .pickerStyle(.menu)
        .frame(minHeight: 44)
        .accessibilityIdentifier("sid-clock")
    }
}
