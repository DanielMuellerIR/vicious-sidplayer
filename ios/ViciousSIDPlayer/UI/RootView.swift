import SwiftUI

// Die Wurzel der Bedienoberflaeche: drei Tabs und darueber die Mini-Player-Leiste.
//
// Hier haengen ausserdem die drei Dinge, die fuer die ganze App gelten:
//
//   - `model.start()` genau einmal beim ersten Erscheinen,
//   - das Erscheinungsbild (Hell/Dunkel/Automatisch),
//   - die Fehlermeldung als Hinweisdialog.
//
// Die Mini-Player-Leiste sitzt ueber `safeAreaInset` am unteren Rand des
// jeweiligen TAB-INHALTS — nicht an der `TabView` selbst. Der Unterschied ist
// nicht kosmetisch: haengt der Inset an der TabView, wird die Leiste UNTER der
// Tab-Leiste eingefuegt und verdeckt sie vollstaendig. Die App waere dann ab
// dem ersten gespielten Titel nicht mehr umschaltbar. Am Tab-Inhalt dagegen
// liegt sie oberhalb der Tab-Leiste und schiebt den Inhalt genau um ihre Hoehe
// nach oben, verdeckt also nie die letzte Zeile einer Liste.
//
// Auf dem Wiedergabe-Tab bleibt sie bewusst weg: dort steht der vollstaendige
// Player, eine zweite Steuerung darunter waere nur Wiederholung.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    /// Der gerade sichtbare Tab. Wird auch von der Mini-Player-Leiste gesetzt.
    @State private var selectedTab: Tab = .library
    /// Sicherung dagegen, dass `start()` bei einem erneuten Erscheinen der View
    /// ein zweites Mal laeuft.
    @State private var hasStarted = false

    enum Tab: Hashable {
        case library
        case nowPlaying
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView()
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
                .tabItem {
                    Label("Bibliothek", systemImage: "music.note.list")
                }
                .tag(Tab.library)

            NowPlayingView()
                .tabItem {
                    Label("Wiedergabe", systemImage: "waveform")
                }
                .tag(Tab.nowPlaying)

            SettingsView()
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayerBar }
                .tabItem {
                    Label("Einstellungen", systemImage: "gearshape")
                }
                .tag(Tab.settings)
        }
        // Auf iOS reicht dieser eine Aufruf: `nil` heisst „System entscheidet".
        // Der Umweg ueber den globalen Schluessel `AppleInterfaceStyle`, den die
        // Mac-App gehen muss, entfaellt hier.
        .preferredColorScheme(model.themeMode.preferredColorScheme)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            model.start()
        }
        .alert("Fehler", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// Die Mini-Player-Leiste. Ohne geladenen Titel gibt es nichts zu zeigen;
    /// sie erscheint mit dem ersten Titel und bleibt danach.
    @ViewBuilder
    private var miniPlayerBar: some View {
        if model.currentTrackID != nil {
            MiniPlayerBar(
                coordinator: model.coordinator,
                onTap: { selectedTab = .nowPlaying },
                onTogglePlayPause: { model.togglePlayPause() },
                onNext: { model.playNext() }
            )
        }
    }

    /// Der Hinweisdialog ist genau dann offen, wenn eine Meldung vorliegt;
    /// Schliessen setzt sie zurueck.
    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented { model.errorMessage = nil }
            }
        )
    }
}

#Preview {
    RootView()
        .environmentObject(AppModel())
}
