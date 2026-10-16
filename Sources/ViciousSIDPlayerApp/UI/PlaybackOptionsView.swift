import SwiftUI
import ViciousSIDPlayerCore

struct PlaybackOptionsPresentation: Identifiable {
    let id = UUID()
    let target: PlaybackEndTimeTarget?
}

struct PlaybackOptionsView: View {
    @ObservedObject var controller: PlaybackOptionsController
    let target: PlaybackEndTimeTarget?
    @State private var endTime = ""
    @State private var inputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Wiedergabeoptionen").font(.headline)
            if let error = controller.storageError { Text(error).font(.caption) }
            Picker("Wiederholen", selection: Binding(get: { controller.document.repeatMode }, set: controller.setRepeatMode)) {
                Text("Aus").tag(PlaybackRepeatMode.off)
                Text("Subtune").tag(PlaybackRepeatMode.subtune)
                Text("Datei").tag(PlaybackRepeatMode.file)
                Text("Hörfolge").tag(PlaybackRepeatMode.sequence)
            }.accessibilityIdentifier("playback-repeat")
            Stepper("Fadeout: \(Int(controller.document.fadeOutSeconds)) s", value: Binding(get: { controller.document.fadeOutSeconds }, set: controller.setFadeOutSeconds), in: 0...30, step: 1)
                .accessibilityIdentifier("playback-fade")
            Divider()
            Text("Eigene Endzeit").font(.subheadline.weight(.semibold))
            if let target {
                Text("\(target.title) · Subtune \(target.subtune + 1)").font(.caption).lineLimit(2)
                HStack {
                    TextField("Sekunden oder m:ss", text: $endTime).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("playback-end-time")
                    Button("Übernehmen") { saveEndTime(target) }
                }
                Button("Vorgabe verwenden") { endTime = ""; saveEndTime(target) }
            } else { Text("Zuerst einen Titel laden.").font(.caption) }
            if let inputError { Label(inputError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.primary) }
            Text("Eigene Endzeit vor HVSC und Berechnung. Maximal 60 Minuten; leer löscht die Vorgabe.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Einschlaftimer").font(.subheadline.weight(.semibold))
            Stepper("\(controller.document.sleepMinutes) Minuten", value: Binding(get: { controller.document.sleepMinutes }, set: controller.setSleepMinutes), in: 1...180)
            HStack {
                Button("Timer starten") { try? controller.startSleepTimer(seconds: Double(controller.document.sleepMinutes) * 60) }
                Button("Nach diesem Subtune") { controller.stopAtSubtuneEnd() }
            }
            if controller.hasSleepTimer { Text("Noch \(LibraryMetadata.durationDescription(controller.remainingSleepSeconds))") }
            if controller.stopAfterSubtune { Text("Stoppt am Ende des aktuellen Subtunes.") }
            if controller.hasSleepTimer || controller.stopAfterSubtune { Button("Timer abbrechen") { controller.cancelSleepTimer() } }
            if controller.didExpire { Text("Wiedergabe durch Timer beendet.").font(.caption) }
            Text("Repeat und gewählte Endaktionen gelten auch bei ausgeschaltetem Auto Next.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 380)
        .disabled(!controller.isLoaded)
        .onAppear { endTime = target.flatMap { controller.document.endTime(md5: $0.md5, subtune: $0.subtune) }.map(PlaybackDurationInput.text) ?? "" }
    }
    private func saveEndTime(_ target: PlaybackEndTimeTarget) {
        do { try controller.setEndTime(endTime, target: target); inputError = nil }
        catch { inputError = error.localizedDescription }
    }
}

struct PlaybackOptionsObserver: ViewModifier {
    @ObservedObject var controller: PlaybackOptionsController
    @ObservedObject var coordinator: ViciousCoordinator
    let onConfigurationChange: () -> Void
    let onFadeChange: () -> Void
    let onStop: () -> Void
    let onReady: () -> Void
    func body(content: Content) -> some View {
        content
            .onAppear { let player = coordinator; controller.onStopRequested = { [weak player] in player?.stop() } }
            .onChange(of: controller.document) { _ in onConfigurationChange() }
            .onChange(of: controller.remainingSleepSeconds) { _ in onFadeChange() }
            .onChange(of: controller.stopAfterSubtune) { _ in onFadeChange() }
            .onChange(of: controller.didExpire) { expired in if expired { onStop() } }
            .onChange(of: controller.isLoaded) { loaded in if loaded { onReady() } }
            .onChange(of: coordinator.isPlaying) { _ in onFadeChange() }
    }
}
