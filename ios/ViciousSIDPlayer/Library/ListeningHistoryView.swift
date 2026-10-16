import SwiftUI
import ViciousSIDPlayerCore

struct ListeningHistoryView: View {
    @EnvironmentObject private var model: AppModel
    let onNeverHeard: () -> Void
    @State private var section = 0
    @State private var showClear = false
    @State private var editor: HistoryEditorTarget?
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Verlaufansicht", selection: $section) {
                Text("Hören").tag(0); Text("Marken").tag(1); Text("Notizen").tag(2)
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8)
            List {
                if let error = model.history.storageError {
                    Section { Label(error, systemImage: "exclamationmark.triangle") }
                }
                if !model.history.isLoaded { ProgressView("Wird geladen …") }
                else if section == 0 { events }
                else if section == 1 { bookmarks }
                else { notes }
                Section { Text("Bis zu 2.000 Wiedergaben aus 180 Tagen. „Schon gehört“ bleibt darüber hinaus erhalten.").font(.caption).foregroundStyle(.secondary) }
            }.listStyle(.insetGrouped)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    if let reference = model.currentHistoryReference {
                        Button("Lesezeichen an aktueller Position") {
                            text = String((model.coordinator.trackName + " · " + PlaytimeFormat.string(model.coordinator.elapsedSeconds)).prefix(200))
                            editor = HistoryEditorTarget(reference: reference, position: model.coordinator.elapsedSeconds)
                        }
                        Button("Notiz zum Subtune") { openNote(reference) }
                        Button("Notiz zur Datei") {
                            openNote(ListeningPersonalReference(libraryID: reference.libraryID, trackID: reference.trackID, md5: reference.md5))
                        }
                    }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Lesezeichen oder Notiz hinzufügen")
                .accessibilityIdentifier("history-add")
                .disabled(model.currentHistoryReference == nil || !model.history.isLoaded || model.history.isReadOnly)
                Menu {
                    Button("Noch nie gehört", action: onNeverHeard)
                    Button("Verlauf leeren …", role: .destructive) { showClear = true }
                        .disabled(model.history.isReadOnly || model.history.document.heardMD5s.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Verlauf verwalten")
            }
        }
        .confirmationDialog("Verlauf vollständig leeren?", isPresented: $showClear, titleVisibility: .visible) {
            Button("Verlauf leeren", role: .destructive) { model.history.clearHistory() }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Auch die Kennzeichnung „schon gehört“ wird zurückgesetzt. Lesezeichen und Notizen bleiben erhalten.") }
        .sheet(item: $editor) { target in
            NavigationStack {
                Form {
                    Section { Text(referenceLabel(target.reference)).font(.caption) }
                    if let position = target.position {
                        Section("Lesezeichen") {
                            TextField("Name", text: $text).accessibilityIdentifier("history-bookmark-name")
                            Text("Position \(PlaytimeFormat.string(position))")
                        }
                    } else {
                        Section("Persönliche Notiz") {
                            TextEditor(text: $text).frame(minHeight: 180).accessibilityIdentifier("history-note-text")
                            Text("\(text.count)/16.000 Zeichen").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle(target.position == nil ? "Notiz" : "Lesezeichen")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { editor = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern") {
                            if let position = target.position { model.history.saveBookmark(reference: target.reference, title: text, position: position) }
                            else { model.history.setNote(text, for: target.reference) }
                            editor = nil
                        }.disabled(model.history.isReadOnly || text.count > (target.position == nil ? 16_000 : 200)
                            || (target.position != nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }
            }
        }
    }

    @ViewBuilder private var events: some View {
        if model.history.document.events.isEmpty { empty("Noch nichts gehört", "Wiedergaben erscheinen nach zehn Sekunden oder der Hälfte eines kurzen Subtunes.") }
        ForEach(model.history.document.events) { event in
            VStack(alignment: .leading, spacing: 6) {
                Text(event.title).font(.headline)
                detail(event.reference)
                Text(event.lastHeardAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary)
                Text("\(PlaytimeFormat.string(event.heardSeconds)) gehört").font(.caption).foregroundStyle(.secondary)
                playButtons(event.reference, position: event.lastPosition)
            }.padding(.vertical, 4)
        }
    }
    @ViewBuilder private var bookmarks: some View {
        if model.history.document.bookmarks.isEmpty { empty("Keine Lesezeichen", "Mit + die aktuelle Position speichern.") }
        ForEach(model.history.document.bookmarks) { bookmark in
            VStack(alignment: .leading, spacing: 6) {
                Text(bookmark.name).font(.headline)
                detail(bookmark.reference)
                playButtons(bookmark.reference, position: bookmark.position)
            }.swipeActions { Button("Löschen", role: .destructive) { model.history.removeBookmark(bookmark.id) }.disabled(model.history.isReadOnly) }
        }
    }
    @ViewBuilder private var notes: some View {
        if model.history.document.notes.isEmpty { empty("Keine persönlichen Notizen", "Notizen gelten für die ganze Datei oder einen Subtune.") }
        ForEach(model.history.document.notes) { note in
            VStack(alignment: .leading, spacing: 6) {
                detail(note.reference)
                Text(note.text).lineLimit(4)
                HStack(spacing: 20) {
                    Button("Bearbeiten") { openNote(note.reference) }.disabled(model.history.isReadOnly)
                    Button("Abspielen") { model.playHistoryReference(note.reference, position: 0) }
                }.buttonStyle(.borderless)
            }.padding(.vertical, 4)
        }
    }
    private func playButtons(_ reference: ListeningPersonalReference, position: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 20) {
                Button("Von Anfang") { model.playHistoryReference(reference, position: 0) }
                Button("Ab \(PlaytimeFormat.string(position))") { model.playHistoryReference(reference, position: position) }
                    .disabled(position > ViciousProcessor.maximumSeekSeconds)
            }.buttonStyle(.borderless)
            if position > ViciousProcessor.maximumSeekSeconds { Text("Positionssprünge sind bis 20:00 min möglich.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func detail(_ reference: ListeningPersonalReference) -> some View {
        Text(referenceLabel(reference)).font(.caption).foregroundStyle(.secondary)
    }
    private func referenceLabel(_ reference: ListeningPersonalReference) -> String {
        reference.trackID + (reference.subtune.map { " · Subtune \($0 + 1)" } ?? " · ganze Datei")
    }
    private func empty(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(message).foregroundStyle(.secondary) }
    }
    private func openNote(_ reference: ListeningPersonalReference) {
        text = model.history.document.note(for: reference)?.text ?? ""
        editor = HistoryEditorTarget(reference: reference, position: nil)
    }
}

private struct HistoryEditorTarget: Identifiable {
    let id = UUID()
    let reference: ListeningPersonalReference
    let position: Double?
}
