import SwiftUI
import Combine
import ViciousSIDPlayerCore

// Das Gehirn der iPhone-App.
//
// Auf dem Mac steckt diese Logik in `MainView.swift` — dort ist sie mit rund 30
// `@State`-Feldern in die View hineingewachsen. Auf iOS liegt sie bewusst in
// einem eigenen `ObservableObject`, weil hier drei getrennte Tabs (Bibliothek,
// Now Playing, Einstellungen) und eine Mini-Player-Leiste auf DENSELBEN Zustand
// schauen muessen. Mit `@State` in einer View ginge das nicht.
//
// Zustaendigkeiten:
//   - Bibliothek: Titel-Liste, Ordnerbaum, Suche, Favoriten
//   - Transport: Play/Pause/Weiter/Zurueck, Subtunes, Position, Shuffle
//   - Songlaengen: HVSC-Datenbank -> berechneter Cache -> Fallback
//   - Import und Zuruecksetzen
//   - Sitzungswiederherstellung
//   - Szenenphase (aktiv / Hintergrund)
//
// Was hier NICHT liegt und bewusst woanders steht:
//   - `AudioSessionController` — Kategorie, Unterbrechungen, Routenwechsel
//   - `NowPlayingController`   — Sperrbildschirm und Fernbedienungsbefehle
//   Beide haengen an Systembenachrichtigungen und werden von hier nur
//   angestossen.
@MainActor
final class AppModel: ObservableObject {

    // MARK: - Wiedergabe-Kern

    /// Der plattformneutrale Koordinator aus dem Core (AVAudioEngine + Emulator).
    /// Views beobachten ihn direkt fuer Titel, Laufzeit und Oszilloskopdaten.
    let coordinator = ViciousCoordinator()
    let history: ListeningHistoryController
    let historyBackgroundSaver = ListeningHistoryBackgroundSaver()
    let listening: ListeningLibraryController
    var listeningPlaylist = Playlist()
    var listeningSubscriptions = Set<AnyCancellable>()
    var pendingListeningRestore = false
    static let listeningCollectionID = "ios-documents"


    // MARK: - Bibliothek

    /// Alle Titel der Bibliothek, stabil sortiert nach relativem Pfad.
    @Published private(set) var tracks: [LibraryTrack] = []

    /// Ordnerbaum ueber `tracks` — die Bibliotheksansicht klappt ihn auf und zu.
    /// HVSC-Sammlungen sind tief verschachtelt; eine flache Liste waere unbenutzbar.
    @Published private(set) var folderTree: MusicLibraryFolder = AppModel.emptyFolderTree

    /// Relativer Pfad des gerade geladenen Titels, `nil` = keiner.
    @Published private(set) var currentTrackID: String?

    /// Live-Suche ueber Titel- und Ordnernamen.
    @Published var searchText: String = ""

