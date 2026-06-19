import SwiftUI
import ViciousSIDPlayerCore
import UniformTypeIdentifiers
import os

// Unified Logging (Konsole.app / `log stream`). Subsystem = Bundle-ID, damit
// sich der Lade-Pfad gezielt mitlesen laesst:
//   log stream --predicate 'subsystem == "com.viben.ViciousSIDPlayer"'
let loadLog = Logger(subsystem: "com.viben.ViciousSIDPlayer", category: "load")

struct Track: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let composer: String
    let year: String
    let isUser: Bool
    let fileURL: URL?
}

final class DropURLsContainer: @unchecked Sendable {
    private let lock = NSLock()
    var urls: [URL] = []
    
    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }
}

public struct MainView: View {
    @StateObject private var coordinator = ViciousCoordinator()
    @State private var theme: PlayerTheme = .dark
    @State private var volume: Float = 1.0
    @State private var autoNext = true
    
    // Track lists
    @State private var userTracks: [Track] = []
    @State private var currentTrackIdx: Int = -1
    
    @State private var showFileImporter = false
    @State private var dragOver = false
    @State private var errorMessage: String? = nil
    @State private var isTransitioning = false
    // onAppear kann mehrfach feuern (Fenster erscheint erneut, z.B. beim Datei-Open
    // der laufenden App). Einmalige Initialisierung darf sich dann nicht wiederholen.
    @State private var didInitialize = false
    private let SCRUB_MAX = 360.0
    
    private var allTracks: [Track] {
        return userTracks
    }

    public init() {}

