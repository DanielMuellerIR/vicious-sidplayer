import SwiftUI
import ViciousSIDPlayerCore

struct MetadataSearchTools: View {
    @ObservedObject var metadata: LibraryMetadataController
    @ObservedObject var saved: SavedLibrarySearchController
    @Binding var query: String
    @Binding var favoritesOnly: Bool
    @State private var editorRequest: SavedSearchEditorRequest?
    @State private var name = ""
    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(saved.document.searches) { search in
                        Button(search.name) { query = search.query; favoritesOnly = search.favoritesOnly }
                    }
                    Divider()
                    Button("Suche sichern") { name = ""; editorRequest = SavedSearchEditorRequest(editingID: nil) }
                        .disabled(saved.isReadOnly || !saved.isLoaded || LibrarySearchQuery(query).error != nil)
                    Menu("Verwalten") {
                        ForEach(saved.document.searches) { search in
                            Menu(search.name) {
                                Button("Umbenennen") { name = search.name; editorRequest = SavedSearchEditorRequest(editingID: search.id) }
                                Button("Löschen", role: .destructive) { saved.remove(search.id) }
                            }
                        }
                    }.disabled(saved.isReadOnly || saved.document.searches.isEmpty)
                } label: {
                    Label("Suchansichten", systemImage: "line.3.horizontal.decrease.circle")
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("saved-library-searches")
                Spacer()
                Button { showHelp = true } label: {
                    Label("Suchhilfe", systemImage: "questionmark.circle")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
            }
            if let error = LibrarySearchQuery(query).error { Label(error, systemImage: "exclamationmark.triangle") }
            if metadata.isIndexing { Text("Metadaten: \(metadata.indexedCount)/\(metadata.totalCount)").foregroundStyle(.secondary) }
            if metadata.storageError != nil { Text("Metadatencache konnte nicht gesichert werden.") }
            if let error = saved.error {
                Text(error)
                if !saved.isReadOnly { Button("Erneut sichern") { saved.retrySave() } }
            }
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .sheet(item: $editorRequest) { request in
            NavigationStack {
                Form { TextField("Name", text: $name).accessibilityIdentifier("saved-search-name") }
                    .navigationTitle(request.editingID == nil ? "Suchansicht sichern" : "Suchansicht umbenennen")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { editorRequest = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Sichern") {
                                if let editingID = request.editingID { saved.rename(editingID, to: name) }
                                else { saved.save(name: name, query: query, favoritesOnly: favoritesOnly) }
                                editorRequest = nil
                            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                List {
                    Section("Suchfelder") {
                        Text("Wörter durchsuchen Dateiname, Ordner und Metadaten.")
                        Text("Felder: title:, author:, released:, chips:, model:")
                        Text("Dauer von Subtune 1: min:1:00 max:3:00")
                        Text("Hörstatus: heard:never heard:yes heard:unknown")
                        Text("Unbekannt: duration:unknown model:unknown metadata:unknown")
                        Text("Mehrere Begriffe gelten zusammen. Leerzeichen in Werten: author:\"Rob Hubbard\"")
                    }
                    Section("Beispiele") {
                        Button("3SID") { query = "chips:3"; showHelp = false }
                        Button("Kurze Titel") { query = "max:3:00"; showHelp = false }
                        Button("Unbekannte Dauer") { query = "duration:unknown"; showHelp = false }
                    }
                }
                .navigationTitle("Suchhilfe")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showHelp = false } } }
            }
        }
    }
}

private struct SavedSearchEditorRequest: Identifiable {
    let id = UUID()
    let editingID: UUID?
}
