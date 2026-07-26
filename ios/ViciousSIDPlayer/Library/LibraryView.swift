import SwiftUI
import UniformTypeIdentifiers
import ViciousSIDPlayerCore

// Der Bibliotheks-Tab: Ordnerbaum, Suche, Favoriten, Import.
//
// Zwei Darstellungen, je nach Lage:
//
//   - Ohne Filter der Ordnerbaum zum Auf- und Zuklappen. HVSC-Sammlungen sind
//     tief verschachtelt (Komponist/Album/Titel); als flache Liste mit
//     zehntausenden Zeilen waere die Bibliothek unbenutzbar.
//   - Sobald gesucht oder auf Favoriten gefiltert wird, eine flache Trefferliste
//     mit Ordnerpfad unter jedem Namen. Ein Baum, aus dem die Haelfte
//     herausgefiltert ist, verwirrt mehr, als er hilft.
//
// Die Trefferliste ist zugleich die Reihenfolge, in der „Weiter" und „Zurück"
// laufen — das entscheidet das Modell (`visibleTracks`), nicht diese Ansicht.
struct LibraryView: View {
    @EnvironmentObject private var model: AppModel

    /// Pfade der aufgeklappten Ordner.
    @State private var expandedFolders: Set<String> = []
    /// Nachschlagetabelle Pfad -> Titel, damit der Ordnerbaum aus seinen
    /// Titel-IDs die Anzeigenamen findet, ohne dafuer jedes Mal die ganze
    /// Titelliste zu durchsuchen.
    @State private var trackIndex: [String: LibraryTrack] = [:]
    /// Dateiauswahl offen?
    @State private var showImporter = false
    /// Was darf ausgewaehlt werden — Ordner oder einzelne .sid-Dateien?
    @State private var importAllowedTypes: [UTType] = [.folder]

    /// Der Dateityp fuer .sid. Bevorzugt der vom System registrierte Typ (die
    /// App meldet ihn in ihrer Info.plist als importierten Typ an); kennt ihn
    /// niemand, hilfsweise ueber die Dateiendung. Ohne diesen Rueckfallweg
    /// stuende im Auswahldialog irgendwann gar nichts mehr zur Auswahl.
    private static let sidContentType: UTType = UTType(SidFileType.uti)
        ?? UTType(filenameExtension: SidFileType.fileExtension)
        ?? .data

    /// Wird gerade gefiltert (Suchtext oder Favoriten)?
    private var isFiltering: Bool {
        !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.favoritesOnly
    }