    public var body: some View {
        let isLight = theme == .light
        let bgSecondary = isLight ? Color.macLightSidebar : Color.macDarkSidebar
        let borderCol = isLight ? Color.macLightBorder : Color.macDarkBorder
        let textCol = isLight ? Color.macLightText : Color.macDarkText
        let textSecCol = isLight ? Color.macLightSecondary : Color.macDarkSecondary
        let accentCol = isLight ? Color.macLightAccent : Color.macDarkAccent

        ZStack {
            HStack(spacing: 0) {
                // Sidebar (Playlist & App Logo & Info)
                VStack(alignment: .leading, spacing: 0) {
                    // Premium App Header / Icon
                    HStack(spacing: 12) {
                        ViciousAppIconOverlay()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Vicious SID Player")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(textCol)
                            Text("Native macOS App")
                                .font(.system(size: 11))
                                .foregroundColor(textSecCol)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    Divider()
                        .background(borderCol)

                    HStack {
                        Text("PLAYLIST")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(textSecCol)
                        Spacer()
                        if !userTracks.isEmpty {
                            Button(action: clearPlaylist) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundColor(textSecCol)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Playlist leeren")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 6)
                    
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(0..<allTracks.count, id: \.self) { idx in
                                let track = allTracks[idx]
                                let isActive = idx == currentTrackIdx
                                
                                Button(action: { selectTrack(at: idx) }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: isActive ? "play.circle.fill" : "music.note")
                                            .font(.system(size: 12))
                                        Text(track.name)
                                            .font(.system(size: 13))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        isActive ? accentCol : Color.clear
                                    )
                                    .foregroundColor(
                                        isActive ? .white : textCol
                                    )
                                    .cornerRadius(6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .background(isLight ? Color.macLightSurface : Color.macDarkSurface)
                    
                    Divider()
                        .background(borderCol)
                    
                    // Metadata Panel
                    VStack(alignment: .leading, spacing: 6) {
                        MetaLine(label: "TITLE", value: coordinator.trackName, theme: theme)
                        MetaLine(label: "COMPOSER", value: coordinator.composer, theme: theme)
                        MetaLine(label: "INFO", value: coordinator.info, theme: theme)
                        
                        if let err = errorMessage {
                            Text(err)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.red)
                                .padding(.top, 4)
                        }
                    }
                    .padding(12)
                    .background(bgSecondary)
                }
                .frame(width: 220)
                .background(bgSecondary)
                
                Divider()
                    .background(borderCol)
                
                // Main Panel
                VStack(spacing: 0) {
                    // Controls View
                    HStack(spacing: 12) {
                        Text("TUNE:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(textSecCol)
                        
                        Picker("", selection: Binding(
                            get: { self.currentTrackIdx },
                            set: { val in if val != -1 { self.selectTrack(at: val) } }
                        )) {
                            Text("— Auswählen —").tag(-1)
                            ForEach(0..<allTracks.count, id: \.self) { idx in
                                Text(allTracks[idx].name).tag(idx)
                            }
                        }
                        .pickerStyle(DefaultPickerStyle())
                        .frame(width: 150)
                        
                        Button("DATEI") {
                            showFileImporter = true
                        }
                        .font(.system(size: 12, weight: .medium))
                        
                        Toggle("AUTO NEXT", isOn: $autoNext)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(textCol)
                        
                        Spacer()
                        
                        if coordinator.subtunesCount > 1 {
                            HStack(spacing: 6) {
                                Button("◀") {
                                    let prev = (coordinator.currentSubtune - 1 + coordinator.subtunesCount) % coordinator.subtunesCount
                                    coordinator.setSubtune(sub: prev)
                                }
                                .font(.system(size: 11))
                                .buttonStyle(BorderlessButtonStyle())
                                
                                Text("\(coordinator.currentSubtune + 1)/\(coordinator.subtunesCount)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(textCol)
                                
                                Button("▶") {
                                    let next = (coordinator.currentSubtune + 1) % coordinator.subtunesCount
                                    coordinator.setSubtune(sub: next)
                                }
                                .font(.system(size: 11))
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            .padding(.horizontal, 4)
                        }
                        
                        Button(coordinator.isPlaying ? "■ STOP" : "▶ PLAY") {
                            guard !isTransitioning else { return }
                            isTransitioning = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                self.isTransitioning = false
                            }
                            if coordinator.isPlaying {
                                coordinator.stop()
                            } else {
                                coordinator.play()
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(coordinator.isPlaying ? .red : .green)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(bgSecondary)
                    
                    Divider()
                        .background(borderCol)
                    
                    // Scrubber Bar
                    HStack(spacing: 12) {
                        Text(formatTime(coordinator.elapsedSeconds))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textSecCol)
                            .frame(width: 36)
                        
                        Slider(value: Binding(
                            get: { min(coordinator.elapsedSeconds, Double(SCRUB_MAX)) },
                            set: { val in coordinator.seek(seconds: val) }
                        ), in: 0...Double(SCRUB_MAX))
                        .accentColor(accentCol)
                        
                        Text(formatTime(Double(SCRUB_MAX)))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textSecCol)
                            .frame(width: 36)
                        
                        Text("VOL:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(textSecCol)
                        
                        Slider(value: $volume, in: 0...1.0)
                            .accentColor(accentCol)
                            .frame(width: 70)
                            .onChange(of: volume) { val in
                                coordinator.setVolume(val)
                            }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(bgSecondary)
                    
                    Divider()
                        .background(borderCol)
                    
                    // Canvas visualizer
                    OscilloscopeView(coordinator: coordinator, theme: theme)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(isLight ? Color.macLightSurface : Color.macDarkSurface)
            }
            .frame(minWidth: 800, minHeight: 520)
            
            // Drag overlay
            if dragOver {
                Color.black.opacity(0.8)
                    .edgesIgnoringSafeArea(.all)
                    .overlay(
                        Text("DROP .SID FILE HERE")
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(accentCol)
                            .padding()
                            .border(accentCol, width: 2)
                    )
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                handleDroppedURLs(urls)
            case .failure(let error):
                self.errorMessage = "Importfehler: \(error.localizedDescription)"
            }
        }
        .onDrop(of: ["public.file-url"], isTargeted: $dragOver) { providers in
            loadLog.info("onDrop: \(providers.count, privacy: .public) provider(s)")
            let container = DropURLsContainer()
            let dispatchGroup = DispatchGroup()

            for provider in providers {
                dispatchGroup.enter()
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                    // Decoding-Logik liegt testbar in DropURLDecoder (siehe dort).
                    if let url = DropURLDecoder.url(fromItem: item) {
                        container.append(url)
                    } else {
                        loadLog.error("onDrop: konnte Item nicht zu URL decodieren (error=\(String(describing: error), privacy: .public))")
                    }
                    dispatchGroup.leave()
                }
            }

            dispatchGroup.notify(queue: .main) {
                let urls = container.urls
                loadLog.info("onDrop: \(urls.count, privacy: .public) URL(s) decodiert")
                if !urls.isEmpty {
                    handleDroppedURLs(urls)
                }
            }
            return true
        }
        .onAppear {
            // Einmalige Initialisierung — NICHT bei jedem erneuten onAppear, sonst
            // doppelte Observer und ein erneutes (storendes) Laden des audio/-Ordners.
            if !didInitialize {
                didInitialize = true
                coordinator.setVolume(volume)
                setupMenuNotificationHandlers()
                // Lokalen audio/-Ordner als Start-Playlist laden (Test-/Komfort).
                loadLocalAudioFolder()
            }
            // Dateien, die per Doppelklick/"Oeffnen mit" die App gestartet haben,
            // liegen schon im Puffer des AppDelegate -> jetzt nachziehen (Kaltstart;
            // Warmstart laeuft zusaetzlich ueber die "openSIDFiles"-Notification).
            drainPendingOpenURLs()
        }
        .onChange(of: coordinator.elapsedSeconds) { elapsed in
            if autoNext && elapsed >= Double(SCRUB_MAX) {
                coordinator.stop()
                if allTracks.count > 1 {
                    let next = (currentTrackIdx + 1) % allTracks.count
                    loadTrack(index: next, autoplay: true)
                }
            }
        }
    }

    private func selectTrack(at index: Int) {
        loadTrack(index: index, autoplay: coordinator.isPlaying)
    }

    private func loadTrack(index: Int, autoplay: Bool) {
        guard !isTransitioning else { return }
        isTransitioning = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.isTransitioning = false
            }
        }
        
        guard index >= 0 && index < allTracks.count else { return }
        
        self.errorMessage = nil
        self.currentTrackIdx = index
        let track = allTracks[index]
        
        // Stop current play
        coordinator.stop()
        
        let fileURL: URL
        if let url = track.fileURL {
            fileURL = url
        } else {
            // Locate builtin track
            guard let resolvedURL = findTrackURL(filename: track.id) else {
                self.errorMessage = "Built-in track '\(track.id)' not found."
                return
            }
            fileURL = resolvedURL
        }

        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: fileURL)
            let sidFile = try SidParser.parse(data: data)
            coordinator.setSid(sidFile)
            coordinator.setVolume(volume)
            loadLog.info("loadTrack[\(index, privacy: .public)] geparst: \(fileURL.lastPathComponent, privacy: .public), autoplay=\(autoplay, privacy: .public)")
            if autoplay {
                coordinator.play()
            }
        } catch {
            loadLog.error("loadTrack[\(index, privacy: .public)] Parser-Fehler: \(error.localizedDescription, privacy: .public)")
            self.errorMessage = "Parser-Fehler: \(error.localizedDescription)"
        }
    }

    private func handleDroppedURLs(_ urls: [URL]) {
        loadLog.info("handleDroppedURLs: \(urls.count, privacy: .public) Eingabe-URL(s)")
        self.errorMessage = nil
        var sidFiles: [URL] = []
        let fm = FileManager.default

        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    let keys: [URLResourceKey] = [.isRegularFileKey]
                    if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                        while let fileURL = enumerator.nextObject() as? URL {
                            let fileAccessed = fileURL.startAccessingSecurityScopedResource()
                            if fileURL.pathExtension.lowercased() == "sid" {
                                sidFiles.append(fileURL)
                            }
                            if fileAccessed {
                                fileURL.stopAccessingSecurityScopedResource()
                            }
                        }
                    }
                } else if url.pathExtension.lowercased() == "sid" {
                    sidFiles.append(url)
                }
            }
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard !sidFiles.isEmpty else {
            loadLog.error("handleDroppedURLs: keine .sid Dateien in der Eingabe gefunden")
            self.errorMessage = "Keine .sid Dateien gefunden."
            return
        }
        loadLog.info("handleDroppedURLs: \(sidFiles.count, privacy: .public) .sid Datei(en) gefunden")

        sidFiles.sort(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })

        var firstTrackToPlayIdx = -1
        var tracksToAdd: [Track] = []

        for url in sidFiles {
            let name = url.lastPathComponent.replacingOccurrences(of: ".sid", with: "")
            
            // Duplicate check: against existing tracks AND within current batch
            let isDuplicate = allTracks.contains(where: { $0.name == name || ($0.fileURL != nil && $0.fileURL?.path == url.path) })
                || tracksToAdd.contains(where: { $0.name == name })
            if isDuplicate {
                if firstTrackToPlayIdx == -1 {
                    if let existingIdx = allTracks.firstIndex(where: { $0.name == name }) {
                        firstTrackToPlayIdx = existingIdx
                    }
                }
                continue
            }
            
            let newTrack = Track(
                id: UUID().uuidString,
                name: name,
                composer: "Benutzer geladen",
                year: "N/A",
                isUser: true,
                fileURL: url
            )
            tracksToAdd.append(newTrack)
            if firstTrackToPlayIdx == -1 {
                firstTrackToPlayIdx = allTracks.count + tracksToAdd.count - 1
            }
        }

        if !tracksToAdd.isEmpty {
            self.userTracks.append(contentsOf: tracksToAdd)
        }

        // Instantly select and play
        if firstTrackToPlayIdx != -1 {
            loadTrack(index: firstTrackToPlayIdx, autoplay: true)
        }
    }

