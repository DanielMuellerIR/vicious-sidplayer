import SwiftUI

// Alles, was die Bibliothek ueber einen Import zu sagen hat: laufender
// Fortschritt, Abschlussbericht und der leere Zustand beim ersten Start.

/// Fortschrittsleiste eines laufenden Imports, mit Abbrechen-Knopf.
///
/// Die Gesamtzahl steht erst fest, wenn der Ordner einmal durchgezaehlt ist —
/// bis dahin liefert `fraction` bewusst `nil` und wir zeigen einen unbestimmten
/// Balken statt einer erfundenen Prozentzahl.
struct ImportProgressBanner: View {
    let progress: ImportProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Import läuft …")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Button("Abbrechen", role: .cancel, action: onCancel)
                    .font(.footnote)
            }

            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                Text("\(progress.current) von \(progress.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Dateien werden gezählt …")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !progress.currentFile.isEmpty {
                Text(progress.currentFile)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

/// Abschlussbericht des letzten Imports. Bleibt stehen, bis der Nutzer ihn
/// wegklickt — sonst wuerde man bei einem langen Import den Ausgang verpassen.
struct ImportReportBanner: View {
    let report: ImportReport
    let onDismiss: () -> Void

    @State private var showsFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if report.wasCancelled {
                    Label("Import abgebrochen", systemImage: "xmark.circle")
                        .font(.footnote.weight(.semibold))
                } else {
                    Label("Import abgeschlossen", systemImage: "checkmark.circle")
                        .font(.footnote.weight(.semibold))
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Hinweis schließen"))
            }

            Text("Importiert: \(report.imported)")
                .font(.caption.monospacedDigit())
            Text("Übersprungen: \(report.skipped)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if !report.failed.isEmpty {
                DisclosureGroup(isExpanded: $showsFailures) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Dateinamen kommen aus dem Import und bleiben unuebersetzt.
                        // Identifiziert wird ueber den Index, NICHT ueber den
                        // String selbst: zusammengefuehrte Mehrfachimporte
                        // koennen fuer denselben Dateinamen denselben Fehlertext
                        // doppelt liefern, und doppelte IDs lassen SwiftUI
                        // Zeilen auslassen oder falsch wiederverwenden.
                        ForEach(Array(report.failed.enumerated()), id: \.offset) { _, name in
                            Text(name)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                } label: {
                    Text("Fehlgeschlagen: \(report.failed.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }
}

/// Der leere Zustand: erklaert beide Importwege.
///
/// Das ist kein Beiwerk. Der Weg ueber den Finder ist fuer eine grosse Sammlung
/// mit Abstand der bequemste — wer ihn nicht kennt, importiert stundenlang
/// einzelne Dateien. Deshalb steht er hier gleichberechtigt neben dem
/// Ordner-Import und nicht in einem Hilfetext, den niemand oeffnet.
struct EmptyLibraryView: View {
    let onImportFolder: () -> Void
    let onImportFiles: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text("Noch keine Musik")
                        .font(.title3.weight(.semibold))
                    Text("Es gibt zwei Wege, deine .sid-Sammlung auf das iPhone zu bekommen.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                importPathBox(
                    number: "1",
                    title: "Direkt in der App",
                    explanation: Text("Einen Ordner wählen — die App geht rekursiv hindurch, kopiert alles Spielbare und behält die Unterordner bei. Die Quelle kann iCloud, Nextcloud oder „Auf meinem iPhone“ sein. Einzelne Dateien gehen auch."),
                    actions: {
                        VStack(spacing: 8) {
                            Button(action: onImportFolder) {
                                Label("Ordner importieren …", systemImage: "folder.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button(action: onImportFiles) {
                                Label("Einzelne Dateien …", systemImage: "doc.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                )

                importPathBox(
                    number: "2",
                    title: "Über den Finder am Mac",
                    explanation: Text("iPhone ans Kabel, im Finder das Gerät auswählen, Reiter „Dateien“, dort „Vicious SID“ aufklappen. In dieses Feld lassen sich ganze Ordner per Drag & Drop ziehen. Für große Sammlungen ist das der schnellste Weg. Dieselbe Ablage erscheint auf dem iPhone in der Dateien-App unter „Auf meinem iPhone“."),
                    actions: { EmptyView() }
                )

                Text("Die App bringt selbst keine Musik mit. Alles, was du siehst, hast du selbst hinzugefügt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
    }

    /// Ein erklaerender Kasten je Importweg.
    private func importPathBox<Actions: View>(number: String,
                                              title: LocalizedStringKey,
                                              explanation: Text,
                                              @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: number)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor))
                Text(title)
                    .font(.headline)
            }
            explanation
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.10)))
    }
}
