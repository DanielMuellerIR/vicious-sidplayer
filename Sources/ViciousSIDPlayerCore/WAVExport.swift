import Foundation

public struct WAVExportSource: Equatable, Sendable {
    public let url: URL
    public let subtune: Int?
    public init(url: URL, subtune: Int? = nil) { self.url = url; self.subtune = subtune }
}

public enum WAVExportError: Error, LocalizedError, Sendable {
    case emptySelection, invalidSubtune, invalidSlice, sourceChanged(String), sourceTooLarge, missingChannel(String), selectionTooLarge, invalidDestination
    public var errorDescription: String? {
        switch self {
        case .emptySelection: return NSLocalizedString("Keine Titel für den Export ausgewählt.", comment: "")
        case .invalidSubtune: return NSLocalizedString("Ein ausgewählter Subtune ist nicht mehr vorhanden.", comment: "")
        case .invalidSlice: return NSLocalizedString("A/B kann nur für einen einzelnen Subtune exportiert werden.", comment: "")
        case .sourceChanged(let name): return String(format: NSLocalizedString("Die Quelldatei %@ wurde seit der Vorschau verändert.", comment: ""), name)
        case .sourceTooLarge: return NSLocalizedString("Die SID-Datei überschreitet das Exportlimit von 1 MiB.", comment: "")
        case .missingChannel(let name): return String(format: NSLocalizedString("Der gewählte SID-Kanal ist in %@ nicht vorhanden.", comment: ""), name)
        case .selectionTooLarge: return NSLocalizedString("Die Auswahl enthält mehr als 100000 Subtunes. Bitte eine kleinere Liste oder einen Bibliotheksfilter wählen.", comment: "")
        case .invalidDestination: return NSLocalizedString("Das WAV-Exportziel ist ungültig oder würde eine SID-Quelle ersetzen.", comment: "")
        }
    }
}

public struct WAVExportItem: Identifiable, Equatable, Sendable {
    public let id: Int
    public let sourceURL: URL
    public let md5: String
    public let subtune: Int
    public let title: String
    public let channels: Int
    public let activeChips: [Int]
    public let resolvedSeconds: Double
    public let durationSource: SongLengthSelection.Source
    public fileprivate(set) var seconds: Double
    public fileprivate(set) var startSeconds: Double
    public fileprivate(set) var fileName: String
    public fileprivate(set) var usesManualDuration = false

    public var hasValidDuration: Bool { (try? WavRenderer.frameCount(seconds: seconds, sampleRate: 44100)) != nil }
    /// Die Vorschau rundet auf Millisekunden; gerendert wird weiterhin die genaue Dauer.
    public var durationDescription: String {
        guard hasValidDuration else { return "" }
        let milliseconds = Int((seconds * 1000).rounded())
        guard milliseconds > 0 else { return "<0:00.001" }
        let whole = milliseconds / 1000
        let base = String(format: "%d:%02d", whole / 60, whole % 60)
        let fraction = milliseconds % 1000
        guard fraction != 0 else { return base }
        var suffix = String(format: ".%03d", fraction)
        while suffix.last == "0" { suffix.removeLast() }
        return base + suffix
    }
    public var estimatedBytes: Int64 {
        guard hasValidDuration else { return 0 }
        return 44 + Int64(seconds * 44100) * Int64(channels * 2)
    }
}

public enum WAVExportMix: Equatable, Sendable {
    case full, current(AnalysisMix), channel(Int)

    func mutedChannels(activeChips: [Int], fileName: String) throws -> [Bool] {
        switch self {
        case .full: return Array(repeating: false, count: 9)
        case .current(let selection): return selection.effectiveMuted(activeChips: activeChips)
        case .channel(let channel):
            guard (0..<9).contains(channel), activeChips.contains(channel / 3) else { throw WAVExportError.missingChannel(fileName) }
            return (0..<9).map { $0 != channel }
        }
    }
}

public struct WAVExportOptions: Equatable, Sendable {
    public var modelOverride: Int?
    public var clockMode: SidClockMode
    public var mix: WAVExportMix
    public var filterEnabled: Bool
    public var fadeOutSeconds: Double
    public init(modelOverride: Int? = nil, clockMode: SidClockMode = .auto,
                mix: WAVExportMix = .full, filterEnabled: Bool = true,
                fadeOutSeconds: Double = 0) {
        self.modelOverride = modelOverride; self.clockMode = clockMode
        self.mix = mix; self.filterEnabled = filterEnabled; self.fadeOutSeconds = fadeOutSeconds
    }
}

