import SwiftUI
import ViciousSIDPlayerCore

struct LibrarySearchTools: View {
    @ObservedObject var metadata: LibraryMetadataController
    @ObservedObject var saved: SavedLibrarySearchController
    @Binding var query: String
    @Binding var favoritesOnly: Bool
    let isLight: Bool
    @State private var editorRequest: SavedSearchEditorRequest?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Menu("Suchansichten") {
                    ForEach(saved.document.searches) { search in
                        Button(search.name) { query = search.query; favoritesOnly = search.favoritesOnly }
                    }
                    Divider()
                    Button("Suche sichern …") { name = ""; editorRequest = SavedSearchEditorRequest(editingID: nil) }
                        .disabled(saved.isReadOnly || !saved.isLoaded || LibrarySearchQuery(query).error != nil)
                    Menu("Verwalten") {
                        ForEach(saved.document.searches) { search in
                            Menu(search.name) {
                                Button("Umbenennen …") { name = search.name; editorRequest = SavedSearchEditorRequest(editingID: search.id) }
                                Button("Löschen", role: .destructive) { saved.remove(search.id) }
                            }
                        }
                    }.disabled(saved.isReadOnly || saved.document.searches.isEmpty)
                }
                .controlSize(.small)
                .accessibilityIdentifier("saved-library-searches")
                Menu {
                    Text("Wörter durchsuchen Dateiname, Ordner und Metadaten.")
                    Text("Felder: title:, author:, released:, chips:, model:")
                    Text("Dauer von Subtune 1: min:1:00 max:3:00")
                    Text("Hörstatus: heard:never heard:yes heard:unknown")
                    Text("Unbekannt: duration:unknown model:unknown metadata:unknown")
                    Text("Mehrere Begriffe gelten zusammen. Leerzeichen in Werten: author:\"Rob Hubbard\"")
                    Divider()
                    Button("Beispiel: 3SID") { query = "chips:3" }
                    Button("Beispiel: kurze Titel") { query = "max:3:00" }
                    Button("Beispiel: unbekannte Dauer") { query = "duration:unknown" }
                } label: { Image(systemName: "questionmark.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Suchfelder und Beispiele")
            }
            if let error = LibrarySearchQuery(query).error { Text(error).foregroundStyle(isLight ? Color.macLightWarning : .orange) }
            if metadata.isIndexing { Text("Metadaten: \(metadata.indexedCount)/\(metadata.totalCount)") }
            if metadata.storageError != nil { Text("Metadatencache konnte nicht gesichert werden.") }
            if let error = saved.error {
                Text(error)
                if !saved.isReadOnly { Button("Erneut sichern") { saved.retrySave() }.buttonStyle(.plain) }
            }
        }
        .font(.caption2)
        .foregroundStyle(isLight ? Color.macLightSecondary : .macDarkSecondary)
        .padding(.horizontal, 12).padding(.bottom, 6)
        .sheet(item: $editorRequest) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text(request.editingID == nil ? "Suchansicht sichern" : "Suchansicht umbenennen").font(.headline)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("saved-search-name")
                HStack {
                    Button("Abbrechen") { editorRequest = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Sichern") {
                        if let editingID = request.editingID { saved.rename(editingID, to: name) }
                        else { saved.save(name: name, query: query, favoritesOnly: favoritesOnly) }
                        editorRequest = nil
                    }.keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 340)
        }
    }
}

private struct SavedSearchEditorRequest: Identifiable {
    let id = UUID()
    let editingID: UUID?
}
