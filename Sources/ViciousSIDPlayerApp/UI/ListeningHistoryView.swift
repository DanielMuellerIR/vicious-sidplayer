import SwiftUI
import ViciousSIDPlayerCore

struct ListeningHistoryView: View {
    @ObservedObject var controller: ListeningHistoryController
    let currentReference: ListeningPersonalReference?
    let currentTitle: String
    let position: Double
    let isLight: Bool
    let onPlay: (ListeningPersonalReference, Double) -> Void
    let onNeverHeard: () -> Void
    @State private var section = 0
    @State private var showClear = false
    @State private var editor: HistoryEditorTarget?
    @State private var text = ""
    private var secondary: Color { isLight ? .macLightSecondary : .macDarkSecondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VERLAUF").font(.system(size: 11, weight: .semibold))
                Spacer()
                Menu {
                    Button("Noch nie gehört", action: onNeverHeard)
                    Button("Verlauf leeren …", role: .destructive) { showClear = true }
                        .disabled(controller.isReadOnly || controller.document.heardMD5s.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("Verlauf verwalten")
            }
            if let error = controller.storageError {
                Text(error).font(.caption).foregroundStyle(isLight ? Color.macLightWarning : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { openBookmark() } label: { Label("Marke", systemImage: "bookmark.badge.plus") }
                    .help("Aktuelle Position als Lesezeichen speichern")
                    .accessibilityIdentifier("history-add-bookmark")
                Menu {
                    if let reference = currentReference {
                        Button("Notiz zum Subtune") { openNote(reference) }
                        Button("Notiz zur Datei") { openNote(fileReference(reference)) }
                    }
                } label: { Label("Notiz", systemImage: "square.and.pencil") }
                .accessibilityIdentifier("history-add-note")
            }
            .controlSize(.small)
            .disabled(currentReference == nil || !controller.isLoaded || controller.isReadOnly)
            Picker("Verlaufansicht", selection: $section) {
                Text("Hören").tag(0); Text("Marken").tag(1); Text("Notizen").tag(2)
            }.pickerStyle(.segmented).controlSize(.small).labelsHidden()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !controller.isLoaded { ProgressView("Wird geladen …") }
                    else if section == 0 { events }
                    else if section == 1 { bookmarks }
                    else { notes }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Bis zu 2.000 Wiedergaben · 180 Tage").font(.caption2).foregroundStyle(secondary)
        }
        .padding(10)
        .foregroundStyle(isLight ? Color.macLightText : .macDarkText)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Verlauf vollständig leeren?", isPresented: $showClear, titleVisibility: .visible) {
            Button("Verlauf leeren", role: .destructive) { controller.clearHistory() }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Auch die Kennzeichnung „schon gehört“ wird zurückgesetzt. Lesezeichen und Notizen bleiben erhalten.") }
        .sheet(item: $editor) { target in
            VStack(alignment: .leading, spacing: 12) {
                Text(target.position == nil ? "Persönliche Notiz" : "Lesezeichen").font(.headline)
                Text(referenceLabel(target.reference)).font(.caption).foregroundStyle(.secondary)
                if target.position == nil {
                    TextEditor(text: $text).frame(width: 380, height: 180)
                        .accessibilityIdentifier("history-note-text")
                    Text("\(text.count)/16.000 Zeichen").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Name", text: $text).frame(width: 380)
                        .accessibilityIdentifier("history-bookmark-name")
                    Text("Position \(PlaytimeFormat.string(target.position!))").font(.caption)
                }
                HStack {
                    Spacer()
                    Button("Abbrechen") { editor = nil }.keyboardShortcut(.cancelAction)
                    Button("Sichern") {
                        if let position = target.position { controller.saveBookmark(reference: target.reference, title: text, position: position) }
                        else { controller.setNote(text, for: target.reference) }
                        editor = nil
                    }.keyboardShortcut(.defaultAction)
                        .disabled(controller.isReadOnly || text.count > (target.position == nil ? 16_000 : 200)
                            || (target.position != nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }.padding(20)
        }
    }

    @ViewBuilder private var events: some View {
        if controller.document.events.isEmpty { empty("Noch nichts gehört", "Wiedergaben erscheinen nach zehn Sekunden oder der Hälfte eines kurzen Subtunes.") }
        ForEach(controller.document.events) { event in
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                detail(event.reference)
                Text(event.lastHeardAt, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(secondary)
                Text("\(PlaytimeFormat.string(event.heardSeconds)) gehört").font(.caption2).foregroundStyle(secondary)
                playButtons(event.reference, position: event.lastPosition)
                Divider()
            }
        }
    }
    @ViewBuilder private var bookmarks: some View {
        if controller.document.bookmarks.isEmpty { empty("Keine Lesezeichen", "Mit „Marke“ die aktuelle Position speichern.") }
        ForEach(controller.document.bookmarks) { bookmark in
            VStack(alignment: .leading, spacing: 4) {
                Text(bookmark.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                detail(bookmark.reference)
                playButtons(bookmark.reference, position: bookmark.position)
                Button("Lesezeichen löschen", role: .destructive) { controller.removeBookmark(bookmark.id) }
                    .font(.caption).buttonStyle(.borderless).disabled(controller.isReadOnly)
                Divider()
            }
        }
    }
    @ViewBuilder private var notes: some View {
        if controller.document.notes.isEmpty { empty("Keine persönlichen Notizen", "Notizen gelten für die ganze Datei oder einen Subtune.") }
        ForEach(controller.document.notes) { note in
            VStack(alignment: .leading, spacing: 4) {
                detail(note.reference)
                Text(note.text).font(.caption).lineLimit(4)
                HStack {
                    Button("Bearbeiten") { openNote(note.reference) }.disabled(controller.isReadOnly)
                    Button("Abspielen") { onPlay(note.reference, 0) }
                }.controlSize(.small)
                Divider()
            }
        }
    }
    private func playButtons(_ reference: ListeningPersonalReference, position: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button { onPlay(reference, 0) } label: { Image(systemName: "play.fill") }
                    .help("Von Anfang abspielen").accessibilityLabel("Von Anfang abspielen")
                Button("Ab \(PlaytimeFormat.string(position))") { onPlay(reference, position) }
                    .disabled(position > ViciousProcessor.maximumSeekSeconds)
            }.controlSize(.small)
            if position > ViciousProcessor.maximumSeekSeconds {
                Text("Positionssprünge sind bis 20:00 min möglich.").font(.caption2).foregroundStyle(secondary)
            }
        }
    }
    private func detail(_ reference: ListeningPersonalReference) -> some View {
        Text(referenceLabel(reference)).font(.caption2).foregroundStyle(secondary)
            .lineLimit(2).help(referenceLabel(reference))
    }
    private func referenceLabel(_ reference: ListeningPersonalReference) -> String {
        reference.trackID + (reference.subtune.map { " · Subtune \($0 + 1)" } ?? " · ganze Datei")
    }
    private func empty(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 8)
    }
    private func fileReference(_ reference: ListeningPersonalReference) -> ListeningPersonalReference {
        ListeningPersonalReference(libraryID: reference.libraryID, trackID: reference.trackID, md5: reference.md5)
    }
    private func openBookmark() {
        guard let currentReference else { return }
        text = String((currentTitle + " · " + PlaytimeFormat.string(position)).prefix(200))
        editor = HistoryEditorTarget(reference: currentReference, position: position)
    }
    private func openNote(_ reference: ListeningPersonalReference) {
        text = controller.document.note(for: reference)?.text ?? ""
        editor = HistoryEditorTarget(reference: reference, position: nil)
    }
}

private struct HistoryEditorTarget: Identifiable {
    let id = UUID()
    let reference: ListeningPersonalReference
    let position: Double?
}