    /// Nur Favoriten anzeigen.
    @Published var favoritesOnly: Bool = false
    let metadataIndex = LibraryMetadataController()
    let savedSearches: SavedLibrarySearchController
    let playbackOptions: PlaybackOptionsController
    let collectionFavorites: PersonalCollectionFavoritesStore
    var collectionImportMayResume = false
    var pendingCollectionAudioReset = false
    lazy var collectionTransfer: PersonalCollectionController = {
        let controller = PersonalCollectionController(listening: listening, history: history, playback: playbackOptions,
            favorites: collectionFavorites, supportURL: listeningFileURL?.deletingLastPathComponent(), context: { [weak self] in
                guard let self, let library = self.services.library, self.importTask == nil,
                      self.services.resetTask == nil else { throw PersonalCollectionImportError.unavailable }
                return .init(libraryID: Self.listeningCollectionID, name: String(localized: "iPhone-Sammlung"), library: library)
            }, pause: { [weak self] in
                guard let self else { return false }
                let playing = self.coordinator.isPlaying
                self.collectionImportMayResume = playing
                self.observeHistory(force: true, playing: false)
                if playing { self.coordinator.pause() }
                self.updateNowPlaying(force: true)
                return playing
            }, resume: { [weak self] in
                guard let self, self.collectionImportMayResume, !self.pendingCollectionAudioReset,
                      self.coordinator.isPaused else { return }
                self.collectionImportMayResume = false
                self.applyPlaybackOptions(); self.coordinator.play(); self.observeHistory(force: true)
                self.syncPlaybackLoop(); self.updateNowPlaying(force: true)
            }, didApply: { [weak self] in self?.didImportCollection() }, auditMetadata: { [weak self] in
                guard let self else { return .init() }
                return .init(stil: self.stilDB, lengths: self.songlengthDB, cache: self.lengthCache,
                    clockMode: self.coordinator.clockMode, knownContents: self.metadataIndex.records.compactMapValues { $0.metadata?.md5 })
            })
        controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &listeningSubscriptions)
        controller.$isApplying.sink { [weak self] applying in
            guard !applying else { return }
            Task { @MainActor [weak self] in
                guard let self, self.pendingCollectionAudioReset else { return }
                self.pendingCollectionAudioReset = false
                self.rebuildAfterMediaServicesReset()
            }
        }.store(in: &listeningSubscriptions)
        return controller
    }()
    private let listeningFileURL: URL?

    /// Favoriten, als Menge relativer Pfade. Bewusst relativ und nicht absolut:
    /// der App-Container bekommt bei jeder Neuinstallation eine neue UUID, mit
    /// absoluten Pfaden waeren alle Favoriten danach verloren.
    @Published private(set) var favorites: Set<String> = []

    /// `tracks`, gefiltert nach `searchText` und `favoritesOnly`. Das ist die
    /// Liste, die die UI zeigt. Eine Hoerfolge wird daraus ausdruecklich gestartet;
    /// spaetere Filteraenderungen veraendern sie nicht.
    /// Die Suchregel selbst steht im Core (`PlaylistSearch`), weil die Mac-App
    /// dieselbe braucht — vorher stand sie hier und dort in je eigener Fassung.
    var visibleTracks: [LibraryTrack] {
        LibrarySearchSelection.indices(in: listeningPlaylist, query: LibrarySearchQuery(searchText), records: metadataIndex.records,
            favoritesOnly: favoritesOnly, favorites: PlaylistFavorites(ids: favorites), duration: knownLibraryDuration, heard: { history.hasHeard(md5: $0.md5) }).map { tracks[$0] }
    }

    func knownLibraryDuration(_ metadata: LibraryMetadata) -> Double? {
        metadata.firstSubtuneDuration(database: songlengthDB, cache: lengthCache, clockMode: coordinator.clockMode,
            personalDuration: playbackOptions.document.endTime(md5: metadata.md5, subtune: 0))
    }

    /// Der gerade geladene Titel als Datensatz, `nil` wenn keiner geladen ist.
    var currentTrack: LibraryTrack? {
        guard let id = currentTrackID else { return nil }
        return tracks.first { $0.id == id }
    }

    // MARK: - Transport

    /// Zufallswiedergabe. Ueberlebt den App-Neustart.
    @Published var shuffle: Bool = false { didSet { defaults.set(shuffle, forKey: Keys.shuffle); listening.setShuffle(shuffle) } }

    /// Am Songende automatisch zum naechsten Titel.
    @Published var autoNext: Bool = true { didSet { defaults.set(autoNext, forKey: Keys.autoNext); applyPlaybackOptions() } }

    /// Master-Lautstaerke 0…1.
    @Published var volume: Float = 1.0 {
        didSet {
            coordinator.setVolume(volume)
            defaults.set(volume, forKey: Keys.volume)
        }
    }

    /// Effektive Dauer des laufenden Subtunes. Reihenfolge wie auf dem Mac:
    /// Persönliche Endzeit, HVSC, eingebettete Dateilänge, Cache und Fallback.
    /// Steuert Scrubber, Auto-Next, Sperrbildschirm und WAV-Export.
    ///
    /// Die Leiter selbst steht im Core (`SongLengthSelection`) — genau deshalb
    /// kann sie hier nicht mehr von der Mac-Fassung abweichen.
    var currentDuration: Double {
        return SongLengthSelection.duration(databaseLengths: currentTrackLengths,
                                            subtune: coordinator.currentSubtune,
                                            computed: computedLength,
                                            fallback: Self.fallbackDurationSeconds, personalDuration: personalDuration, embeddedLengths: currentEmbeddedLengths)
    }

    /// Fallback, wenn weder HVSC-Eintrag noch berechnete Laenge vorliegen —
    /// identisch zur Mac-App, weil beide denselben Core-Wert verwenden.
    static let fallbackDurationSeconds = SongLengthSelection.fallbackSeconds

    // MARK: - Import

    /// Fortschritt eines laufenden Imports, `nil` = gerade kein Import.
    @Published private(set) var importProgress: ImportProgress?

    /// Abschlussbericht des letzten Imports (fuer den Ergebnis-Hinweis).
    @Published var lastImportReport: ImportReport?

    // MARK: - Einstellungen

    @Published var themeMode: ThemeMode = .auto {
        didSet { defaults.set(themeMode.rawValue, forKey: ThemeMode.userDefaultsKey) }
    }

    /// Sitzung beim naechsten Start wiederherstellen (Titel, Subtune, Position).
    @Published var sessionRestoreEnabled: Bool = true {
        didSet { defaults.set(sessionRestoreEnabled, forKey: Keys.sessionRestore) }
    }

    /// Kurzer Status der Songlaengen-Datenbank fuer die Einstellungen,
    /// z.B. „12345 Einträge" oder „keine Datenbank importiert".
    @Published private(set) var songlengthsStatus: String = ""

    /// Dasselbe fuer die STIL-Datei der HVSC (Anmerkungen zu Titel und Subtune).
    @Published private(set) var stilStatus: String = ""

    // MARK: - Sonstiger Zustand

    /// Zuletzt aufgetretener Fehler; die UI zeigt ihn als Hinweis und setzt ihn
    /// danach auf `nil` zurueck.
    @Published var errorMessage: String?

    /// Ist die App im Vordergrund? Alle zeichnenden Timer haengen hieran.
    /// Im Hintergrund laeuft Audio weiter, die Visualisierung steht still —
    /// das ist der groesste Batteriehebel der App.
    @Published private(set) var isSceneActive: Bool = true
    private var isPlaybackViewVisible = false

    // MARK: - Interne Bausteine

    /// Wohin Einstellungen und Sitzungszustand geschrieben werden.
    ///
    /// Injizierbar, damit Tests eine EIGENE Suite bekommen. Vorher schrieben sie
    /// in `UserDefaults.standard` der Test-App und liessen ihre Werte dort
    /// liegen: Die Tests hingen damit voneinander und von ihrer Reihenfolge ab
    /// und veraenderten den Zustand im Simulator ueber den einzelnen Test hinaus
    /// (Review-Fund 2026-08-17).
    let defaults: UserDefaults
    let fileManager = FileManager.default

    /// Langlebige Bausteine, die die Extensions in `Player/` brauchen —
    /// Bibliothek, Audio-Session, Now Playing, Hintergrund-Lauf. Sie stehen
    /// hier und nicht in den Extensions, weil Swift-Extensions keine
    /// gespeicherten Eigenschaften hinzufuegen duerfen. `lazy`, damit die
    /// Bibliothek erst beim ersten Zugriff geoeffnet wird und nicht schon im
    /// Initializer. Siehe `PlayerServices.swift`.
    lazy var services = PlayerServices()

    /// Wurzel der Bibliothek im App-Container (`Documents/`).
    private(set) lazy var libraryRoot: URL? = MusicLibraryLocation.root(fm: fileManager)

    /// HVSC-Songlaengen-Datenbank, sofern der Nutzer eine importiert hat.
    var songlengthDB: SonglengthDB?
    /// HVSC-STIL, sofern der Nutzer eine importiert hat. Siehe `AppModel+STIL`.
    var stilDB: STILDatabase?
    /// Laengen des aktuellen Titels je Subtune (aus der HVSC-Datenbank).
    var currentEmbeddedLengths: [Double]?
    @Published var currentTrackLengths: [Double]? { didSet { applyPlaybackOptions() } }
    /// Im Hintergrund berechnete Laenge des aktuellen Subtunes.
    @Published var computedLength: Double? { didSet { applyPlaybackOptions() } }
    /// MD5 der aktuellen Datei — Schluessel fuer beide Laengenquellen.
    var currentMD5: String?
    let lengthCache = SongLengthCache.defaultCache()

    /// Reihenfolge der Laengenquellen und Buchfuehrung ueber die laufende
    /// Berechnung — dieselbe Regel wie in der Mac-App, weil beide denselben
    /// Core-Typ benutzen. `lazy`, weil sie auf `lengthCache` aufsetzt: das
    /// Zuruecksetzen der Bibliothek leert genau diese Cache-Instanz.
    lazy var lengthResolver = SongLengthResolver(cache: lengthCache)

    /// Der laufende Hintergrund-Task der Laengenberechnung. Nur der Task liegt
    /// noch hier; ob sein Ergebnis noch zum aktuellen Titel passt, entscheidet
    /// der Resolver.
    var lengthEstimateTask: Task<Void, Never>?
    /// Wem gehoert `lengthEstimateTask` gerade? Ohne diese Angabe leerte der
    /// spaete Abschluss von Schaetzung A den Griff bedingungslos — und traf
    /// damit die inzwischen eingetragene Schaetzung B, die danach nicht mehr
    /// abbrechbar war und nach `lengthCache.clear()` alte Werte
    /// zurueckschreiben konnte (Review-Fund 2026-08-17).
    var lengthEstimateOwner: SongLengthEstimateTicket?
    var importTask: Task<Void, Never>?

    /// UserDefaults-Schluessel an einer Stelle, damit Schreiber und Leser sich
    /// nicht auseinanderentwickeln.
    /// Leerer Ordnerbaum — der Startwert und der Zustand nach dem
    /// Zuruecksetzen der Bibliothek.
    static let emptyFolderTree = MusicLibrary.folderTree(for: [])

    enum Keys {
        static let shuffle = "shuffleEnabled"
        static let autoNext = "autoNext"
        static let volume = "volume"
        static let favorites = "favorites"
        static let sessionRestore = "sessionRestoreEnabled"
        static let lastTrackID = "lastTrackID"
        static let lastSubtune = "lastSubtune"
        static let lastPosition = "lastPosition"
        static let lastListeningEntryID = "lastListeningEntryID"
    }

    init(defaults: UserDefaults = .standard, listeningFileURL: URL? = ListeningLibraryStore.defaultURL()) {
        self.defaults = defaults
        self.listeningFileURL = listeningFileURL
        let favorites = PersonalCollectionFavoritesStore(defaults: defaults, key: Keys.favorites)
        self.collectionFavorites = favorites
        let startup = PersonalCollectionStartup(supportURL: listeningFileURL?.deletingLastPathComponent(), favorites: favorites)
        self.listening = ListeningLibraryController(fileURL: listeningFileURL, startup: startup)
        self.history = ListeningHistoryController(fileURL: listeningFileURL?.deletingLastPathComponent().appendingPathComponent(ListeningHistoryStore.fileName), startup: startup)
        self.savedSearches = SavedLibrarySearchController(fileURL: listeningFileURL?.deletingLastPathComponent().appendingPathComponent("saved-searches.json"))
        self.playbackOptions = PlaybackOptionsController(fileURL: listeningFileURL?.deletingLastPathComponent().appendingPathComponent(PlaybackSettingsStore.fileName), startup: startup)
        loadSettings()
        playbackOptions.onStopRequested = { [weak self] in self?.stopPlayback() }
        playbackOptions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &listeningSubscriptions)
        playbackOptions.$document.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resolveComputedLengthIfNeeded(); self?.applyPlaybackOptions(); self?.updateNowPlaying(force: true)
            }
        }.store(in: &listeningSubscriptions)
        playbackOptions.$remainingSleepSeconds.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyPlaybackOptions() }
        }.store(in: &listeningSubscriptions)
        playbackOptions.$stopAfterSubtune.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyPlaybackOptions() }
        }.store(in: &listeningSubscriptions)
        history.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &listeningSubscriptions)
        listening.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &listeningSubscriptions)
        metadataIndex.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &listeningSubscriptions)
        savedSearches.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &listeningSubscriptions)
        playbackOptions.$isLoaded.filter { $0 }.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pendingListeningRestore else { return }
                self.pendingListeningRestore = false; self.restoreSessionIfPossible()
            }
        }.store(in: &listeningSubscriptions)
        listening.$isLoaded.filter { $0 }.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.favorites = self.collectionFavorites.read()
                self.activateListeningLibrary()
                if self.pendingListeningRestore {
                    self.pendingListeningRestore = false
                    self.restoreSessionIfPossible()
                }
            }
        }.store(in: &listeningSubscriptions)
    }

    // MARK: - Einstellungen laden

    /// Liest die gespeicherten Einstellungen. Bewusst ueber `didSet`-freie
    /// Zuweisung waere hier falsch — die `didSet`-Bloecke schreiben denselben
    /// Wert nur zurueck, das ist harmlos und spart eine zweite Codebahn.
    private func loadSettings() {
        shuffle = defaults.bool(forKey: Keys.shuffle)
        // `object(forKey:)` unterscheidet „nie gesetzt" von „auf false gesetzt";
        // `bool(forKey:)` allein wuerde beim Erststart faelschlich false liefern.
        autoNext = defaults.object(forKey: Keys.autoNext) as? Bool ?? true
        sessionRestoreEnabled = defaults.object(forKey: Keys.sessionRestore) as? Bool ?? true
        volume = defaults.object(forKey: Keys.volume) as? Float ?? 1.0
        themeMode = ThemeMode(storedValue: defaults.string(forKey: ThemeMode.userDefaultsKey))
        favorites = Set(defaults.stringArray(forKey: Keys.favorites) ?? [])
    }

    // MARK: - Zustandsaenderungen fuer Unterbereiche

    /// Setzt die sichtbare Titelliste und den Ordnerbaum. Wird vom
    /// Bibliotheks-Teil aufgerufen (`AppModel+Library.swift`).
    func applyLibrary(tracks: [LibraryTrack], folderTree: MusicLibraryFolder, preservingListeningQueue: Bool = false) {
        guard !collectionTransfer.isApplying || preservingListeningQueue else { return }
        self.tracks = tracks
        self.folderTree = folderTree
        let root = services.library?.root ?? URL(fileURLWithPath: "/")
        listeningPlaylist = Playlist(tracks: tracks.map {
            PlaylistTrack(id: $0.id, name: $0.name, folderPath: $0.folderPath, url: $0.url(in: root))
        })
        if !preservingListeningQueue { activateListeningLibrary(removeMissing: true) }
        if let library = services.library { metadataIndex.refresh(library: library) }
        // Ist der laufende Titel verschwunden (z.B. per Finder geloescht),
        // gilt kein Titel mehr als aktuell — die Wiedergabe laeuft aber weiter,
        // bis der Nutzer etwas anderes waehlt.
        if !preservingListeningQueue, let id = currentTrackID, !tracks.contains(where: { $0.id == id }) {
            currentTrackID = nil
        }
    }

    func setCurrentTrackID(_ id: String?) {
        currentTrackID = id
    }

    func setImportProgress(_ progress: ImportProgress?) {
        importProgress = progress
    }

    func setSonglengthsStatus(_ status: String) {
        songlengthsStatus = status
    }

    func setSTILStatus(_ status: String) {
        stilStatus = status
    }

    func setFavorites(_ value: Set<String>) {
        guard !collectionTransfer.isApplying else { return }
        favorites = value
        defaults.set(Array(value).sorted(), forKey: Keys.favorites)
    }

    private func didImportCollection() {
        favorites = collectionFavorites.read()
        resolveComputedLengthIfNeeded(); applyPlaybackOptions(); updateNowPlaying(force: true)
        // Persönlicher Sammlungsaustausch ändert keine Musikdateien. Der
        // vorhandene Bibliotheksstand bleibt gültig; ein freier Snapshot-Task
        // könnte nach einem anschließenden Reset alte Titel zurückbringen.
    }

    /// Favoritenstatus eines Titels umschalten.
    func toggleFavorite(_ trackID: String) {
        var updated = favorites
        if updated.contains(trackID) {
            updated.remove(trackID)
        } else {
            updated.insert(trackID)
        }
        setFavorites(updated)
    }

    func isFavorite(_ trackID: String) -> Bool {
        favorites.contains(trackID)
    }

    // MARK: - Formatierung

    /// Sekunden als „M:SS" bzw. „H:MM:SS". Nicht-endliche oder negative Werte
    /// ergeben „0:00" statt „nan:aN" — der Scrubber liefert beim Ziehen
    /// gelegentlich solche Zwischenwerte.
    ///
    /// Die Rechnung selbst steht im Core (`PlaytimeFormat`), weil Mac-App und
    /// Quick-Look-Vorschau dieselbe Anzeige brauchen. Der Aufruf bleibt hier
    /// stehen, damit die Ansichten und ihre Tests unveraendert weiterlaufen.
    nonisolated static func formatTime(_ seconds: Double) -> String {
        PlaytimeFormat.string(seconds)
    }

    // MARK: - Szenenphase

    /// Wird vom App-Einstiegspunkt gerufen, wenn die App in den Vorder- oder
    /// Hintergrund wechselt.
    ///
    /// Wichtig: Audio wird hier NICHT angehalten. Genau das ist der Zweck der
    /// Hintergrund-Wiedergabe — der Nutzer sperrt das Display und die Musik
    /// laeuft weiter. Angehalten werden nur die zeichnenden Timer.
    func scenePhaseChanged(to phase: ScenePhase) {
        let active = (phase == .active)
        guard active != isSceneActive else { return }
        isSceneActive = active
        if !active {
            observeHistory(force: true)
            listening.flush(); savedSearches.flush(); playbackOptions.flush()
            historyBackgroundSaver.flush(history)
        }
        playbackOptions.refreshSleepTimer()
        // Nur Zeit und Scrubber werden gespiegelt. Das Oszilloskop liest seine
        // schnellen Werte selbst; Auto-Next und Now Playing haben ihren 1-Hz-Lauf.
        updateUIRefreshInterval()
        if active {
            // Beim Zurueckkommen kann sich die Bibliothek von aussen geaendert
            // haben (Finder-Dateifreigabe), also abgleichen.
            refreshLibrary()
        } else {
            // Vor dem Hintergrundwechsel den Sitzungszustand sichern — es ist
            // nicht garantiert, dass die App danach noch einmal Rechenzeit
            // bekommt, bevor iOS sie beendet.
            saveSessionState()
        }
    }

    func setPlaybackViewVisible(_ visible: Bool) {
        isPlaybackViewVisible = visible
        updateUIRefreshInterval()
    }

    private func updateUIRefreshInterval() {
        coordinator.setUIUpdateInterval(isSceneActive && isPlaybackViewVisible ? 0.1 : 1.0)
    }
}