    private func findTrackURL(filename: String) -> URL? {
        // 1. Relative execution path (for local testing)
        let fm = FileManager.default
        let relativeURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("audio").appendingPathComponent(filename)
        if fm.fileExists(atPath: relativeURL.path) {
            return relativeURL
        }
        
        // 2. Adjacent audio directory to app bundle
        if let bundlePath = Bundle.main.bundlePath as String? {
            let appDir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
            let nearApp = appDir.appendingPathComponent("audio").appendingPathComponent(filename)
            if fm.fileExists(atPath: nearApp.path) {
                return nearApp
            }
        }
        
        return nil
    }

    private func clearPlaylist() {
        coordinator.stop()
        userTracks.removeAll()
        currentTrackIdx = -1
        errorMessage = nil
    }

    private func loadLocalAudioFolder() {
        let fm = FileManager.default
        // Scan several candidate directories for .sid files
        var candidateDirs: [URL] = []
        candidateDirs.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("audio"))
        if let bundlePath = Bundle.main.bundlePath as String? {
            let appDir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
            candidateDirs.append(appDir.appendingPathComponent("audio"))
        }
        for dir in candidateDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            let sids = contents.filter { $0.pathExtension.lowercased() == "sid" }
                .sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            if sids.isEmpty { continue }
            handleDroppedURLs(sids)
            return // Use first directory that contains SIDs
        }
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && !sec.isNaN else { return "0:00" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func setupMenuNotificationHandlers() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuPlayStop"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                guard !isTransitioning else { return }
                isTransitioning = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.isTransitioning = false
                }
                if coordinator.isPlaying {
                    coordinator.stop()
                } else {
                    coordinator.play()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuNextTrack"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                if allTracks.count > 1 {
                    let next = (currentTrackIdx + 1) % allTracks.count
                    loadTrack(index: next, autoplay: coordinator.isPlaying)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuPrevTrack"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                if allTracks.count > 1 {
                    let prev = (currentTrackIdx - 1 + allTracks.count) % allTracks.count
                    loadTrack(index: prev, autoplay: coordinator.isPlaying)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuToggleTheme"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                theme = theme == .light ? .dark : .light
            }
        }
        // Doppelklick / "Oeffnen mit" bei bereits laufender App (Warmstart).
        NotificationCenter.default.addObserver(forName: NSNotification.Name("openSIDFiles"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                drainPendingOpenURLs()
            }
        }
    }

    // Zieht die vom AppDelegate gepufferten Open-URLs und laedt sie wie ein Drop.
    private func drainPendingOpenURLs() {
        let urls = AppDelegate.pendingURLs
        AppDelegate.pendingURLs = []
        loadLog.info("drainPendingOpenURLs: \(urls.count, privacy: .public) URL(s)")
        if !urls.isEmpty {
            // Ein per Doppelklick/"Oeffnen mit" geoeffnetes File hat Vorrang: den
            // Transition-Debounce zuruecksetzen, sonst weist loadTrack die Auswahl
            // beim Kaltstart ab (loadLocalAudioFolder hat ihn gerade gesetzt) und
            // die Datei landet zwar in der Liste, wird aber nicht ausgewaehlt.
            isTransitioning = false
            handleDroppedURLs(urls)
        }
    }
}

// Helper view for metadata lines
struct MetaLine: View {
    let label: String
    let value: String
    let theme: PlayerTheme

    var body: some View {
        let isLight = theme == .light
        let labelColor = isLight ? Color.macLightSecondary : Color.macDarkSecondary
        let valueColor = isLight ? Color.macLightText : Color.macDarkText

        HStack(alignment: .top, spacing: 4) {
            Text(label + ":")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(labelColor)
                .frame(width: 80, alignment: .leading)
            
            Text(value)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .help(value)
            
            Spacer()
        }
    }
}