public struct WAVExportDurationContext: Sendable {
    public let resolver: SongLengthResolver
    public let database: SonglengthDB?
    public let settings: PlaybackSettingsDocument
    public let clockMode: SidClockMode
    public init(resolver: SongLengthResolver, database: SonglengthDB?, settings: PlaybackSettingsDocument,
                clockMode: SidClockMode) {
        self.resolver = resolver; self.database = database; self.settings = settings; self.clockMode = clockMode
    }
    func resolve(md5: String, subtune: Int) -> SongLengthSelection.Resolution {
        resolver.durationResolution(md5: md5, subtune: subtune, databaseLengths: database?.lengths(forMD5: md5),
            clockMode: clockMode, personalDuration: settings.endTime(md5: md5, subtune: subtune))
    }
}

public enum WAVExportPlanner {
    public static let maximumItems = 100000
    public static func prepare(sources: [WAVExportSource], durations: WAVExportDurationContext,
                               progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> [WAVExportItem] {
        guard !sources.isEmpty else { throw WAVExportError.emptySelection }
        var items: [WAVExportItem] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let parsed = try readSource(at: source.url)
            let sid = parsed.sid, md5 = parsed.md5
            let subs: [Int]
            if let sub = source.subtune {
                guard (0..<sid.subtuneAmount).contains(sub) else { throw WAVExportError.invalidSubtune }
                subs = [sub]
            } else { subs = Array(0..<sid.subtuneAmount) }
            guard items.count + subs.count <= maximumItems else { throw WAVExportError.selectionTooLarge }
            for sub in subs {
                let duration = durations.resolve(md5: md5, subtune: sub)
                let title = source.url.deletingPathExtension().lastPathComponent + " (Subtune \(sub + 1))"
                items.append(WAVExportItem(id: items.count, sourceURL: source.url, md5: md5,
                    subtune: sub, title: title, channels: sid.secondSidAddress != 0 || sid.thirdSidAddress != 0 ? 2 : 1,
                    activeChips: [0] + (sid.secondSidAddress != 0 ? [1] : []) + (sid.thirdSidAddress != 0 ? [2] : []),
                    resolvedSeconds: duration.seconds, durationSource: duration.source,
                    seconds: duration.seconds, startSeconds: 0, fileName: ""))
            }
            progress(index + 1, sources.count)
        }
        let names = WAVExportFileNames.names(for: items.map(\.title))
        for index in items.indices { items[index].fileName = names[index] }
        return items
    }

    public static func applyingDuration(_ seconds: Double?, to items: [WAVExportItem]) throws -> [WAVExportItem] {
        if let seconds { _ = try WavRenderer.frameCount(seconds: seconds, sampleRate: 44100) }
        return items.map { item in
            var changed = item
            changed.seconds = seconds ?? item.resolvedSeconds
            changed.usesManualDuration = seconds != nil
            changed.startSeconds = 0
            return changed
        }
    }

    public static func applyingSlice(_ range: ClosedRange<Double>, to items: [WAVExportItem]) throws -> [WAVExportItem] {
        guard items.count == 1, range.lowerBound.isFinite, range.upperBound.isFinite,
              range.lowerBound >= 0, range.lowerBound <= ViciousProcessor.maximumSeekSeconds,
              range.upperBound - range.lowerBound >= PlaybackLoop.minimumSpan else { throw WAVExportError.invalidSlice }
        var item = items[0]
        item.startSeconds = range.lowerBound; item.seconds = range.upperBound - range.lowerBound
        _ = try WavRenderer.frameCount(seconds: item.seconds, sampleRate: 44100)
        item.usesManualDuration = true
        return [item]
    }

    public static func naming(_ items: [WAVExportItem], in directory: URL) throws -> [WAVExportItem] {
        guard directory.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let existing = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        let names = WAVExportFileNames.names(for: items.map(\.title), existing: existing)
        return items.enumerated().map { index, item in
            var renamed = item; renamed.fileName = names[index]; return renamed
        }
    }

    static func readSource(at url: URL) throws -> (sid: SidFileData, md5: String) {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        // Eine C64-Datei braucht höchstens einen Speicherraum plus Header.
        // Begrenztes Lesen verhindert, dass ein falsch benannter großer Blob
        // den ganzen Batch vor der Abbruchprüfung im Speicher festhält.
        while true {
            try Task.checkCancellation()
            guard let block = try handle.read(upToCount: 65536), !block.isEmpty else { break }
            bytes.append(block)
            guard bytes.count <= 1024 * 1024 else { throw WAVExportError.sourceTooLarge }
        }
        return (try SidParser.parse(data: bytes), SonglengthDB.md5Hex(of: bytes))
    }
}

