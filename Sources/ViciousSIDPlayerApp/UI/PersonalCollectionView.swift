import SwiftUI
import UniformTypeIdentifiers
import ViciousSIDPlayerCore

// Gemeinsame Ansicht beider nativen Apps; das iOS-Projekt bindet diese Datei
// direkt ein. Dateiauswahl und Darstellung bleiben außerhalb des Core.
struct PersonalCollectionView: View {
    @ObservedObject var controller: PersonalCollectionController
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var exportFile: CollectionTransferFile?
    @State private var exportSaved = false
    @State private var conflictPage = 0
    @State private var issuePage = 0
    @State private var expandedConflicts: Set<String> = []
    private let pageSize = 20

    var body: some View {
        #if os(iOS)
        configuredPresentation.onChange(of: mode) { _, _ in resetMode() }
        #else
        configuredPresentation.onChange(of: mode) { _ in resetMode() }
        #endif
    }
    private func resetMode() {
        controller.reset(); conflictPage = 0; issuePage = 0; expandedConflicts = []; exportSaved = false
    }
    private var configuredPresentation: some View {
        presentation
            .task { await controller.ready() }
            .interactiveDismissDisabled(controller.isApplying)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): Task { await controller.readImport(from: url) }
                case .failure(let error): if (error as? CocoaError)?.code != .userCancelled { controller.report(error) }
                }
            }
            .fileExporter(isPresented: $showExporter, document: exportFile, contentType: .json,
                          defaultFilename: "Sammlungsdaten.vicious-collection") { result in
                switch result {
                case .success: exportSaved = true
                case .failure(let error): if (error as? CocoaError)?.code != .userCancelled { controller.report(error) }
                }
            }
    }

    @ViewBuilder private var presentation: some View {
        #if os(iOS)
        NavigationStack {
            content
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Sammlungsdaten").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { closeButton } }
        }
        #else
        VStack(alignment: .leading, spacing: 0) {
            Text("Persönliche Sammlungsdaten").font(.title2.weight(.semibold)).padding(20)
            Divider()
            content
            Divider()
            HStack { Spacer(); closeButton.keyboardShortcut(.cancelAction) }.padding(16)
        }.frame(minWidth: 680, idealWidth: 740, maxWidth: 900, minHeight: 600, idealHeight: 720, maxHeight: 900)
        #endif
    }
    private var closeButton: some View {
        Button("Schließen") { dismiss() }
            .disabled(controller.isApplying && !controller.requiresRestart)
            .accessibilityIdentifier("collection-close")
    }
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Favoriten, Hörlisten, Lesezeichen, Notizen und Endzeiten in eine andere Sammlung übernehmen. Musikdateien werden nicht mitkopiert.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Aktion", selection: $mode) {
                    Text("Exportieren").tag(0); Text("Importieren").tag(1)
                }.pickerStyle(.segmented).accessibilityIdentifier("collection-mode")
                    .disabled(controller.isBusy || controller.isApplying || controller.requiresRestart)
                if let error = controller.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                if let completion = controller.completion { Label(completion, systemImage: "checkmark.circle").font(.subheadline) }
                if exportSaved { Label("Die Exportdatei wurde gesichert.", systemImage: "checkmark.circle").font(.subheadline) }
                if controller.isBusy {
                    ProgressView(controller.isApplying ? "Daten werden übernommen …" : "Sammlung und Dateiidentitäten werden geprüft …")
                        .font(.subheadline)
                }
                if mode == 1 {
                    Button("Sammlungsdatei auswählen …") { showImporter = true }
                        .accessibilityIdentifier("collection-import-file")
                        .disabled(controller.isBusy || controller.isApplying || controller.requiresRestart)
                    if let document = controller.importedDocument {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Quelle: \(document.name)").font(.headline)
                            Text(document.createdAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if controller.completion == nil {
                        Text("Eine vorhandene Exportdatei auswählen. Die Vorschau verändert noch keine persönlichen Daten.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if mode == 0 || controller.importedDocument != nil {
                    areaSelection
                    if mode == 0 { exportActions } else { importPreview }
                }
            }.padding(20)
        }
    }
    private var areaSelection: some View {
        GroupBox("Bereiche") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(PersonalCollectionArea.allCases) { area in
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(isOn: Binding(get: { controller.areas.contains(area) }, set: { enabled in
                            Task { await controller.select(area, enabled: enabled) }
                        })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(area.title)
                                if controller.availableAreas.contains(area), let document = controller.importedDocument ?? controller.exportReport?.document {
                                    if area == .history {
                                        Text("\(countText(document.history?.events.count ?? 0, singular: "Wiedergabe", plural: "Wiedergaben")) · \(countText(document.history?.heardMD5s.count ?? 0, singular: "Gehört-Kennzeichnung", plural: "Gehört-Kennzeichnungen"))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else { Text(countText(document.count(in: area), singular: "Eintrag", plural: "Einträge")).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                        .accessibilityIdentifier("collection-area-\(area.rawValue)")
                        .disabled(controller.isBusy || controller.isApplying || controller.requiresRestart
                            || !controller.availableAreas.contains(area)
                            || (mode == 1 && controller.importedDocument?.count(in: area) == 0))
                        if !controller.availableAreas.contains(area) {
                            Text("Ablage schreibgeschützt oder noch nicht geladen").font(.caption).foregroundStyle(.secondary)
                                .padding(.leading, 22).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Hörverlauf ist standardmäßig aus. Seine Auswahl umfasst auch die gesamte, sammlungsübergreifende Gehört-Kennzeichnung.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(8)
        }
    }
    private var exportActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Export vorbereiten") { Task { await controller.prepareExport() } }
                .accessibilityIdentifier("collection-prepare-export")
                .disabled(controller.isBusy || controller.areas.isEmpty || controller.requiresRestart)
            if let report = controller.exportReport, let data = controller.exportData {
                Text("Der vorbereitete Export enthält \(data.count.formatted()) Bytes.").font(.subheadline)
                if !report.unverifiedReferences.isEmpty {
                    Label("\(countText(report.unverifiedReferences.count, singular: "Referenz hat", plural: "Referenzen haben")) keinen Inhaltsfingerabdruck. Ihre Zuordnung muss am Ziel bestätigt werden.", systemImage: "info.circle")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if report.omittedEndTimeCount > 0 {
                    Text("\(countText(report.omittedEndTimeCount, singular: "Endzeit", plural: "Endzeiten")) ohne Zuordnung zu dieser Sammlung \(report.omittedEndTimeCount == 1 ? "wird" : "werden") ausgelassen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Datei sichern …") { exportFile = CollectionTransferFile(bytes: data); showExporter = true }
                    .accessibilityIdentifier("collection-save-export")
            }
        }
    }
    @ViewBuilder private var importPreview: some View {
        if let preview = controller.preview {
            GroupBox("Vorschau") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(countText(preview.additions, singular: "Ergänzung", plural: "Ergänzungen")) · \(countText(preview.updates, singular: "Aktualisierung", plural: "Aktualisierungen")) · \(preview.duplicates) unverändert")
                    if preview.heardAddedCount > 0 { Text(countText(preview.heardAddedCount, singular: "zusätzliche Gehört-Kennzeichnung", plural: "zusätzliche Gehört-Kennzeichnungen")) }
                    if !preview.hasChanges { Text("Diese Auswahl ist bereits vorhanden. Es ist keine Übernahme nötig.").foregroundStyle(.secondary) }
                }.font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if !preview.conflicts.isEmpty { conflicts(preview.conflicts) }
            if !preview.unresolved.isEmpty { unresolved(preview.unresolved) }
            if preview.skippedPathEntries > 0 {
                Toggle("\(countText(preview.skippedPathEntries, singular: "nicht zugeordneten Favoriten- oder Listeneintrag", plural: "nicht zugeordnete Favoriten- oder Listeneinträge")) auslassen", isOn: $controller.confirmedSkippedEntries)
                    .font(.subheadline).accessibilityIdentifier("collection-confirm-skip")
                    .disabled(controller.isBusy || controller.isApplying)
            }
            HStack(spacing: 16) {
                Button("Vorschau neu laden") { Task { await controller.refreshPreview() } }
                    .disabled(controller.isBusy || controller.isApplying || controller.requiresRestart)
                Button("Zusammenführen") { Task { await controller.apply() } }
                    .buttonStyle(.borderedProminent).disabled(!controller.canApply)
                    .accessibilityIdentifier("collection-apply")
            }
            Text("Die Wiedergabe wird zur Übernahme kurz pausiert und anschließend gegebenenfalls fortgesetzt. Ein inzwischen abgelaufener Einschlaftimer bleibt beendet.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func conflicts(_ values: [PersonalCollectionConflict]) -> some View {
        GroupBox(countText(values.count, singular: "Konflikt", plural: "Konflikte")) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(values.dropFirst(boundedPage(conflictPage, count: values.count) * pageSize).prefix(pageSize))) { conflict in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(conflict.label).font(.headline).lineLimit(2)
                        Text("Vorhanden: \(conflict.existingValue)").font(.caption)
                            .lineLimit(expandedConflicts.contains(conflict.id) ? nil : 4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Import: \(conflict.importedValue)").font(.caption)
                            .lineLimit(expandedConflicts.contains(conflict.id) ? nil : 4).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(expandedConflicts.contains(conflict.id) ? "Werte einklappen" : "Vollständige Werte anzeigen") {
                            if !expandedConflicts.insert(conflict.id).inserted { expandedConflicts.remove(conflict.id) }
                        }
                        .font(.caption)
                        #if os(iOS)
                        .frame(minHeight: 44)
                        #endif
                        .accessibilityIdentifier("collection-expand-\(conflict.id)")
                        if let explanation = conflict.explanation { Text(explanation).font(.caption).foregroundStyle(.secondary) }
                        Picker("Übernehmen", selection: Binding(get: { controller.choices[conflict.id] ?? .keepExisting }, set: { choice in
                            Task { await controller.choose(choice, for: conflict.id) }
                        })) {
                            Text("Vorhandene behalten").tag(PersonalCollectionMergeChoice.keepExisting)
                            Text("Importierte übernehmen").tag(PersonalCollectionMergeChoice.useImported)
                        }
                        .accessibilityIdentifier("collection-choice-\(conflict.id)")
                        .disabled(!conflict.canUseImported || controller.isBusy || controller.isApplying)
                        Divider()
                    }
                }
                pager(count: values.count, page: pageBinding($conflictPage, count: values.count))
            }.padding(8)
        }
    }
    private func unresolved(_ values: [PersonalCollectionUnresolved]) -> some View {
        GroupBox("\(countText(values.count, singular: "Dateireferenz", plural: "Dateireferenzen")) zur Prüfung") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Fehlende oder geänderte Lesezeichen und Notizen bleiben mit ihrem Inhaltsbeleg erhalten. Nicht zugeordnete Favoriten und Listeneinträge werden ausgelassen.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(values.enumerated().dropFirst(boundedPage(issuePage, count: values.count) * pageSize).prefix(pageSize)), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(issue.reference.path + (issue.reference.subtune.map { " · Subtune \($0 + 1)" } ?? "")).font(.subheadline).lineLimit(2)
                        Text(resolutionLabel(issue.resolution)).font(.caption).foregroundStyle(.secondary)
                        if case .unverified = issue.resolution {
                            Toggle("Diesem Pfad ohne Inhaltsbeleg vertrauen", isOn: Binding(get: { controller.acceptedPaths.contains(issue.reference) }, set: { enabled in
                                Task { await controller.acceptPath(issue.reference, enabled: enabled) }
                            })).font(.caption).disabled(controller.isBusy || controller.isApplying)
                        }
                    }
                }
                pager(count: values.count, page: pageBinding($issuePage, count: values.count))
            }.padding(8)
        }
    }
    private func countText(_ count: Int, singular: String, plural: String) -> String { "\(count) \(count == 1 ? singular : plural)" }
    private func boundedPage(_ page: Int, count: Int) -> Int { min(max(0, page), max(0, (count - 1) / pageSize)) }
    private func pageBinding(_ page: Binding<Int>, count: Int) -> Binding<Int> {
        Binding(get: { boundedPage(page.wrappedValue, count: count) }, set: { page.wrappedValue = $0 })
    }
    @ViewBuilder private func pager(count: Int, page: Binding<Int>) -> some View {
        if count > pageSize {
            HStack {
                Button("Zurück") { page.wrappedValue = max(0, page.wrappedValue - 1) }.disabled(page.wrappedValue == 0)
                Spacer()
                Text("Seite \(page.wrappedValue + 1) von \((count + pageSize - 1) / pageSize)").font(.caption)
                Spacer()
                Button("Weiter") { page.wrappedValue += 1 }.disabled((page.wrappedValue + 1) * pageSize >= count)
            }
        }
    }
    private func resolutionLabel(_ resolution: PersonalCollectionResolution) -> String {
        switch resolution {
        case .missing: return "Datei fehlt"
        case .changed: return "Der Pfad enthält einen anderen Dateiinhalt"
        case .ambiguous: return "Mehrere Dateien haben denselben Inhalt"
        case .unverified: return "Der Pfad ist vorhanden; der Inhaltsbeleg fehlt"
        case .unavailable: return "Datei nicht lesbar oder kein gültiger SID-Titel"
        case .unavailableSubtune(_, let count): return "Subtune fehlt; die Datei hat \(count) Subtunes"
        case .exact, .moved: return "Datei zugeordnet"
        }
    }
}

private struct CollectionTransferFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
}