// MARK: - Datentypen der Bibliothek

/// Schlanker Dateieintrag. Der getrennte Headercache ergaenzt Metadaten im
/// Hintergrund, ohne den Dateiscan oder die erste Anzeige aufzuhalten.
struct LibraryTrack: Identifiable, Hashable, Sendable {
    /// Relativer Pfad zur Bibliothekswurzel. Stabile Identitaet ueber
    /// Neuinstallationen hinweg — anders als eine absolute URL.
    let id: String
    /// Anzeigename (Dateiname ohne Endung).
    let name: String
    /// Ordner relativ zur Wurzel, "" fuer die oberste Ebene.
    let folderPath: String

    /// Absolute URL, aufgeloest gegen die aktuelle Bibliothekswurzel.
    func url(in root: URL) -> URL {
        root.appendingPathComponent(id)
    }
}

/// Fortschritt eines laufenden Imports.
struct ImportProgress: Equatable, Sendable {
    let current: Int
    let total: Int
    let currentFile: String

    /// 0…1, oder `nil` solange die Gesamtzahl noch gezaehlt wird.
    var fraction: Double? {
        guard total > 0 else { return nil }
        return min(1.0, Double(current) / Double(total))
    }
}

/// Ergebnis eines abgeschlossenen oder abgebrochenen Imports.
struct ImportReport: Equatable, Sendable {
    let imported: Int
    let skipped: Int
    let failed: [String]
    let wasCancelled: Bool
}
