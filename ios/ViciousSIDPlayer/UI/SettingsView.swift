import SwiftUI
import UniformTypeIdentifiers
import ViciousSIDPlayerCore

// Einstellungen-Tab: Erscheinungsbild, Sitzungswiederherstellung,
// Songlaengen-Datenbank, Bibliothek zuruecksetzen, Ueber/Lizenzen.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    /// Beim Zuruecksetzen die Favoritenliste behalten?
    @State private var keepFavorites = true
    /// Erste Stufe der Sicherheitsabfrage.
    @State private var showResetPrompt = false
    /// Zweite Stufe — erst hier wird tatsaechlich geloescht.
    @State private var showFinalResetPrompt = false
    /// Auswahldialog fuer die Songlengths-Datei.
    @State private var showSonglengthsImporter = false
    @State private var showSTILImporter = false

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                playbackSection
                songlengthsSection
                stilSection
                librarySection
                aboutSection
            }
            .navigationTitle("Einstellungen")
            // Die zweite Stufe haengt bewusst an der Form und nicht am selben
            // Knopf wie die erste: zwei Abfragen an derselben View koennen sich
            // gegenseitig verschlucken, wenn die erste gerade ausblendet.
            .alert("Bibliothek wirklich löschen?", isPresented: $showFinalResetPrompt) {
                Button("Abbrechen", role: .cancel) { }
                Button("Endgültig löschen", role: .destructive) {
                    model.resetLibrary(keepFavorites: keepFavorites)
                }
            } message: {
                if keepFavorites {
                    Text("Letzte Nachfrage. Alle importierten Musikdateien werden vom Gerät gelöscht. Die Favoritenliste bleibt erhalten.")
                } else {
                    Text("Letzte Nachfrage. Alle importierten Musikdateien und die Favoritenliste werden gelöscht.")
                }
            }
            .fileImporter(
                isPresented: $showSonglengthsImporter,
                // Die Songlengths.md5 hat keinen eigenen Dateityp, deshalb der
                // allgemeine Datentyp — sonst waere sie im Dialog nicht waehlbar.
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        model.importSonglengths(from: url)
                    }
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
            .fileImporter(
                isPresented: $showSTILImporter,
                // Auch die STIL.txt hat keinen eigenen Dateityp; als reiner Text
                // waere sie im Dialog je nach Herkunft nicht waehlbar.
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        model.importSTIL(from: url)
                    }
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Erscheinungsbild

    private var appearanceSection: some View {
        Section {
            Picker(selection: $model.themeMode) {
                ForEach(ThemeMode.allCases, id: \.self) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            } label: {
                Text("Erscheinungsbild")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("Erscheinungsbild")
        } footer: {
            Text("„Automatisch“ folgt der Hell/Dunkel-Einstellung des Systems.")
        }
    }

    // MARK: - Wiedergabe

    private var playbackSection: some View {
        Section {
            Toggle("Sitzung wiederherstellen", isOn: $model.sessionRestoreEnabled)
        } header: {
            Text("Wiedergabe")
        } footer: {
            Text("Beim nächsten Start dort weitermachen, wo du aufgehört hast — Titel, Subtune und Position. Bei eingeschalteter Zufallswiedergabe wird bewusst nicht wiederhergestellt.")
        }
    }

    // MARK: - Songlaengen

    private var songlengthsSection: some View {
        Section {
            Button {
                showSonglengthsImporter = true
            } label: {
                Label("Songlengths.md5 importieren …", systemImage: "clock.arrow.circlepath")
            }
            if !model.songlengthsStatus.isEmpty {
                // Der Status kommt fertig formuliert aus dem Modell.
                Text(model.songlengthsStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Songlängen")
        } footer: {
            Text("Die Datei Songlengths.md5 aus der High Voltage SID Collection liefert die echten Spieldauern für Positionsleiste und automatisches Weiterschalten. Ohne sie berechnet die App die Länge beim ersten Abspielen selbst, sofern das Stück in Stille endet.")
        }
    }

    // MARK: - Titel-Anmerkungen (STIL)

    private var stilSection: some View {
        Section {
            Button {
                showSTILImporter = true
            } label: {
                Label("STIL.txt importieren …", systemImage: "text.book.closed")
            }
            if !model.stilStatus.isEmpty {
                Text(model.stilStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Titel-Anmerkungen")
        } footer: {
            Text("Die Datei STIL.txt aus der High Voltage SID Collection sammelt, was im SID-Dateikopf keinen Platz hat: welche Vorlage ein Stück covert, wer die Melodie geschrieben hat, Anmerkungen zu einzelnen Subtunes. Zugeordnet wird über den Ordnerweg des Titels — nur wenn er eindeutig ist, sonst bleibt die Anzeige leer.")
        }
    }

    // MARK: - Bibliothek

    private var librarySection: some View {
        Section {
            Toggle("Favoriten behalten", isOn: $keepFavorites)
            Button(role: .destructive) {
                showResetPrompt = true
            } label: {
                Label("Bibliothek zurücksetzen …", systemImage: "trash")
            }
            .confirmationDialog("Bibliothek zurücksetzen?",
                                isPresented: $showResetPrompt,
                                titleVisibility: .visible) {
                Button("Abbrechen", role: .cancel) { }
                Button("Weiter", role: .destructive) {
                    showFinalResetPrompt = true
                }
            } message: {
                Text("Dabei werden alle importierten .sid-Dateien vom Gerät gelöscht, dazu der Bibliotheksindex und die berechneten Songlängen. Danach musst du deine Sammlung neu importieren.")
            }
        } header: {
            Text("Bibliothek")
        } footer: {
            Text("Zum Zurücksetzen gibt es zwei Nachfragen — gelöschte Dateien lassen sich auf dem Gerät nicht wiederherstellen.")
        }
    }

    // MARK: - Ueber und Lizenzen

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(Self.versionString)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("SID-Emulation auf Basis von jsSID 0.9.1 von Hermit (Mihály Horváth), veröffentlicht unter der WTFPL.")
                Text("Vicious SID Player selbst steht ebenfalls unter der WTFPL.")
                Text("Keine SID-Musik ist Teil der App. Alle Stücke stammen aus deiner eigenen Sammlung und bleiben es.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Über")
        }
    }

    /// Version und Buildnummer aus dem App-Bundle, z.B. „1.9.0 (1)".
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppModel())
}