    /// Sichtbare Zeilen des Ordnerbaums.
    private var treeRows: [LibraryRowItem] {
        LibraryTree.rows(of: model.folderTree,
                         expanded: expandedFolders,
                         trackIndex: trackIndex)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Fortschritt hat Vorrang vor dem Bericht des vorigen Laufs.
                if let progress = model.importProgress {
                    ImportProgressBanner(progress: progress) {
                        model.cancelImport()
                    }
                } else if let report = model.lastImportReport {
                    ImportReportBanner(report: report) {
                        model.lastImportReport = nil
                    }
                }

                content
            }
            .navigationTitle("Bibliothek")
            .toolbar { toolbarContent }
            .searchable(text: $model.searchText, prompt: Text("Titel oder Ordner suchen"))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importAllowedTypes,
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .onAppear(perform: rebuildTrackIndex)
            .onChange(of: model.tracks) { _, _ in
                rebuildTrackIndex()
            }
        }
    }

    // MARK: - Inhalt

    @ViewBuilder
    private var content: some View {
        if model.tracks.isEmpty && model.importProgress == nil {
            EmptyLibraryView(
                onImportFolder: { presentImporter(forFolders: true) },
                onImportFiles: { presentImporter(forFolders: false) }
            )
        } else if isFiltering {
            filteredList
        } else {
            treeList
        }
    }

    /// Flache Trefferliste bei aktiver Suche oder Favoritenfilter.
    private var filteredList: some View {
        List {
            if model.visibleTracks.isEmpty {
                Text("Keine Treffer.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.visibleTracks) { track in
                    trackRow(LibraryTrackRow(track: track, depth: 0), showsFolderPath: true)
                }
            }
        }
        .listStyle(.plain)
    }

    /// Ordnerbaum.
    private var treeList: some View {
        List {
            ForEach(treeRows) { item in
                switch item {
                case .folder(let row):
                    FolderRowView(row: row) {
                        toggleFolder(row.id)
                    }
                case .track(let row):
                    trackRow(row, showsFolderPath: false)
                }
            }
        }
        .listStyle(.plain)
        // Nach unten ziehen gleicht die Bibliothek mit dem ab, was tatsaechlich
        // im Documents-Ordner liegt — noetig, wenn jemand ueber den Finder
        // Dateien abgelegt oder geloescht hat.
        //
        // Die Aktion ist zwar `async`, laeuft aber auf dem Hauptthread; der
        // Aufruf braucht deshalb kein `await`. Das eigentliche Nachladen startet
        // das Modell selbst im Hintergrund.
        .refreshable {
            model.refreshLibrary()
        }
    }

    /// Eine Titelzeile samt Wisch-Geste fuer den Favoritenstatus.
    private func trackRow(_ row: LibraryTrackRow, showsFolderPath: Bool) -> some View {
        let trackID = row.track.id
        let isFavorite = model.isFavorite(trackID)
        return TrackRowView(row: row,
                            isCurrent: model.currentTrackID == trackID,
                            isFavorite: isFavorite,
                            showsFolderPath: showsFolderPath) {
            model.play(trackID: trackID)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.toggleFavorite(trackID)
            } label: {
                if isFavorite {
                    Label("Favorit entfernen", systemImage: "star.slash")
                } else {
                    Label("Favorit", systemImage: "star")
                }
            }
            .tint(.yellow)
        }
    }

    // MARK: - Werkzeugleiste

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                model.favoritesOnly.toggle()
            } label: {
                Image(systemName: model.favoritesOnly ? "star.fill" : "star")
            }
            .accessibilityLabel(Text("Nur Favoriten"))
            .accessibilityValue(model.favoritesOnly ? Text("An") : Text("Aus"))
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    presentImporter(forFolders: true)
                } label: {
                    Label("Ordner importieren …", systemImage: "folder.badge.plus")
                }
                Button {
                    presentImporter(forFolders: false)
                } label: {
                    Label("Dateien importieren …", systemImage: "doc.badge.plus")
                }

                Divider()

                Button {
                    expandedFolders = LibraryTree.allFolderIDs(of: model.folderTree)
                } label: {
                    Label("Alle Ordner aufklappen", systemImage: "chevron.down")
                }
                Button {
                    expandedFolders.removeAll()
                } label: {
                    Label("Alle Ordner zuklappen", systemImage: "chevron.right")
                }

                Divider()

                Button {
                    model.refreshLibrary()
                } label: {
                    Label("Bibliothek aktualisieren", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel(Text("Bibliothek verwalten"))
        }
    }

    // MARK: - Aktionen

    private func toggleFolder(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedFolders.contains(id) {
                expandedFolders.remove(id)
            } else {
                expandedFolders.insert(id)
            }
        }
    }

    private func presentImporter(forFolders: Bool) {
        importAllowedTypes = forFolders ? [.folder] : [Self.sidContentType]
        showImporter = true
    }

    /// Ergebnis der Dateiauswahl. Ordner und Einzeldateien landen im selben
    /// Dialog-Ergebnis, deshalb wird hier nach Art getrennt: Ordner gehen an den
    /// rekursiven Import, Dateien an den Einzelimport.
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.errorMessage = error.localizedDescription
        case .success(let urls):
            let folders = urls.filter { $0.hasDirectoryPath }
            let files = urls.filter { !$0.hasDirectoryPath }
            for folder in folders {
                model.importFolder(at: folder)
            }
            if !files.isEmpty {
                model.importFiles(at: files)
            }
        }
    }

    /// Baut die Nachschlagetabelle neu auf. Laeuft nur, wenn sich die Titelliste
    /// wirklich geaendert hat — nicht bei jedem Neuzeichnen.
    private func rebuildTrackIndex() {
        var index: [String: LibraryTrack] = [:]
        index.reserveCapacity(model.tracks.count)
        for track in model.tracks {
            index[track.id] = track
        }
        trackIndex = index
    }
}

#Preview {
    LibraryView()
        .environmentObject(AppModel())
}
