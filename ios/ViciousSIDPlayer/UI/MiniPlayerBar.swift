import SwiftUI
import ViciousSIDPlayerCore

// Die schmale Leiste ueber der Tab-Leiste: zeigt, was gerade laeuft, und bleibt
// in jedem Tab sichtbar.
//
// Sie loest ein Problem, das die Mac-App nicht hat: dort liegen Playlist,
// Transport und Oszilloskop gleichzeitig im Fenster. Auf dem iPhone ist immer
// nur ein Tab sichtbar — ohne diese Leiste muesste man zum Pausieren jedes Mal
// den Tab wechseln.
//
// Antippen wechselt zu „Now Playing"; die beiden Knoepfe rechts sind eigene
// Ziele, damit ein Fingertipp auf Pause nicht zusaetzlich den Tab wechselt.
struct MiniPlayerBar: View {
    @ObservedObject var coordinator: ViciousCoordinator
    let onTap: () -> Void
    let onTogglePlayPause: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.body)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(coordinator.trackName)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                        Text(coordinator.composer)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Öffnet die Wiedergabeansicht.")

            Button(action: onTogglePlayPause) {
                Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // „Abspielen" statt „Wiedergabe": Letzteres ist die Beschriftung des
            // Tabs, und beide Texte teilen sich sonst denselben
            // Uebersetzungsschluessel mit unterschiedlicher Bedeutung.
            .accessibilityLabel(coordinator.isPlaying ? Text("Pause") : Text("Abspielen"))

            Button(action: onNext) {
                Image(systemName: "forward.end.fill")
                    .font(.body)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Nächster Titel"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Durchscheinender Hintergrund wie bei den Systemleisten, damit die
        // Liste darunter beim Scrollen weich durchschimmert.
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
