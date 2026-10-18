import SwiftUI
import ViciousSIDPlayerCore

struct WAVExportView: View {
    let presentation: WAVExportPresentation
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = WAVExportController()
    @State private var choiceID = 0
    @State private var mixMode = 0
    @State private var channel = 0
    @State private var filterEnabled = true
    @State private var durationText = ""
    @State private var directory: URL?
    @State private var localError: String?
    @State private var sharedFiles: ExportedFiles?
    @FocusState private var isEditingDuration: Bool

    private var choice: WAVExportChoice? { presentation.choices.first { $0.id == choiceID } }
    private var missingChannel: Bool {
        mixMode == 2 && controller.selectedItems.contains { !$0.activeChips.contains(channel / 3) }
    }
    private var options: WAVExportOptions {
        var value = presentation.options
        value.filterEnabled = filterEnabled
        value.mix = mixMode == 1 ? .current(presentation.analysisMix) : mixMode == 2 ? .channel(channel) : .full
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                if controller.state != .finished {
                    configuration.disabled(controller.isWorking)
                }
                if controller.isWorking {
                    Section {
                        ProgressView(value: controller.progress?.fraction ?? 0)
                        Text(phaseLabel)
                        if let progress = controller.progress {
                            Text(verbatim: "\(progress.completedFiles)/\(progress.totalFiles) · \(progress.fileName)").font(.caption)
                        }
                        Button { controller.cancel() } label: {
                            Text("Abbrechen").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                        }.disabled(controller.state == .cancelling)
                    }
                } else if let result = controller.result {
                    resultView(result)
                } else if controller.state == .ready {
                    preview
                    Section {
                        Text("Ausgewählt: \(controller.selectedIDs.count)")
                        Text(ByteCountFormatter.string(fromByteCount: controller.selectedBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            if let directory { controller.export(directory: directory, options: options) }
                        } label: { Text("Exportieren").frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!controller.canExport || missingChannel || directory == nil)
                    }
                }
                if let error = controller.error ?? localError {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .navigationTitle("WAV exportieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Text("Schließen").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }.disabled(controller.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(controller.isWorking)
        .sheet(item: $sharedFiles) { ShareSheet(urls: $0.urls) }
        .task(id: choiceID) {
            isEditingDuration = false
            durationText = ""
            if let choice { controller.prepare(sources: choice.sources, durations: presentation.durations, directory: directory) }
        }
        .onAppear {
            filterEnabled = presentation.options.filterEnabled
            guard directory == nil else { return }
            do {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WAV-Export", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                directory = folder
            } catch { localError = error.localizedDescription }
        }
        .onDisappear { controller.cancel() }
    }

    private var phaseLabel: String {
        switch controller.state {
        case .preparing: return String(localized: "Exportvorschau wird vorbereitet …")
        case .cancelling: return String(localized: "Export wird abgebrochen …")
        default: return String(localized: "WAV wird gerendert …")
        }
    }

    @ViewBuilder private var configuration: some View {
        Section("Auswahl und Mix") {
            Picker("Auswahl", selection: $choiceID) {
                ForEach(presentation.choices) { Text($0.title).tag($0.id) }
            }
            Picker("Mix", selection: $mixMode) {
                Text("Gesamter Mix").tag(0)
                Text("Aktueller Abhörmix").tag(1)
                Text("Einzelner Kanal").tag(2)
            }
            if mixMode == 2 {
                Picker("Kanal", selection: $channel) {
                    ForEach(0..<9, id: \.self) { channel in
                        Text(verbatim: "SID \(channel / 3 + 1) · V\(channel % 3 + 1)").tag(channel)
                    }
                }
            }
            Button { filterEnabled.toggle() } label: {
                Label(filterEnabled ? String(localized: "Filter an") : String(localized: "Filter aus"), systemImage: "waveform.path")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.bordered).tint(filterEnabled ? .accentColor : .orange)
            Text("Getrennte Kanaldateien lassen sich wegen Rundung und Clipping nicht bitgenau addieren.")
                .font(.caption).foregroundStyle(.secondary)
            if missingChannel { Text("Der gewählte Kanal fehlt in mindestens einer Datei.").foregroundStyle(.red) }
            Text(verbatim: "SID: \(presentation.options.modelOverride.map(String.init) ?? "Auto") · \(presentation.options.clockMode.rawValue.uppercased()) · Fade \(presentation.options.fadeOutSeconds) s")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        Section("Dauer") {
            TextField("Automatische Dauer oder Sekunden / m:ss", text: $durationText)
                .keyboardType(.numbersAndPunctuation).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($isEditingDuration).submitLabel(.done).onSubmit { applyDuration() }
                .frame(minHeight: 44)
            Button { applyDuration() } label: {
                Text("Dauer übernehmen").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            Text("Leer lassen für eigene Endzeit → HVSC → Cache → 6-Minuten-Fallback. Eine manuelle Dauer gilt für alle Einträge.")
                .font(.caption).foregroundStyle(.secondary)
            Button { controller.setSlice(controller.isUsingSlice ? nil : choice?.slice) } label: {
                Label("A/B-Ausschnitt exportieren", systemImage: controller.isUsingSlice ? "checkmark.square.fill" : "square")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(choice?.slice == nil || controller.state != .ready)
            .accessibilityValue(controller.isUsingSlice ? Text("An") : Text("Aus"))
        }
    }

    private func applyDuration() {
        controller.setDuration(durationText)
        isEditingDuration = false
    }

    private var preview: some View {
        Section("Exportvorschau") {
            HStack {
                Button { controller.selectAll(true) } label: {
                    Text("Alle").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                Spacer()
                Button { controller.selectAll(false) } label: {
                    Text("Keine").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
            }.buttonStyle(.borderless)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.items) { item in
                        Button { controller.toggleSelection(item.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: controller.selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.fileName).lineLimit(2).truncationMode(.middle)
                                    Text(durationLabel(item)).font(.caption).foregroundStyle(item.hasValidDuration ? Color.secondary : .red)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(controller.selectedIDs.contains(item.id) ? Text("An") : Text("Aus"))
                    }
                }
            }.frame(height: 240)
        }
    }

    private func durationLabel(_ item: WAVExportItem) -> String {
        let source: String
        if controller.isUsingSlice { source = String(localized: "A/B-Ausschnitt") }
        else if item.usesManualDuration { source = String(localized: "Manuelle Dauer") }
        else {
            switch item.durationSource {
            case .personal: source = String(localized: "Eigene Endzeit")
            case .database: source = "HVSC"
            case .computed: source = String(localized: "Berechnet")
            case .fallback: source = String(localized: "Fallback")
            }
        }
        return item.hasValidDuration ? "\(item.durationDescription) · \(source) · \(item.channels == 2 ? "Stereo" : "Mono")" : String(localized: "Ungültige Dauer")
    }

    @ViewBuilder private func resultView(_ result: WAVExportResult) -> some View {
        Section {
            Text(result.wasCancelled ? String(localized: "Export abgebrochen; fertige Dateien bleiben erhalten.")
                : result.error != nil ? String(localized: "Export beendet; fertige Dateien bleiben erhalten.") : String(localized: "Export abgeschlossen."))
            Text("Fertige Dateien: \(result.files.count)")
            if !result.files.isEmpty {
                Button { sharedFiles = ExportedFiles(urls: result.files) } label: {
                    Label("Dateien teilen …", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
            }
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach(result.files, id: \.self) { Text($0.lastPathComponent).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 240)
        }
    }
}
