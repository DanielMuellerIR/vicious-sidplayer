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
    @State private var auditPage = 0
    @State private var auditKind: CollectionAuditKind?
    @State private var exportName = "Sammlungsdaten.vicious-collection"
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
        auditPage = 0; auditKind = nil; exportName = "Sammlungsdaten.vicious-collection"
    }
    private var configuredPresentation: some View {
        presentation
            .task { await controller.ready() }
            .onDisappear { controller.cancelAudit() }
            .interactiveDismissDisabled(controller.isApplying)
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): Task { await controller.readImport(from: url) }
                case .failure(let error): if (error as? CocoaError)?.code != .userCancelled { controller.report(error) }
                }
            }
            .fileExporter(isPresented: $showExporter, document: exportFile, contentType: .json,
                          defaultFilename: exportName) { result in
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
                    Text("Exportieren").tag(0); Text("Importieren").tag(1); Text("Prüfen").tag(2)
                }.pickerStyle(.segmented).accessibilityIdentifier("collection-mode")
                    .disabled(controller.isBusy || controller.isApplying || controller.requiresRestart)
                if let error = controller.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
                if let completion = controller.completion { Label(completion, systemImage: "checkmark.circle").font(.subheadline) }
                if exportSaved { Label("Die Exportdatei wurde gesichert.", systemImage: "checkmark.circle").font(.subheadline) }
                if controller.isBusy && !controller.isAuditing {
                    ProgressView(controller.isApplying ? "Daten werden übernommen …" : "Sammlung und Dateiidentitäten werden geprüft …")
                        .font(.subheadline)
                }
                if mode == 2 { auditContent }
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
                if mode == 0 || mode == 1 && controller.importedDocument != nil {
                    areaSelection
                    if mode == 0 { exportActions } else { importPreview }
                }
            }.padding(20)
        }
    }
    private var auditContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dateien prüfen und persönliche Verweise wiederfinden. Musikdateien werden weder verändert noch gelöscht. Die laufende Hörfolge bleibt erhalten.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if controller.isAuditing {
                ProgressView(value: Double(controller.auditProgress), total: Double(max(1, controller.auditTotal)))
                Text("Geprüft: \(controller.auditProgress) von \(controller.auditTotal)")
                Button("Prüfung abbrechen") { controller.cancelAudit() }
                    .auditActionStyle().accessibilityIdentifier("audit-cancel")
            } else {
                Button(controller.auditReport == nil ? NSLocalizedString("Sammlung prüfen", comment: "") : NSLocalizedString("Erneut prüfen", comment: "")) {
                    auditPage = 0; controller.startAudit()
                }.auditActionStyle().disabled(controller.isBusy || controller.requiresRestart).accessibilityIdentifier("audit-start")
            }
            if controller.auditCancelled { Text("Die Prüfung wurde abgebrochen. Persönliche Daten und Musikdateien bleiben unverändert.") }
            if let report = controller.auditReport {
                Text("\(report.fileCount) Dateien geprüft, \(report.validCount) lesbare SID-Titel, \(report.issues.count) Hinweise")
                    .font(.headline).accessibilityIdentifier("audit-summary")
                if !report.hasSTIL { Text("STIL ist nicht geladen. Fehlende STIL-Zuordnungen wurden nicht geprüft.").font(.caption) }
                if !report.hasLengths { Text("Songlengths.md5 ist nicht geladen. Persönliche und berechnete Längen werden berücksichtigt.").font(.caption) }
                if let warning = report.inventoryWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption) }
                Picker("Hinweise", selection: Binding(get: { auditKind }, set: { auditKind = $0; auditPage = 0 })) {
                    Text("Alle Hinweise").tag(nil as CollectionAuditKind?)
                    ForEach(CollectionAuditKind.allCases) { kind in
                        Text(verbatim: "\(kind.title) (\(report.issues.filter { $0.kind == kind }.count))").tag(Optional(kind))
                    }
                }.accessibilityIdentifier("audit-filter")
                auditRows(report)
                Button("Prüfbericht sichern …") {
                    do {
                        exportFile = CollectionTransferFile(bytes: try CollectionAudit.exportReport(report))
                        exportName = "Sammlungsprüfung.vicious-audit"; showExporter = true
                    } catch { controller.report(error) }
                }.auditActionStyle().disabled(controller.isBusy).accessibilityIdentifier("audit-export")
                if !report.repairs.isEmpty {
                    GroupBox("Vorschau der Zuordnungen") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Nur ausdrücklich gewählte, eindeutige Dateiidentitäten werden übernommen. Favoriten und Listen ohne bekannte Prüfsumme können nicht sicher wiedergefunden werden.")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                            Text("Ausgewählte Zuordnungen: \(controller.auditSelection.count)")
                            if !controller.availableAreas.isSuperset(of: [.favorites, .lists, .bookmarks, .notes, .history]) {
                                Text("Persönliche Daten sind schreibgeschützt oder noch nicht geladen. Die Zuordnung kann nicht übernommen werden.")
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Button("Ausgewählte Verweise aktualisieren") { Task { await controller.applyAuditRepairs() } }
                                .auditActionStyle()
                                .disabled(controller.isBusy || controller.requiresRestart || controller.auditSelection.isEmpty
                                    || !controller.availableAreas.isSuperset(of: [.favorites, .lists, .bookmarks, .notes, .history]))
                                .accessibilityIdentifier("audit-apply")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    private func auditRows(_ report: CollectionAuditReport) -> some View {
        let values = report.issues.filter { auditKind == nil || $0.kind == auditKind }
        let offset = min(auditPage * pageSize, max(0, values.count - 1) / pageSize * pageSize)
        let page = Array(values.dropFirst(offset).prefix(pageSize))
        return VStack(alignment: .leading, spacing: 12) {
            if values.isEmpty { Text("Keine Hinweise in dieser Auswahl.").foregroundStyle(.secondary) }
            ForEach(page) { issue in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: issue.kind.title).font(.headline)
                        ForEach(Array(issue.paths.prefix(3).enumerated()), id: \.offset) { _, path in
                            Text(verbatim: path).font(.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if issue.paths.count > 3 { Text("Weitere Pfade im Prüfbericht: \(issue.paths.count - 3)").font(.caption) }
                        if let subtune = issue.reference?.subtune { Text("Subtune \(subtune + 1)").font(.caption) }
                        Text(verbatim: issue.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if issue.canRepair {
                            Toggle("Diese Zuordnung übernehmen", isOn: Binding(get: { controller.auditSelection.contains(issue.id) }, set: {
                                controller.selectAuditRepair(issue.id, enabled: $0)
                            })).disabled(controller.isBusy || controller.requiresRestart)
                                .accessibilityIdentifier("audit-repair-\(issue.id)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Button("Zurück") { auditPage = max(0, auditPage - 1) }.auditActionStyle().disabled(offset == 0)
                Text(verbatim: "\(values.isEmpty ? 0 : offset + 1)–\(offset + page.count) / \(values.count)").font(.caption)
                Button("Weiter") { auditPage += 1 }.auditActionStyle().disabled(offset + page.count >= values.count)
            }
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

private extension View {
    @ViewBuilder func auditActionStyle() -> some View {
        #if os(iOS)
        buttonStyle(AuditActionButtonStyle())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct AuditActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .background(Color.accentColor.opacity(isEnabled ? (configuration.isPressed ? 0.2 : 0.1) : 0.04),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
#endif

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
