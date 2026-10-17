import SwiftUI
import ViciousSIDPlayerCore

enum ListeningPage: String, CaseIterable {
    case library, lists, queue, history
}

struct ListeningView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: ListeningLibraryController
    let page: ListeningPage
    @State private var showName = false
    @State private var name = ""
    @State private var entriesToSave: [ListeningEntry] = []

    var body: some View {
        List {
            if let error = controller.storageError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.primary)
                    if !controller.isReadOnly { Button("Erneut sichern") { controller.retrySave() } }
                }
            }
            if page == .lists { lists } else { queue }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if page == .lists {
                    Button {
                        name = ""; entriesToSave = []; showName = true
                    } label: { Label("Neue Hörfolge", systemImage: "plus") }
                    .disabled(controller.isReadOnly || !controller.isLoaded)
                } else { EditButton() }
            }
        }
        .sheet(isPresented: $showName) {
            ListeningNameSheet(name: $name) {
                _ = model.saveListeningList(name: name, entries: entriesToSave)
                showName = false
            }
        }
    }

    private var lists: some View {
        Section {
            if controller.activeLists.isEmpty {
                ContentUnavailableView("Noch keine Hörfolgen", systemImage: "music.note.list",
                    description: Text("Lege eine Liste an oder sichere eine Auswahl aus der Bibliothek."))
            }
            ForEach(controller.activeLists) { list in
                NavigationLink {
                    ListeningListDetail(controller: controller, listID: list.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(list.kind == .subtuneFavorites ? String(localized: "Lieblings-Subtunes") : list.name)
                        Text("\(list.entries.count) Einträge").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { indices in
                let ids = indices.map { controller.activeLists[$0].id }
                ids.forEach { controller.deleteList($0) }
            }
            .deleteDisabled(controller.isReadOnly)
        }
    }

    @ViewBuilder private var queue: some View {
        if let queue = controller.queue, !queue.items.isEmpty {
            Section {
                Text(queue.name).font(.headline)
                Text("\((queue.currentIndex ?? 0) + 1) / \(queue.items.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Als Liste sichern") {
                    name = queue.name; entriesToSave = queue.items; showName = true
                }.disabled(controller.isReadOnly)
                Button("Hörfolge beenden", role: .destructive) {
                    model.endListeningQueue()
                }
            }
            Section {
                ForEach(queue.items) { entry in
                    ListeningEntryRow(entry: entry, current: queue.currentID == entry.id,
                        available: controller.availableTrackIDs.contains(entry.trackID)) {
                        model.selectListeningEntry(entry.id)
                    }
                    .deleteDisabled(queue.currentID == entry.id)
                }
                .onDelete { offsets in offsets.map { queue.items[$0].id }.forEach { controller.removeQueueEntry($0) } }
                .onMove { controller.moveQueueEntries(fromOffsets: $0, toOffset: $1) }
            }
        } else {
            ContentUnavailableView("Noch keine Hörfolge", systemImage: "text.line.first.and.arrowtriangle.forward",
                description: Text("Starte eine Auswahl oder eine gespeicherte Liste."))
        }
    }
}

private struct ListeningListDetail: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: ListeningLibraryController
    let listID: UUID
    @State private var showRename = false
    @State private var name = ""
    @State private var editingEntry: ListeningEntry?
    @State private var selectedSubtune = 1
    @State private var subtuneCount = 1
    private var list: SavedListeningList? { controller.lists.first { $0.id == listID } }

    var body: some View {
        List {
            if let list {
                Section {
                    Button("Abspielen") { model.startSavedListeningList(list) }.disabled(list.entries.isEmpty)
                    Button("Aktuellen Subtune hinzufügen") { model.appendCurrentSubtune(to: listID) }
                        .disabled(model.currentTrackID == nil || controller.isReadOnly)
                    Text("Änderungen gelten beim nächsten Start").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(list.entries) { entry in
                        ListeningEntryRow(entry: entry, current: false,
                            available: controller.availableTrackIDs.contains(entry.trackID)) {
                            model.startSavedListeningList(list, entryID: entry.id)
                        }
                        .contextMenu {
                            Button("Als Nächstes") { model.enqueueNext(trackID: entry.trackID, subtune: entry.subtune) }
                            if list.kind == .regular {
                                Button("Alle Subtunes") { controller.setSubtune(nil, entryID: entry.id, listID: listID) }
                                    .disabled(controller.isReadOnly)
                                Button("Subtune auswählen") {
                                    guard let count = model.listeningSubtuneCount(for: entry) else { return }
                                    subtuneCount = count; selectedSubtune = min(count, (entry.subtune ?? 0) + 1); editingEntry = entry
                                }.disabled(controller.isReadOnly)
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { list.entries[$0].id }.forEach { controller.removeListEntry($0, from: listID) } }
                    .onMove { controller.moveListEntries(in: listID, fromOffsets: $0, toOffset: $1) }
                    .deleteDisabled(controller.isReadOnly)
                    .moveDisabled(controller.isReadOnly)
                    if list.entries.isEmpty { Text("Diese Liste ist leer").foregroundStyle(.secondary) }
                }
            }
        }
        .navigationTitle(list.map { $0.kind == .subtuneFavorites ? String(localized: "Lieblings-Subtunes") : $0.name } ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if list?.kind == .regular {
                    Button { name = list?.name ?? ""; showRename = true } label: { Label("Umbenennen", systemImage: "pencil") }
                        .disabled(controller.isReadOnly)
                }
                EditButton()
            }
        }
        .sheet(isPresented: $showRename) {
            ListeningNameSheet(name: $name) { controller.renameList(listID, to: name); showRename = false }
        }
        .sheet(item: $editingEntry) { entry in
            NavigationStack {
                Form { Stepper("Subtune \(selectedSubtune) / \(subtuneCount)", value: $selectedSubtune, in: 1...max(1, subtuneCount)) }
                    .navigationTitle("Subtune auswählen")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { editingEntry = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Übernehmen") {
                                controller.setSubtune(selectedSubtune - 1, entryID: entry.id, listID: listID); editingEntry = nil
                            }
                        }
                    }
            }
        }
    }
}

private struct ListeningEntryRow: View {
    let entry: ListeningEntry
    let current: Bool
    let available: Bool
    let onPlay: () -> Void
    var body: some View {
        Button(action: onPlay) {
            HStack {
                if current { Image(systemName: "play.fill") }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).foregroundStyle(.primary)
                    if let sub = entry.subtune { Text("Subtune \(sub + 1)").font(.caption).foregroundStyle(.secondary) }
                    else { Text("Alle Subtunes").font(.caption).foregroundStyle(.secondary) }
                    if !available { Text("Nicht in Bibliothek").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityIdentifier("listening-entry-\(entry.id.uuidString)")
    }
}

struct ListeningNameSheet: View {
    @Binding var name: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form { TextField("Name", text: $name).accessibilityIdentifier("listening-list-name") }
                .navigationTitle("Hörfolge sichern")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Sichern", action: onSave).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
