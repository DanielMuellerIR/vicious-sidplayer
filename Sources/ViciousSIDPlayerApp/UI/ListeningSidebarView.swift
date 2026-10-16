import SwiftUI
import ViciousSIDPlayerCore

enum LibrarySidebarPage: String, CaseIterable {
    case library
    case lists
    case queue
    case history
}

struct ListeningSidebarView: View {
    @ObservedObject var controller: ListeningLibraryController
    @Binding var selectedListID: UUID?
    let page: LibrarySidebarPage
    let isLight: Bool
    let hasCurrentTrack: Bool
    let onNewList: () -> Void
    let onRenameList: (SavedListeningList) -> Void
    let onPlayList: (SavedListeningList, UUID?) -> Void
    let onAppendCurrent: (UUID) -> Void
    let onEditSubtune: (SavedListeningList, ListeningEntry) -> Void
    let onPlayQueueEntry: (UUID) -> Void
    let onSaveQueue: () -> Void
    let onEndQueue: () -> Void

    @State private var showDelete = false

    private var textColor: Color { isLight ? .macLightText : .macDarkText }
    private var secondaryColor: Color { isLight ? .macLightSecondary : .macDarkSecondary }
    private var accent: Color { isLight ? .macLightAccent : .macDarkAccent }
    private var warningColor: Color { isLight ? .macLightWarning : .orange }
    private var selectedList: SavedListeningList? { controller.lists.first { $0.id == selectedListID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = controller.storageError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                if !controller.isReadOnly {
                    Button("Erneut sichern") { controller.retrySave() }
                        .controlSize(.small)
                }
            }
            if page == .lists { listsContent } else { queueContent }
            if controller.isSaving {
                Text("Wird gesichert …")
                    .font(.caption2)
                    .foregroundColor(secondaryColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .foregroundColor(textColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Liste löschen?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Liste löschen", role: .destructive) {
                if let id = selectedListID { controller.deleteList(id) }
                selectedListID = controller.activeLists.first?.id
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die gespeicherte Hörfolge wird entfernt. Die Musikdateien bleiben erhalten.")
        }
        .onAppear {
            if selectedListID == nil { selectedListID = controller.activeLists.first?.id }
        }
    }

    private var listsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HÖRFOLGEN").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(action: onNewList) { Image(systemName: "plus") }
                    .help("Neue Hörfolge anlegen")
                    .accessibilityLabel("Neue Hörfolge")
                    .disabled(controller.isReadOnly)
            }
            if controller.lists.isEmpty {
                emptyState("Noch keine Hörfolgen", detail: "Speichere eine Auswahl aus der Bibliothek oder lege mit + eine Liste an.")
            } else {
                Picker("Hörfolge", selection: $selectedListID) {
                    Text("Liste auswählen").tag(nil as UUID?)
                    ForEach(controller.lists) { list in
                        Text(list.name + (list.libraryID == controller.activeLibraryID ? "" : " · andere Sammlung"))
                            .tag(Optional(list.id))
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("listening-list-picker")
                if let list = selectedList {
                    listDetails(list)
                }
            }
        }
    }

    private func listDetails(_ list: SavedListeningList) -> some View {
        let sameLibrary = list.libraryID == controller.activeLibraryID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Abspielen") { onPlayList(list, nil) }
                    .disabled(!sameLibrary || list.entries.isEmpty)
                    .accessibilityIdentifier("play-list")
                Spacer(minLength: 0)
                if list.kind == .regular {
                    Button { onRenameList(list) } label: { Image(systemName: "pencil") }
                        .help("Hörfolge umbenennen")
                        .disabled(controller.isReadOnly)
                }
                Button { showDelete = true } label: { Image(systemName: "trash") }
                    .help("Hörfolge löschen")
                    .disabled(controller.isReadOnly)
            }
            .controlSize(.small)
            if !sameLibrary {
                Text("Diese Liste gehört zu einer anderen Sammlung. Wähle deren Autoplay-Ordner, um sie abzuspielen.")
                    .font(.caption)
                    .foregroundColor(secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Aktuellen Subtune hinzufügen") { onAppendCurrent(list.id) }
                .font(.caption)
                .disabled(!sameLibrary || !hasCurrentTrack || controller.isReadOnly)
                .accessibilityIdentifier("append-current-subtune")
            Text("\(list.entries.count) Einträge · Änderungen gelten beim nächsten Start")
                .font(.caption2)
                .foregroundColor(secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if list.entries.isEmpty {
                emptyState("Diese Liste ist leer", detail: "Füge den laufenden Subtune hinzu oder verwende das Kontextmenü eines Bibliothekstitels.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(list.entries) { entry in
                            entryRow(entry, current: false,
                                     isFirst: list.entries.first?.id == entry.id,
                                     isLast: list.entries.last?.id == entry.id,
                                     canEdit: !controller.isReadOnly,
                                     onPlay: { onPlayList(list, entry.id) },
                                     onMove: { controller.moveListEntry(entry.id, in: list.id, by: $0) },
                                     onRemove: { controller.removeListEntry(entry.id, from: list.id) })
                                .disabled(!sameLibrary)
                                .contextMenu {
                                    Button("Als Nächstes") { controller.enqueueNext(entry) }
                                        .disabled(controller.queue == nil || !sameLibrary)
                                    if list.kind == .regular {
                                        Button("Alle Subtunes") { controller.setSubtune(nil, entryID: entry.id, listID: list.id) }
                                            .disabled(controller.isReadOnly)
                                        Button("Subtune auswählen …") { onEditSubtune(list, entry) }
                                            .disabled(controller.isReadOnly || !sameLibrary)
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var queueContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WARTESCHLANGE").font(.system(size: 11, weight: .semibold))
            if let queue = controller.queue, !queue.items.isEmpty {
                Text(queue.name).font(.headline).lineLimit(2)
                Text("\((queue.currentIndex ?? 0) + 1) / \(queue.items.count) · \(queue.shuffled ? "Zufall" : "Reihenfolge")")
                    .font(.caption)
                    .foregroundColor(secondaryColor)
                HStack {
                    Button("Als Liste sichern", action: onSaveQueue)
                        .disabled(controller.isReadOnly)
                    Spacer(minLength: 0)
                    Button(action: onEndQueue) { Image(systemName: "stop.circle") }
                        .help("Hörfolge beenden")
                        .accessibilityLabel("Hörfolge beenden")
                }
                .controlSize(.small)
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(queue.items) { entry in
                            entryRow(entry, current: entry.id == queue.currentID,
                                     isFirst: queue.items.first?.id == entry.id,
                                     isLast: queue.items.last?.id == entry.id,
                                     canEdit: true,
                                     onPlay: { onPlayQueueEntry(entry.id) },
                                     onMove: { controller.moveQueueEntry(entry.id, by: $0) },
                                     onRemove: { controller.removeQueueEntry(entry.id) })
                        }
                    }
                    .padding(.vertical, 3)
                }
            } else {
                emptyState("Noch keine Hörfolge", detail: "Starte eine Auswahl in der Bibliothek oder eine gespeicherte Liste.")
            }
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundColor(secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func entryRow(_ entry: ListeningEntry, current: Bool, isFirst: Bool, isLast: Bool,
                          canEdit: Bool, onPlay: @escaping () -> Void,
                          onMove: @escaping (Int) -> Void, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Button(action: onPlay) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        if current { Image(systemName: "play.fill").font(.caption2) }
                        Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    }
                    Text(entry.detail).font(.caption2).foregroundColor(secondaryColor)
                    if !controller.availableTrackIDs.contains(entry.trackID) {
                        Text("Nicht in Bibliothek").font(.caption2).foregroundColor(warningColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.trackID + " · " + entry.detail)
            .accessibilityLabel(entry.title + ", " + entry.detail
                + (controller.availableTrackIDs.contains(entry.trackID) ? "" : ", Nicht in Bibliothek"))
            .accessibilityIdentifier("listening-entry-\(entry.id.uuidString)")
            rowButton("chevron.up", help: "Nach oben", disabled: isFirst || !canEdit) { onMove(-1) }
                .accessibilityIdentifier("listening-up-\(entry.id.uuidString)")
            rowButton("chevron.down", help: "Nach unten", disabled: isLast || !canEdit) { onMove(1) }
                .accessibilityIdentifier("listening-down-\(entry.id.uuidString)")
            rowButton("minus.circle", help: current ? "Laufender Eintrag" : "Eintrag entfernen", disabled: current || !canEdit, action: onRemove)
                .accessibilityIdentifier("listening-remove-\(entry.id.uuidString)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(current ? accent.opacity(0.15) : Color.clear)
        .cornerRadius(5)
    }

    private func rowButton(_ symbol: String, help: String, disabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10)).frame(width: 22, height: 24) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
            .disabled(disabled)
    }
}

struct ListeningNameSheet: View {
    @Binding var name: String
    let renaming: Bool
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(renaming ? "Hörfolge umbenennen" : "Hörfolge sichern").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("listening-list-name")
                .focused($nameFocused)
                .onSubmit { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSave() } }
            HStack {
                Spacer()
                Button("Abbrechen", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Sichern", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { nameFocused = true }
    }
}

struct ListeningSubtuneSheet: View {
    @Binding var subtune: Int
    let count: Int
    let title: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Stepper("Subtune \(subtune) / \(count)", value: $subtune, in: 1...max(1, count))
            HStack {
                Spacer()
                Button("Abbrechen", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Übernehmen", action: onSave).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
