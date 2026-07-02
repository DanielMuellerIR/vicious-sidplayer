import SwiftUI
import ViciousSIDPlayerCore
import UniformTypeIdentifiers
import os
import MediaPlayer
#if canImport(AppKit)
import AppKit
#endif

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
    // Zufallswiedergabe. @AppStorage sichert den Zustand in UserDefaults, bleibt
    // also ueber App-Neustarts erhalten.
    @AppStorage("shuffleEnabled") private var shuffle = false
    // MPRemoteCommandCenter nur einmal verdrahten (onAppear kann mehrfach feuern).
    @State private var mediaCommandsConfigured = false
    
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
                        // codereview-ok: MetaLine wird genutzt; kein toter Code (2026-07-01)
                        MetaLine(label: "TITLE", value: coordinator.trackName, theme: theme)
                        MetaLine(label: "COMPOSER", value: coordinator.composer, theme: theme)
                        MetaLine(label: "INFO", value: coordinator.info, theme: theme)

                        // codereview-ok: stilistisch, kein Bug (2026-07-01)
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
                    HStack(spacing: 10) {
                        Text("TUNE:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(textSecCol)
                        
                        // codereview-ok: loadTrack setzt currentTrackIdx auf den gepickten Index (2026-07-01)
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
                        .foregroundColor(textCol)
                        .help("SID-Datei(en) öffnen")

                        Toggle("AUTO NEXT", isOn: $autoNext)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(textCol)
                            .fixedSize()   // "AUTO NEXT" einzeilig, kein haesslicher Umbruch

                        // SID-Chip-Modell: Auto folgt der Datei-Praeferenz, 6581/8580
                        // erzwingen das jeweilige Modell (viele Tunes klingen nur auf
                        // dem richtigen Chip korrekt). Wirkt live auf den laufenden Song.
                        Picker("", selection: Binding(
                            get: { coordinator.modelOverride ?? 0 },   // 0 = Auto
                            set: { coordinator.setModelOverride($0 == 0 ? nil : $0) }
                        )) {
                            Text("SID: Auto").tag(0)
                            Text("6581").tag(6581)
                            Text("8580").tag(8580)
                        }
                        .pickerStyle(DefaultPickerStyle())
                        .frame(width: 110)
                        .help("SID-Chip-Modell — Auto folgt der Datei")

                        Spacer()
                        
                        // Subtune-Umschaltung: eine SID-Datei kann mehrere Songs
                        // ("Subtunes") enthalten. "2/5" = Subtune 2 von 5. Die Pfeile
                        // schalten zum vorigen/naechsten Subtune (Akzentfarbe = klickbar).
                        if coordinator.subtunesCount > 1 {
                            HStack(spacing: 8) {
                                Button(action: {
                                    let prev = (coordinator.currentSubtune - 1 + coordinator.subtunesCount) % coordinator.subtunesCount
                                    coordinator.setSubtune(sub: prev)
                                }) {
                                    Image(systemName: "chevron.left.circle.fill")
                                        .font(.system(size: 16))
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .foregroundColor(accentCol)
                                .help("Vorheriger Subtune")

                                Text("\(coordinator.currentSubtune + 1)/\(coordinator.subtunesCount)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(textCol)
                                    .fixedSize()   // Zahl nie wegkuerzen, auch bei engem Balken
                                    .help("Subtune — ein Song innerhalb dieser SID-Datei")

                                Button(action: {
                                    let next = (coordinator.currentSubtune + 1) % coordinator.subtunesCount
                                    coordinator.setSubtune(sub: next)
                                }) {
                                    Image(systemName: "chevron.right.circle.fill")
                                        .font(.system(size: 16))
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .foregroundColor(accentCol)
                                .help("Nächster Subtune")
                            }
                            .padding(.horizontal, 4)
                        }

                        // Transport: Shuffle · 15 s zurueck · Play/Pause · 30 s vor · Stop.
                        HStack(spacing: 12) {
                            Button(action: { shuffle.toggle() }) {
                                Image(systemName: "shuffle").font(.system(size: 15))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(shuffle ? accentCol : textSecCol)
                            .help(shuffle ? "Zufallswiedergabe: an" : "Zufallswiedergabe: aus")

                            Button(action: { skip(by: -15) }) {
                                Image(systemName: "gobackward.15").font(.system(size: 16))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(textCol)
                            .help("15 Sekunden zurück")

                            Button(action: { togglePlayPause() }) {
                                Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(coordinator.isPlaying ? accentCol : .green)
                            .help(coordinator.isPlaying ? "Pause" : "Wiedergabe")

                            Button(action: { skip(by: 30) }) {
                                Image(systemName: "goforward.30").font(.system(size: 16))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(textCol)
                            .help("30 Sekunden vor")

                            Button(action: { coordinator.stop() }) {
                                Image(systemName: "stop.fill").font(.system(size: 14))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(.red)
                            .help("Stopp (zurück an den Anfang)")
                        }
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
            .frame(minWidth: 980, minHeight: 540)
            
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

            // Unsichtbarer Button, damit die Leertaste global Play/Pause umschaltet.
            // (Kein Menue-Shortcut, weil die Leertaste dort untypisch waere.)
            Button("") { togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(PlainButtonStyle())
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
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
                setupMediaRemoteCommands()
                // Start-Playlist aus ~/Music/Vicious SID Player/ laden.
                loadLocalAudioFolder()
            }
            // Dateien, die per Doppelklick/"Oeffnen mit" die App gestartet haben,
            // liegen schon im Puffer des AppDelegate -> jetzt nachziehen (Kaltstart;
            // Warmstart laeuft zusaetzlich ueber die "openSIDFiles"-Notification).
            drainPendingOpenURLs()
            applyAppearance()
        }
        .onChange(of: theme) { _ in applyAppearance() }
        // "Now Playing"-Infos bei jedem relevanten Zustandswechsel aktualisieren
        // (nicht bei jedem elapsed-Tick — Titel/Status/Position genuegen dem System).
        .onChange(of: coordinator.isPlaying) { _ in updateNowPlayingInfo() }
        .onChange(of: coordinator.isPaused) { _ in updateNowPlayingInfo() }
        .onChange(of: coordinator.trackName) { _ in updateNowPlayingInfo() }
        .onChange(of: coordinator.elapsedSeconds) { elapsed in
            if autoNext && elapsed >= Double(SCRUB_MAX) {
                // Erst alle weiteren Subtunes DIESER SID-Datei durchspielen, dann
                // zum naechsten Playlist-Eintrag. setSubtune setzt die Position auf 0
                // zurueck und laeuft (da isPlaying) direkt weiter.
                if coordinator.currentSubtune + 1 < coordinator.subtunesCount {
                    coordinator.setSubtune(sub: coordinator.currentSubtune + 1)
                } else if allTracks.count > 1 {
                    coordinator.stop()
                    loadTrack(index: advanceTrackIndex(), autoplay: true)
                } else {
                    coordinator.stop()
                }
            }
        }
    }

    private func selectTrack(at index: Int) {
        loadTrack(index: index, autoplay: coordinator.isPlaying)
    }

    // Erzwingt die AppKit-Fenster-/Control-Darstellung passend zum App-Theme.
    // Ohne das rendern System-Controls (Picker, Toggle) im Hell-Modus dunklen Text
    // auf dem dunklen App-Hintergrund — "schwarz auf schwarz", unlesbar. So folgt
    // die gesamte Fensterdarstellung (auch die Titelleiste) dem gewaehlten Theme.
    private func applyAppearance() {
        #if canImport(AppKit)
        NSApplication.shared.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        #endif
    }

    // Play/Pause umschalten: pause() haelt an und behaelt die Position, play() setzt
    // dort fort (bzw. baut beim ersten Mal die Wiedergabe auf).
    private func togglePlayPause() {
        if coordinator.isPlaying {
            coordinator.pause()
        } else {
            coordinator.play()
        }
    }

    // Relatives Vor-/Zurueckspringen, auf [0, SCRUB_MAX] begrenzt. Funktioniert auch
    // im pausierten/gestoppten Zustand (coordinator.seek puffert die Position dann).
    private func skip(by delta: Double) {
        let target = min(Double(SCRUB_MAX), max(0.0, coordinator.elapsedSeconds + delta))
        coordinator.seek(seconds: target)
    }

    // Index des naechsten Tracks: bei aktiver Zufallswiedergabe ein zufaelliger
    // (nicht der aktuelle), sonst der naechste in Reihenfolge (mit Umlauf).
    private func advanceTrackIndex() -> Int {
        let count = allTracks.count
        guard count > 1 else { return currentTrackIdx }
        if shuffle {
            var idx = Int.random(in: 0..<count)
            if idx == currentTrackIdx { idx = (idx + 1) % count }
            return idx
        }
        return (currentTrackIdx + 1) % count
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
        
        // User-Tracks tragen immer ihre Datei-URL. Built-in-Tracks gibt es in
        // diesem Player bewusst nicht (es werden keine SIDs gebuendelt), daher
        // ist der fileURL == nil-Fall nur eine defensive Absicherung.
        guard let fileURL = track.fileURL else {
            self.errorMessage = "Track ohne Datei-URL: \(track.name)"
            return
        }

        // codereview-ok: defer haelt Scope ueber den Read; ausserdem App nicht sandboxed (2026-07-01)
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

    private func handleDroppedURLs(_ urls: [URL], isStartupLoad: Bool = false) {
        loadLog.info("handleDroppedURLs: \(urls.count, privacy: .public) Eingabe-URL(s)")
        self.errorMessage = nil
        var sidFiles: [URL] = []
        let fm = FileManager.default

        for url in urls {
            // codereview-ok: App nicht sandboxed -> security-scoped calls sind No-Op; latent falls je Sandbox aktiviert wird (2026-07-01)
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
            // Endung robust entfernen: deletingPathExtension strippt nur die echte
            // Datei-Endung (egal ob .sid/.SID/.Sid), waehrend das frueher genutzte
            // replacingOccurrences(of: ".sid") case-sensitiv war und Grossschreibung
            // stehen liess (verfaelschte Duplikat-Erkennung via name==name und Anzeige).
            let name = url.deletingPathExtension().lastPathComponent
            
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

        // Sofort einen Track auswaehlen und abspielen. Beim Start mit aktiver
        // Zufallswiedergabe einen zufaelligen statt des ersten (alphabetisch)
        // Tracks — so beginnt jeder App-Start mit einem anderen Song.
        if firstTrackToPlayIdx != -1 {
            let playIdx: Int
            if isStartupLoad && shuffle && allTracks.count > 1 {
                playIdx = Int.random(in: 0..<allTracks.count)
            } else {
                playIdx = firstTrackToPlayIdx
            }
            loadTrack(index: playIdx, autoplay: true)
        }
    }

    private func clearPlaylist() {
        coordinator.stop()
        userTracks.removeAll()
        currentTrackIdx = -1
        errorMessage = nil
    }

    private func loadLocalAudioFolder() {
        let fm = FileManager.default
        // Start-Playlist ausschliesslich aus dem persoenlichen Musik-Ordner laden:
        // ~/Music/Vicious SID Player/ (rekursiv, inkl. Unterordner). Liegt AUSSERHALB
        // des Repos, wird nie mit ausgeliefert/nach GitHub gepusht. Hier eigene
        // .sid-Dateien ablegen — sie werden beim Start automatisch geladen.
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Music/Vicious SID Player")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return }
        let sids = collectSIDs(in: dir, fm: fm)
        guard !sids.isEmpty else { return }
        handleDroppedURLs(sids, isStartupLoad: true)
    }

    // Sammelt alle .sid-Dateien in dir REKURSIV (auch aus Unterordnern), natuerlich
    // sortiert nach Pfad. So kann der Nutzer seine Sammlung beliebig verschachteln.
    private func collectSIDs(in dir: URL, fm: FileManager) -> [URL] {
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "sid" {
            out.append(url)
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite && !sec.isNaN else { return "0:00" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func setupMenuNotificationHandlers() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuPlayStop"), object: nil, queue: .main) { _ in
            // codereview-ok: Task{@MainActor} noetig fuer Aktor-Isolation; Entfernen bricht Compile (2026-07-01)
            Task { @MainActor in
                togglePlayPause()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuNextTrack"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                if allTracks.count > 1 {
                    loadTrack(index: advanceTrackIndex(), autoplay: coordinator.isPlaying)
                }
            }
        }
        // Media-Tasten: expliziter Play/Pause/Stop (zusaetzlich zum Toggle) — Play
        // und Pause posten getrennt, weil das System sie getrennt schickt.
        NotificationCenter.default.addObserver(forName: NSNotification.Name("mediaPlay"), object: nil, queue: .main) { _ in
            Task { @MainActor in coordinator.play() }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("mediaPause"), object: nil, queue: .main) { _ in
            Task { @MainActor in coordinator.pause() }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuStop"), object: nil, queue: .main) { _ in
            Task { @MainActor in coordinator.stop() }
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

    // Media-Tasten (F7/F8/F9 bzw. Touch Bar / AirPods): Registriert die App im
    // System als "Now Playing"-App. Die Kommandos posten dieselben Notifications
    // wie die Menuepunkte, sodass beide Quellen einheitlich verarbeitet werden.
    private func setupMediaRemoteCommands() {
        guard !mediaCommandsConfigured else { return }
        mediaCommandsConfigured = true

        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("menuPlayStop"), object: nil)
            return .success
        }
        center.playCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("mediaPlay"), object: nil)
            return .success
        }
        center.pauseCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("mediaPause"), object: nil)
            return .success
        }
        center.stopCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("menuStop"), object: nil)
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("menuNextTrack"), object: nil)
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: NSNotification.Name("menuPrevTrack"), object: nil)
            return .success
        }
    }

    // Haelt die "Now Playing"-Infos des Systems aktuell (Titel, Komponist, Dauer,
    // Position, laeuft/pausiert) — Voraussetzung dafuer, dass die Media-Tasten an
    // diese App geroutet werden. Ohne echte Songlength-DB dient SCRUB_MAX als Dauer.
    private func updateNowPlayingInfo() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard currentTrackIdx >= 0 else {
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
            return
        }
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: coordinator.trackName,
            MPMediaItemPropertyArtist: coordinator.composer,
            MPMediaItemPropertyPlaybackDuration: Double(SCRUB_MAX),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: coordinator.elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: coordinator.isPlaying ? 1.0 : 0.0
        ]
        infoCenter.playbackState = coordinator.isPlaying ? .playing : (coordinator.isPaused ? .paused : .stopped)
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
