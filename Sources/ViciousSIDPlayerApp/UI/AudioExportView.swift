import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ViciousSIDPlayerCore

struct AudioExportView: View {
    let presentation: AudioExportPresentation
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = AudioExportController()
    @State private var choiceID = 0
    @State private var mixMode = 0
    @State private var channel = 0
    @State private var filterEnabled = true
    @State private var durationText = ""
    @State private var aacQuality = AACExportQuality.standard
    @State private var directory: URL?

    private var choice: AudioExportChoice? { presentation.choices.first { $0.id == choiceID } }
    private var missingChannel: Bool {
        mixMode == 2 && controller.selectedItems.contains { !$0.activeChips.contains(channel / 3) }
    }
    private var options: AudioExportOptions {
        var value = presentation.options
        value.filterEnabled = filterEnabled
        value.format = controller.format; value.aacQuality = aacQuality
        value.mix = mixMode == 1 ? .current(presentation.analysisMix) : mixMode == 2 ? .channel(channel) : .full
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Audio exportieren").font(.title2.weight(.semibold))
                Spacer()
                Button("Schließen") { dismiss() }.disabled(controller.isWorking)
            }
            if controller.state != .finished {
                configuration
                    .disabled(controller.isWorking)
            }
            if controller.isWorking {
                ProgressView(value: controller.progress?.fraction ?? 0)
                Text(phaseLabel)
                if let progress = controller.progress {
                    Text(verbatim: "\(progress.completedFiles)/\(progress.totalFiles) · \(progress.fileName)")
                        .font(.caption).lineLimit(2)
                }
                Button("Abbrechen") { controller.cancel() }.disabled(controller.state == .cancelling)
                Spacer(minLength: 0)
            } else if let result = controller.result {
                resultView(result)
            } else if controller.state == .ready {
                preview
                HStack {
                    Text("Ausgewählt: \(controller.selectedIDs.count)").foregroundStyle(.secondary)
                    Text(sizeLabel).foregroundStyle(.secondary)
                    Spacer()
                    Button("Exportieren …") { export() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!controller.canExport || missingChannel)
                }
            } else { Spacer(minLength: 0) }
            if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let error = controller.formatError { Text(error).foregroundStyle(.red) }
        }
        .padding(20)
        .frame(minWidth: 660, idealWidth: 720, minHeight: 580, idealHeight: 720)
        .interactiveDismissDisabled(controller.isWorking)
        .task(id: choiceID) {
            durationText = ""
            if let choice { controller.prepare(sources: choice.sources, durations: presentation.durations, directory: directory) }
        }
        .onAppear { filterEnabled = presentation.options.filterEnabled }
        .onDisappear { controller.cancel() }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Format", selection: Binding(get: { controller.format }, set: { controller.setFormat($0) })) {
                    ForEach(AudioExportFormat.allCases) { Text(verbatim: $0.displayName).tag($0) }
                }
                if controller.format == .m4a {
                    Picker("Bitrate", selection: $aacQuality) {
                        ForEach(AACExportQuality.allCases) { Text(verbatim: $0.displayName).tag($0) }
                    }.frame(width: 220)
                }
            }
            Text(controller.format.description).font(.caption).foregroundStyle(.secondary)
            if controller.format != .wav {
                Text("Metadaten: SID-Titel, Autor, SID-Info und Subtune.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Auswahl", selection: $choiceID) {
                ForEach(presentation.choices) { choice in Text(choice.title).tag(choice.id) }
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
            Toggle("SID-Filter", isOn: $filterEnabled)
            Text("Getrennte Kanaldateien lassen sich wegen Rundung und Clipping nicht bitgenau addieren.")
                .font(.caption).foregroundStyle(.secondary)
            if missingChannel { Text("Der gewählte Kanal fehlt in mindestens einer Datei.").foregroundStyle(.red) }
            HStack {
                TextField("Automatische Dauer oder Sekunden / m:ss", text: $durationText)
                    .onSubmit { controller.setDuration(durationText) }
                Button("Dauer übernehmen") { controller.setDuration(durationText) }
            }
            Text("Leer lassen für eigene Endzeit → HVSC → SID-Datei → Cache → 6-Minuten-Fallback. Eine manuelle Dauer gilt für alle Einträge.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("A/B-Ausschnitt exportieren", isOn: Binding(get: { controller.isUsingSlice },
                set: { controller.setSlice($0 ? choice?.slice : nil) }))
                .disabled(choice?.slice == nil || controller.state != .ready)
            HStack {
                Button("Zielordner wählen …") { chooseDirectory() }
                Text(directory?.path ?? String(localized: "Einzelziel über Save-Panel, mehrere Dateien über Zielordner."))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(verbatim: "SID: \(presentation.options.modelOverride.map(String.init) ?? "Auto") · \(presentation.options.clockMode.rawValue.uppercased()) · Fade \(presentation.options.fadeOutSeconds) s")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Exportvorschau").font(.headline)
                Spacer()
                Button("Alle") { controller.selectAll(true) }
                Button("Keine") { controller.selectAll(false) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(controller.items) { item in
                        Button { controller.toggleSelection(item.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: controller.selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.fileName).lineLimit(1).truncationMode(.middle)
                                    Text(durationLabel(item)).font(.caption).foregroundStyle(item.hasValidDuration(for: controller.format) ? Color.secondary : .red)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(item.fileName)
                        .accessibilityValue(controller.selectedIDs.contains(item.id) ? Text("An") : Text("Aus"))
                    }
                }
            }.frame(minHeight: 150)
        }
    }

    private func durationLabel(_ item: AudioExportItem) -> String {
        let source: String
        if controller.isUsingSlice { source = String(localized: "A/B-Ausschnitt") }
        else if item.usesManualDuration { source = String(localized: "Manuelle Dauer") }
        else {
            switch item.durationSource {
            case .personal: source = String(localized: "Eigene Endzeit")
            case .database: source = "HVSC"
            case .embedded: source = String(localized: "SID-Datei")
            case .computed: source = String(localized: "Berechnet")
            case .fallback: source = String(localized: "Fallback")
            }
        }
        return item.hasValidDuration ? "\(item.durationDescription) · \(source) · \(item.channels == 2 ? "Stereo" : "Mono")" : String(localized: "Ungültige Dauer")
    }

    @ViewBuilder private func resultView(_ result: AudioExportResult) -> some View {
        Text(result.wasCancelled ? String(localized: "Export abgebrochen; fertige Dateien bleiben erhalten.")
            : result.error != nil ? String(localized: "Export beendet; fertige Dateien bleiben erhalten.") : String(localized: "Export abgeschlossen.")).font(.headline)
        Text("Fertige Dateien: \(result.files.count)")
        ScrollView {
            LazyVStack(alignment: .leading) {
                ForEach(result.files, id: \.self) { Text($0.lastPathComponent).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        if !result.files.isEmpty {
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting(result.files) }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Auswählen")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directory = url
        controller.renameForDirectory(url)
    }
    private func export() {
        if let directory { controller.export(directory: directory, options: options); return }
        if controller.selectedIDs.count == 1, let item = controller.selectedItems.first {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: controller.format.rawValue) ?? .audio]
            panel.nameFieldStringValue = item.fileName
            guard panel.runModal() == .OK, let url = panel.url else { return }
            controller.export(destination: .file(url), options: options)
        } else { chooseDirectory() }
    }

    private var sizeLabel: String {
        guard let bytes = controller.estimatedBytes(quality: aacQuality) else { return String(localized: "FLAC-Größe hängt vom Inhalt ab.") }
        let value = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return controller.format == .m4a ? String(format: String(localized: "Ca. %@"), value) : value
    }
    private var phaseLabel: String {
        if controller.state == .preparing { return String(localized: "Exportvorschau wird vorbereitet …") }
        if controller.state == .cancelling { return String(localized: "Export wird abgebrochen …") }
        switch controller.progress?.phase {
        case .encoding: return String(localized: "Audio wird codiert …")
        case .metadata: return String(localized: "Metadaten werden geschrieben …")
        default: return String(localized: "Audio wird gerendert …")
        }
    }
}
