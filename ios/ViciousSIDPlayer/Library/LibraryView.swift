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
// Suchtreffer koennen ausdruecklich als Hoerfolge gestartet werden. Spaetere
// Filteraenderungen veraendern deren Reihenfolge nicht.
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
    @State private var showCollectionTransfer = false
    @State private var page = ListeningPage.library
    @FocusState private var searchIsFocused: Bool
    @State private var showListeningName = false
    @State private var listeningName = ""
    @State private var entriesToSave: [ListeningEntry] = []
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
                Picker("Sammlungsansicht", selection: $page) {
                    Text("Musik").tag(ListeningPage.library)
                    Text("Listen").tag(ListeningPage.lists)
                    Text("Folge").tag(ListeningPage.queue)
                    Text("Verlauf").tag(ListeningPage.history)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .accessibilityIdentifier("library-listening-tabs")
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

                if page == .library {
                    searchBar
                    content
                } else if page == .history {
                    ListeningHistoryView { model.searchText = "heard:never"; page = .library }
                } else {
                    ListeningView(controller: model.listening, page: page)
                }
            }
            .navigationTitle("Bibliothek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showListeningName) {
                ListeningNameSheet(name: $listeningName) {
                    _ = model.saveListeningList(name: listeningName, entries: entriesToSave)
                    showListeningName = false; page = .lists
                }
            }
            .sheet(isPresented: $showCollectionTransfer, onDismiss: { model.collectionTransfer.reset() }) {
                PersonalCollectionView(controller: model.collectionTransfer)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importAllowedTypes,
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .onAppear(perform: rebuildTrackIndex)
            .onChange(of: page) { _, _ in searchIsFocused = false }
            .onChange(of: model.tracks) { _, _ in
                rebuildTrackIndex()
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Titel, Autor oder Suchfelder", text: $model.searchText)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .focused($searchIsFocused).submitLabel(.search)
                        .onSubmit { searchIsFocused = false }
                        .accessibilityIdentifier("library-search")
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel("Suche leeren")
                    }
                }
                .padding(.horizontal, 10).frame(minHeight: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                MetadataSearchTools(saved: model.savedSearches,
                    query: $model.searchText, favoritesOnly: $model.favoritesOnly)
            }
            MetadataSearchStatus(metadata: model.metadataIndex, saved: model.savedSearches, query: model.searchText)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
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
        .environment(\.defaultMinListRowHeight, 44)
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
                    .contextMenu {
                        Button("Ordner abspielen") { model.startListeningScope(.folder(row.id), name: row.name); page = .queue }
                        Button("Ordner als Hörfolge sichern") { prepareListeningList(scope: .folder(row.id), name: row.name) }
                            .disabled(model.listening.isReadOnly)
                    }
                case .track(let row):
                    trackRow(row, showsFolderPath: false)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
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
                            showsFolderPath: showsFolderPath,
                            metadata: model.metadataIndex.records[trackID]?.metadata,
                            duration: model.metadataIndex.records[trackID]?.metadata.flatMap(model.knownLibraryDuration)) {
            searchIsFocused = false
            model.select(trackID: trackID)
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
        .contextMenu {
            Button("Als Nächstes") { model.enqueueNext(trackID: trackID) }
            Menu("Zu Hörfolge hinzufügen") {
                ForEach(model.listening.activeLists.filter { $0.kind == .regular }) { list in
                    Button(list.name) { model.listening.append(ListeningEntry(trackID: trackID), to: list.id) }
                }
            }.disabled(model.listening.isReadOnly)
            Button("Neue Hörfolge mit diesem Titel") {
                entriesToSave = [ListeningEntry(trackID: trackID)]; listeningName = row.track.name; showListeningName = true
            }.disabled(model.listening.isReadOnly)
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

    private func prepareListeningList(scope: ListeningScope, name: String) {
        entriesToSave = model.listeningEntries(scope: scope); listeningName = name; showListeningName = true
    }

    // MARK: - Werkzeugleiste

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Gesamte Bibliothek abspielen") { model.startListeningScope(.library, name: String(localized: "Bibliothek")); page = .queue }
                Button("Sichtbare Auswahl abspielen") {
                    model.startListeningScope(.visible(searchText: model.searchText, favoritesOnly: model.favoritesOnly), name: String(localized: "Auswahl")); page = .queue
                }
                Button("Favoriten abspielen") { model.startListeningScope(.favorites, name: String(localized: "Favoriten")); page = .queue }
                Divider()
                Button("Sichtbare Auswahl sichern") { prepareListeningList(scope: .visible(searchText: model.searchText, favoritesOnly: model.favoritesOnly), name: String(localized: "Auswahl")) }
                    .disabled(model.listening.isReadOnly)
            } label: { Label("Auswahl", systemImage: "music.note.list") }
            .disabled(model.tracks.isEmpty || !model.listening.isLoaded)
            .accessibilityIdentifier("listening-selection-menu")
        }
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

                Button { model.collectionTransfer.reset(); showCollectionTransfer = true } label: {
                    Label("Persönliche Sammlungsdaten …", systemImage: "arrow.left.arrow.right")
                }.accessibilityIdentifier("collection-open")

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
