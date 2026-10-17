import SwiftUI
import ViciousSIDPlayerCore

struct AdvancedPlaybackOptionsView: View {
    @ObservedObject var controller: PlaybackOptionsController
    let target: PlaybackEndTimeTarget?
    @Environment(\.dismiss) private var dismiss
    @State private var endTime = ""
    @State private var inputError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let error = controller.storageError { Section { Text(error) } }
                Section("Wiedergabe") {
                    Picker("Wiederholen", selection: Binding(get: { controller.document.repeatMode }, set: { controller.setRepeatMode($0) })) {
                        Text("Aus").tag(PlaybackRepeatMode.off)
                        Text("Subtune").tag(PlaybackRepeatMode.subtune)
                        Text("Datei").tag(PlaybackRepeatMode.file)
                        Text("Hörfolge").tag(PlaybackRepeatMode.sequence)
                    }.accessibilityIdentifier("playback-repeat")
                    Stepper("Fadeout: \(Int(controller.document.fadeOutSeconds)) s", value: Binding(get: { controller.document.fadeOutSeconds }, set: { controller.setFadeOutSeconds($0) }), in: 0...30, step: 1)
                        .accessibilityIdentifier("playback-fade")
                }
                Section("Eigene Endzeit") {
                    if let target {
                        Text("\(target.title) · Subtune \(target.subtune + 1)").font(.caption)
                        TextField("Sekunden oder m:ss", text: $endTime).keyboardType(.numbersAndPunctuation)
                            .accessibilityIdentifier("playback-end-time")
                        Button("Übernehmen") { saveEndTime(target) }
                        Button("Vorgabe verwenden") { endTime = ""; saveEndTime(target) }
                    } else { Text("Zuerst einen Titel laden.") }
                    if let inputError { Label(inputError, systemImage: "exclamationmark.triangle").foregroundStyle(.primary) }
                    Text("Eigene Endzeit vor HVSC und Berechnung. Maximal 60 Minuten; leer löscht die Vorgabe.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Einschlaftimer") {
                    Stepper("\(controller.document.sleepMinutes) Minuten", value: Binding(get: { controller.document.sleepMinutes }, set: { controller.setSleepMinutes($0) }), in: 1...180)
                    Button("Timer starten") { try? controller.startSleepTimer(seconds: Double(controller.document.sleepMinutes) * 60) }
                    Button("Nach diesem Subtune") { controller.stopAtSubtuneEnd() }
                    if controller.hasSleepTimer { Text("Noch \(LibraryMetadata.durationDescription(controller.remainingSleepSeconds))") }
                    if controller.stopAfterSubtune { Text("Stoppt am Ende des aktuellen Subtunes.") }
                    if controller.hasSleepTimer || controller.stopAfterSubtune { Button("Timer abbrechen") { controller.cancelSleepTimer() } }
                    if controller.didExpire { Text("Wiedergabe durch Timer beendet.") }
                }
                Section { Text("Repeat und gewählte Endaktionen gelten auch bei ausgeschaltetem Auto Next.").font(.caption) }
            }
            .navigationTitle("Wiedergabeoptionen")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .disabled(!controller.isLoaded)
            .onAppear { endTime = target.flatMap { controller.document.endTime(md5: $0.md5, subtune: $0.subtune) }.map(PlaybackDurationInput.text) ?? "" }
        }
    }
    private func saveEndTime(_ target: PlaybackEndTimeTarget) {
        do { try controller.setEndTime(endTime, target: target); inputError = nil }
        catch { inputError = error.localizedDescription }
    }
}