public struct WAVExportProgress: Equatable, Sendable {
    public let completedFiles: Int
    public let totalFiles: Int
    public let fileName: String
    public let renderedFrames: Int
    public let totalFrames: Int
    public var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        let current = totalFrames > 0 ? Double(renderedFrames) / Double(totalFrames) : 0
        return min(1, (Double(completedFiles) + current) / Double(totalFiles))
    }
}

public struct WAVExportResult: Sendable {
    public let files: [URL]
    public let wasCancelled: Bool
    public let error: String?
}

public enum WAVExportDestination: Sendable {
    case folder(URL)
    /// Ein ausdrücklich im Save-Panel bestätigtes Einzelziel darf ersetzt werden.
    case file(URL)
}

public struct WAVExportChoice: Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let sources: [WAVExportSource]
    public let slice: ClosedRange<Double>?
    public init(id: Int, title: String, sources: [WAVExportSource], slice: ClosedRange<Double>? = nil) {
        self.id = id; self.title = title; self.sources = sources; self.slice = slice
    }
}

public struct WAVExportPresentation: Identifiable, Sendable {
    public let id = UUID()
    public let choices: [WAVExportChoice]
    public let durations: WAVExportDurationContext
    public let options: WAVExportOptions
    public let analysisMix: AnalysisMix
    public init(choices: [WAVExportChoice], durations: WAVExportDurationContext,
                options: WAVExportOptions, analysisMix: AnalysisMix) {
        self.choices = choices; self.durations = durations; self.options = options; self.analysisMix = analysisMix
    }
}

public enum WAVBatchExporter {
    public static func run(items: [WAVExportItem], options: WAVExportOptions, directory: URL,
                           progress: @Sendable (WAVExportProgress) -> Void = { _ in }) -> WAVExportResult {
        run(items: items, options: options, destination: .folder(directory), progress: progress)
    }

    public static func run(items: [WAVExportItem], options: WAVExportOptions, destination: WAVExportDestination,
                           progress: @Sendable (WAVExportProgress) -> Void = { _ in }) -> WAVExportResult {
        var files: [URL] = []
        do {
            guard !items.isEmpty else { throw WAVExportError.emptySelection }
            if case .file(let url) = destination {
                guard items.count == 1, url.isFileURL else { throw WAVExportError.invalidDestination }
            }
            for item in items {
                try Task.checkCancellation()
                let parsed = try WAVExportPlanner.readSource(at: item.sourceURL)
                guard parsed.md5 == item.md5 else {
                    throw WAVExportError.sourceChanged(item.sourceURL.lastPathComponent)
                }
                guard item.fileName == (item.fileName as NSString).lastPathComponent, !item.fileName.isEmpty else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                let sid = parsed.sid
                let muted = try options.mix.mutedChannels(activeChips: item.activeChips, fileName: item.sourceURL.lastPathComponent)
                let completed = files.count
                let output: URL
                let mode: WavRenderer.DestinationMode
                switch destination {
                case .folder(let directory):
                    guard directory.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
                    output = directory.appendingPathComponent(item.fileName); mode = .createNew
                case .file(let url): output = url; mode = .replace
                }
                guard output.pathExtension.lowercased() == "wav",
                      output.standardizedFileURL.resolvingSymlinksInPath() != item.sourceURL.standardizedFileURL.resolvingSymlinksInPath()
                else { throw WAVExportError.invalidDestination }
                try WavRenderer.render(sidFile: sid, subtune: item.subtune, seconds: item.seconds,
                    modelOverride: options.modelOverride, clockMode: options.clockMode, fadeOutSeconds: options.fadeOutSeconds,
                    startSeconds: item.startSeconds, mutedChannels: muted, filterEnabled: options.filterEnabled,
                    destinationMode: mode, progress: { rendered, total in
                        progress(WAVExportProgress(completedFiles: completed, totalFiles: items.count,
                            fileName: output.lastPathComponent, renderedFrames: rendered, totalFrames: total))
                    }, to: output)
                files.append(output)
            }
            return WAVExportResult(files: files, wasCancelled: false, error: nil)
        } catch is CancellationError {
            return WAVExportResult(files: files, wasCancelled: true, error: nil)
        } catch {
            return WAVExportResult(files: files, wasCancelled: false, error: error.localizedDescription)
        }
    }
}
