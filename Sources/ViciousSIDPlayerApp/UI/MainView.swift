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
    // Erscheinungsbild-Modus aus den Einstellungen (Auto/Hell/Dunkel). Gleicher
    // UserDefaults-Key wie in SettingsView — Aenderungen dort wirken sofort.
    // "auto" (Default) folgt dem Hell/Dunkel-Modus von macOS.
    @AppStorage(ThemeMode.userDefaultsKey) private var themeModeRaw = ThemeMode.auto.rawValue
    // Aktueller System-Modus (Dark ja/nein); wird ueber die verteilte
    // "AppleInterfaceThemeChangedNotification" live nachgefuehrt (siehe
    // setupMenuNotificationHandlers), damit der Auto-Modus sofort umschaltet.
    @State private var systemPrefersDark = MainView.systemInterfaceIsDark()
    @State private var volume: Float = 1.0
    @State private var autoNext = true
    // Zufallswiedergabe. @AppStorage sichert den Zustand in UserDefaults, bleibt
    // also ueber App-Neustarts erhalten.
    @AppStorage("shuffleEnabled") private var shuffle = false
    // Breite der linken Playlist-Seitenleiste (anpassbar per Splitter).
    @AppStorage("sidebarWidth") private var sidebarWidth = 240.0
    // Autoplay-Ordner aus den Einstellungen (Cmd+,). "" = Standard-Ordner.
    // Gleicher UserDefaults-Key wie in SettingsView — Aenderungen dort landen
    // hier sofort (onChange laedt die Playlist neu).
    @AppStorage("autoplayFolderPath") private var autoplayFolderPath = ""
    // MPRemoteCommandCenter nur einmal verdrahten (onAppear kann mehrfach feuern).
    @State private var mediaCommandsConfigured = false
    // Session-Restore: letzter Track, Subtune und Position werden laufend
    // gesichert und beim naechsten Start wiederhergestellt — aber nur bei
    // AUSGESCHALTETEM Shuffle (mit Shuffle ist der zufaellige Start bei jedem
    // Launch das gewollte Verhalten).
    //
    // Gespeichert wird seit 2026-08-15 die stabile Titel-ID (`PlaylistTrackID`),
    // also der Pfad relativ zum Autoplay-Ordner. Der Schluessel heisst weiter
    // "lastTrackPath", damit ein vorhandener absoluter Pfad beim ersten Start
    // noch gelesen und umgerechnet werden kann.
    @AppStorage("lastTrackPath") private var lastTrackPath = ""
    @AppStorage("lastSubtune") private var lastSubtune = 0
    @AppStorage("lastPosition") private var lastPosition = 0.0
    // Drosselung der Positions-Sicherung (alle 5 s statt bei jedem UI-Tick).
    @State private var lastSavedBucket = -1
    
    // Die Titelliste. Aufbau, Duplikatpruefung, Suche, Favoriten und die
    // Rechnung fuer den naechsten Titel stehen im Core (`Playlist`) und sind
    // dort getestet — hier bleibt nur der Zustand.
    @State private var playlist = Playlist()
    @State private var currentTrackIdx: Int = -1

    // Die Bibliothek zum aktuellen Autoplay-Ordner: sie liefert den Ordner-Scan
    // und haelt den Index vor. Optional und veraenderlich, weil der Ordner in
    // den Einstellungen umgestellt werden kann und `MusicLibrary` ihre Wurzel
    // bewusst nicht wechselt — bei einer Aenderung wird sie neu gebaut.
    @State private var library: MusicLibrary? = nil

    // Der Abgleich der Bibliothek mit dem Dateisystem laeuft im Hintergrund:
    // Bei einer HVSC-Sammlung mit ueber 50.000 Dateien dauert er Sekunden, und
    // solange er (wie bis v1.9.10) im Hauptthread lief, stand die Oberflaeche
    // sichtbar still. Genau ein Abgleich zur Zeit; die Generation entscheidet,
    // wer sein Ergebnis noch eintragen darf — ein Ordnerwechsel in den
    // Einstellungen macht einen laufenden Scan gegenstandslos.
    // Mini-Player: kompakte Fensterleiste mit Titel und Transport statt des
    // vollen Fensters. Bleibt ueber App-Starts erhalten.
    @AppStorage("miniPlayer") private var miniPlayer = false
    /// Das AppKit-Fenster, in dem diese Ansicht haengt — gebraucht zum
    /// Umschalten der Fenstergroesse. Wird von `WindowAccessor` gemeldet.
    @State private var hostWindow: NSWindow? = nil
    /// Die Fenstergroesse vor dem Wechsel in den Mini-Player.
    @State private var fullWindowFrame: NSRect? = nil

    // Ordneransicht statt flacher Liste. Bleibt ueber App-Starts erhalten.
    @AppStorage("sidebarShowsFolders") private var showFolderTree = false
    /// Der Ordnerbaum der Bibliothek.
    ///
    /// Wird NICHT bei jedem Bildaufbau gerechnet und auch nicht im Hauptthread:
    /// Das Gruppieren von 50.000 Eintraegen dauert eine halbe Sekunde (gemessen
    /// am 2026-08-23). Er entsteht deshalb im Hintergrund, einmal aus dem
    /// gespeicherten Index und noch einmal nach dem Abgleich.
    @State private var folderTree = MusicLibrary.folderTree(for: [])
    /// Steht der Baum schon? Bis dahin zeigt die Seitenleiste die flache Liste,
    /// auch wenn die Ordneransicht eingeschaltet ist — besser die Titel als ein
    /// leeres Feld.
    @State private var folderTreeReady = false
    @State private var folderTreeTask: Task<Void, Never>? = nil
    @State private var folderTreeGeneration = 0
    /// Pfade der aufgeklappten Ordner.
    ///
    /// Bleibt ueber App-Starts erhalten: Wer sich in einer HVSC bis zu seinem
    /// Komponisten durchgeklickt hat, will nicht bei jedem Start von vorn
    /// anfangen. Gespeichert wie die Favoriten als Zeichenkettenliste in den
    /// Einstellungen — `@AppStorage` kann keine Mengen.
    @State private var expandedFolders: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: MainView.expandedFoldersKey) ?? [])

    static let expandedFoldersKey = "sidebarExpandedFolders"

    @State private var libraryScanTask: Task<Void, Never>? = nil
    @State private var libraryScanGeneration = 0
    /// Zeigt in der Seitenleiste an, dass gerade abgeglichen wird.
    @State private var isScanningLibrary = false
    // Fernsteuerbefehl `track`, der beim Kaltstart noch keine Liste vorfand.
    // Er wird nach dem Bibliotheks-Scan genau einmal erneut versucht.
    @State private var pendingTrackCommandID: String? = nil

    // Playlist-Filter: Live-Suche nach Titel + Ordner sowie "nur Favoriten".
    // Beide filtern NUR die Anzeige (sichtbare Indizes) — Auswahl, Auto-Next
    // und Shuffle arbeiten weiter auf der vollen Liste mit globalen Indizes.
    @State private var searchText = ""
    @State private var favoritesOnly = false
    // Favoriten als stabile Titel-IDs, persistent in UserDefaults.
    @State private var favorites = PlaylistFavorites()

    // Der Ausschnitt der Playlist, den das Titelmenue oben zeigt. Die Rechnung
    // steht im Core (`PlaylistMenuWindow`) und ist dort getestet.
    private var tuneMenuIndices: [Int] {
        PlaylistMenuWindow.indices(count: playlist.count, anchor: currentTrackIdx)
    }

    @State private var showFileImporter = false
    @State private var dragOver = false
    @State private var errorMessage: String? = nil
    @State private var isTransitioning = false
    // onAppear kann mehrfach feuern (Fenster erscheint erneut, z.B. beim Datei-Open
    // der laufenden App). Einmalige Initialisierung darf sich dann nicht wiederholen.
    @State private var didInitialize = false
    // Fallback-Dauer, wenn keine echte Songlaenge bekannt ist (weder HVSC-DB-
    // Eintrag noch berechnete Laenge): dient dann als Scrub-Limit und Auto-Next-
    // Schwelle. Mit Songlaenge gilt stattdessen currentDuration (s.u.).
    private let SCRUB_MAX = 360.0

    // Songlaengen-Aufloesung (Reihenfolge: HVSC-DB -> berechneter Cache -> SCRUB_MAX).
    // songlengthDB wird im Hintergrund geladen (Datei aus den Einstellungen oder
    // Auto-Fund im HVSC-Ordner); currentTrackLengths sind die DB-Laengen der
    // aktuellen Datei (je Subtune); computedLength ist die im Hintergrund
    // berechnete Laenge des aktuellen Subtunes (Tunes, die in Stille enden).
    @State private var songlengthDB: SonglengthDB? = nil
    @State private var currentTrackLengths: [Double]? = nil
    @State private var computedLength: Double? = nil
    @State private var currentMD5: String? = nil
    // Genau je ein verwalteter DB-Lade- und Schaetz-Task. Generationen verhindern,
    // dass ein langsames altes Ergebnis einen inzwischen gewaehlten Pfad/Track
    // ueberschreibt; der Key dedupliziert identische Schaetz-Anfragen.
    @State private var songlengthLoadTask: Task<Void, Never>? = nil
    @State private var songlengthLoadGeneration = 0
    @State private var lengthEstimateTask: Task<Void, Never>? = nil
    /// Wem gehoert `lengthEstimateTask` gerade? Ohne diese Angabe leerte der
    /// spaete Abschluss von Schaetzung A den Griff bedingungslos und traf damit
    /// die inzwischen eingetragene Schaetzung B (Review-Fund 2026-08-17).
    @State private var lengthEstimateOwner: SongLengthEstimateTicket? = nil
    // Die Reihenfolge der Laengenquellen und die Buchfuehrung ueber die laufende
    // Berechnung stehen im Core (`SongLengthResolver`) — dieselbe Instanz der
    // Regel wie in der iPhone-App, und dort auch getestet. Die Ansicht haelt nur
    // noch den Task.
    // `@State` statt `let`: Der Resolver ist eine ZUSTANDSBEHAFTETE Referenz
    // (activeKey, generation). Als normales `private let` bekam jede
    // Neuerzeugung der Ansicht eine frische Instanz, waehrend der Task im
    // SwiftUI-Zustand ueberlebte — Deduplikation, Generation und Abbruch liefen
    // dann auf verschiedenen Instanzen (Review-Fund 2026-08-17). `@State` haelt
    // die erste Instanz ueber alle Neuerzeugungen hinweg fest.
    @State private var lengthResolver = SongLengthResolver()
    // Pfad zur Songlengths.md5 aus den Einstellungen ("" = automatisch suchen).
    @AppStorage("songlengthsPath") private var songlengthsPath = ""

    // STIL — die "SID Tune Information List" der HVSC. Sie sammelt, was im
    // SID-Dateikopf keinen Platz hat: welche Vorlage ein Tune covert, wer die
    // Melodie geschrieben hat, Anmerkungen zu einzelnen Subtunes. Die Datei
    // gehoert dem HVSC-Projekt und wird nicht mitgeliefert; die App liest die
    // Fassung des Nutzers (Einstellungen oder Auto-Fund).
    //
    // `stilRoot` ist die HVSC-Wurzel zur gefundenen Datei. Ohne sie ist die
    // Datenbank wertlos: Die STIL kennt ihre Titel unter Pfaden wie
    // "/MUSICIANS/H/Hubbard_Rob/Commando.sid", und nur relativ zu dieser Wurzel
    // laesst sich eine Datei auf der Platte in genau diesen Pfad umrechnen.
    @AppStorage("stilPath") private var stilPath = ""
    @State private var stilDB: STILDatabase? = nil
    @State private var stilRoot: URL? = nil
    @State private var stilLoadTask: Task<Void, Never>? = nil
    @State private var stilLoadGeneration = 0

    // Was die STIL zum laufenden Titel und Subtune sagt — `nil`, wenn sie ihn
    // nicht kennt. Lieber nichts anzeigen als die Anmerkung eines fremden
    // Titels: Das Pfadende zaehlt nur, wenn GENAU EIN Eintrag darauf passt.
    // (Der Satz "oder er ausserhalb der HVSC-Wurzel liegt" stand hier noch aus
    // der Zeit vor v1.9.13 und widersprach dem Code zwei Zeilen weiter.)
    private var currentSTILInfo: STILInfo? {
        guard let stilDB, let track = playlist.track(at: currentTrackIdx) else { return nil }
        // Erst der volle Pfad unterhalb der HVSC-Wurzel, sonst ein eindeutiges
        // Pfadende: Die meisten Sammlungen sind aus der HVSC herauskopiert und
        // liegen gar nicht mehr unter deren Wurzel. Beide Wege stehen im Core.
        guard let path = stilDB.resolvedPath(forFileURL: track.url,
                                             hvscRoot: stilRoot,
                                             relativePath: track.isExternal
                                                ? track.url.lastPathComponent
                                                : track.id)
        else { return nil }
        let info = stilDB.info(forHVSCPath: path, subtune: coordinator.currentSubtune)
        return info.isEmpty ? nil : info
    }

    // Effektive Dauer des aktuellen Subtunes — bestimmt Scrubber, Auto-Next,
    // Now-Playing und WAV-Export-Dauer. Die Leiter aus den drei Quellen steht im
    // Core, damit Mac und iPhone nicht auseinanderlaufen.
    private var currentDuration: Double {
        return SongLengthSelection.duration(databaseLengths: currentTrackLengths,
                                            subtune: coordinator.currentSubtune,
                                            computed: computedLength,
                                            fallback: SCRUB_MAX)
    }
    
    private var themeMode: ThemeMode { ThemeMode(storedValue: themeModeRaw) }

    // Effektives Theme: der gespeicherte Modus, im Auto-Fall aufgeloest gegen
    // den aktuellen System-Modus. Alle Farben im Body haengen hieran.
    private var theme: PlayerTheme {
        themeMode.resolvesToDark(systemPrefersDark: systemPrefersDark) ? .dark : .light
    }

    // Liest den macOS-Dark-Mode aus den globalen UserDefaults: der Key
    // "AppleInterfaceStyle" existiert nur im Dark-Modus (Wert "Dark") — im
    // Hell-Modus fehlt er. Zuverlaessiger als NSApp.effectiveAppearance, weil
    // Letzteres unsere eigene appearance-Override widerspiegeln wuerde.
    static func systemInterfaceIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    // Was der Oeffnen-Dialog anbieten darf: `.sid`-Dateien und Ordner.
    //
    // Der exportierte UTI ist der genauere Filter, steht dem System aber erst
    // zur Verfuegung, wenn das App-Bundle registriert ist — in `swift run` also
    // nicht. Deshalb der Rueckfall auf die Endung; findet das System auch die
    // nicht, bleibt `.data` (alles anzeigen) besser als ein Dialog, der gar
    // nichts mehr zeigt.
    static let openPanelContentTypes: [UTType] = {
        let sid = UTType(SidFileType.uti)
            ?? UTType(filenameExtension: SidFileType.fileExtension)
            ?? .data
        return [sid, .folder]
    }()

    public init() {}

    public var body: some View {
        let isLight = theme == .light
        let bgSecondary = isLight ? Color.macLightSidebar : Color.macDarkSidebar
        let borderCol = isLight ? Color.macLightBorder : Color.macDarkBorder
        let textCol = isLight ? Color.macLightText : Color.macDarkText
        let textSecCol = isLight ? Color.macLightSecondary : Color.macDarkSecondary
        let accentCol = isLight ? Color.macLightAccent : Color.macDarkAccent

        ZStack {
            if miniPlayer {
                miniPlayerBar(textCol: textCol,
                              textSecCol: textSecCol,
                              accentCol: accentCol,
                              bgSecondary: bgSecondary)
            } else {
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
                        // Solange die Bibliothek gegen das Dateisystem
                        // abgeglichen wird, ist die Liste schon benutzbar (sie
                        // steht aus dem gespeicherten Index) — aber eben noch
                        // nicht vollstaendig. Das sagt dieser Ring.
                        if isScanningLibrary {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)
                                .help("Bibliothek wird abgeglichen …")
                        }
                        Spacer()
                        // Umschalter zwischen flacher Titelliste und
                        // Ordneransicht. Bei einer HVSC-Sammlung ist die flache
                        // Liste mit 50.000 Zeilen kaum zu ueberblicken; die
                        // Ordner sind dort die eigentliche Gliederung
                        // (Komponist, Spiel, Sammlung).
                        if !playlist.isEmpty {
                            Button(action: { showFolderTree.toggle() }) {
                                Image(systemName: showFolderTree
                                      ? "list.bullet.indent"
                                      : "list.bullet")
                                    .font(.system(size: 10))
                                    .foregroundColor(showFolderTree ? accentCol : textSecCol)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help(showFolderTree ? "Als flache Liste zeigen" : "Nach Ordnern gliedern")
                        }
                        // Alles auf- oder zuklappen — nur in der Ordneransicht
                        // und nur, wenn es ueberhaupt Ordner gibt.
                        if showFolderTree, !folderTree.subfolders.isEmpty {
                            Button(action: expandAllFolders) {
                                Image(systemName: "chevron.down.2")
                                    .font(.system(size: 9))
                                    .foregroundColor(textSecCol)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Alle Ordner aufklappen")

                            Button(action: collapseAllFolders) {
                                Image(systemName: "chevron.up.2")
                                    .font(.system(size: 9))
                                    .foregroundColor(textSecCol)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Alle Ordner zuklappen")
                        }
                        // Filter "nur Favoriten" (Stern) neben dem Papierkorb.
                        if !playlist.isEmpty {
                            Button(action: { favoritesOnly.toggle() }) {
                                Image(systemName: favoritesOnly ? "star.fill" : "star")
                                    .font(.system(size: 10))
                                    .foregroundColor(favoritesOnly ? .yellow : textSecCol)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help(favoritesOnly ? "Alle Titel zeigen" : "Nur Favoriten zeigen")

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

                    // Live-Suche: filtert die Playlist waehrend des Tippens.
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10))
                            .foregroundColor(textSecCol)
                        TextField("Suchen", text: $searchText)
                            .textFieldStyle(PlainTextFieldStyle())
                            .font(.system(size: 12))
                            .foregroundColor(textCol)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(textSecCol)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Suche löschen")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(isLight ? Color.macLightSurface : Color.macDarkSurface)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderCol, lineWidth: 1))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                    TrackListView(playlist: playlist,
                                  currentTrackIdx: currentTrackIdx,
                                  searchText: searchText,
                                  favoritesOnly: favoritesOnly,
                                  favorites: favorites,
                                  isLight: isLight,
                                  showTree: showFolderTree && folderTreeReady,
                                  folderTree: folderTree,
                                  expandedFolders: expandedFolders,
                                  onSelect: selectTrack,
                                  onToggleFavorite: toggleFavorite,
                                  onToggleFolder: toggleFolder)

                    Divider()
                        .background(borderCol)
                    
                    // Metadata Panel
                    VStack(alignment: .leading, spacing: 6) {
                        // codereview-ok: MetaLine wird genutzt; kein toter Code (2026-07-01)
                        MetaLine(label: "TITLE", value: coordinator.trackName, theme: theme)
                        MetaLine(label: "COMPOSER", value: coordinator.composer, theme: theme)
                        MetaLine(label: "INFO", value: coordinator.info, theme: theme)

                        // Anmerkungen der HVSC-Kuratoren zum laufenden Titel
                        // (STIL). Sie erscheinen nur, wenn es welche gibt —
                        // ohne HVSC-Sammlung bleibt der Bereich unsichtbar
                        // statt leer herumzustehen.
                        if let stil = currentSTILInfo {
                            Divider()
                                .background(borderCol)
                                .padding(.vertical, 2)
                            Text("STIL")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(textSecCol)
                            // Eigener Rollbereich mit fester Hoehe: Manche
                            // Kommentare der HVSC sind Absaetze, die sonst die
                            // ganze Seitenleiste auseinanderziehen wuerden.
                            ScrollView {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(Array(stil.orderedFields.enumerated()), id: \.offset) { _, field in
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(field.label)
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundColor(textSecCol)
                                            Text(field.value)
                                                .font(.system(size: 11))
                                                .foregroundColor(textCol)
                                                .fixedSize(horizontal: false, vertical: true)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 140)
                        }

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
                .frame(width: CGFloat(max(180.0, min(600.0, sidebarWidth))))
                .background(bgSecondary)
                
                SidebarSplitter(width: $sidebarWidth,
                                range: 180.0...600.0,
                                defaultWidth: 240.0,
                                borderCol: borderCol)
                
                // Main Panel
                VStack(spacing: 0) {
                    // Controls View
                    HStack(spacing: 10) {
                        Text("TUNE:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(textSecCol)
                        
                        // Titelwaehler. Frueher ein `Picker` ueber die GANZE
                        // Playlist — daraus baute macOS ein Menue mit einem
                        // Eintrag je Titel. Bei 50.001 Titeln waren das rund
                        // 5,2 GB Arbeitsspeicher, und die App stuerzte beim
                        // Start im Ansichtsaufbau von SwiftUI ab (gemessen am
                        // 2026-08-23). Jetzt zeigt das Menue hoechstens
                        // `PlaylistMenuWindow.defaultLimit` Titel rund um den
                        // laufenden — wer in einer grossen Sammlung sucht, tut
                        // das in der Titelliste links.
                        Menu {
                            ForEach(tuneMenuIndices, id: \.self) { idx in
                                if let track = playlist.track(at: idx) {
                                    Button(track.name) { selectTrack(at: idx) }
                                }
                            }
                            if playlist.count > PlaylistMenuWindow.defaultLimit {
                                Divider()
                                Text("… \(playlist.count - PlaylistMenuWindow.defaultLimit) weitere Titel: links in der Liste suchen")
                            }
                        } label: {
                            Text(playlist.track(at: currentTrackIdx)?.name ?? "— Auswählen —")
                                .lineLimit(1)
                        }
                        // 260 ist die Wunschbreite. Nachgeben darf der
                        // Titelwaehler trotzdem: Bei Minimalbreite des Fensters
                        // (1140 pt) war die Kopfzeile sonst zu eng, und der
                        // Knopf „Öffnen…" daneben verlor seine Beschriftung —
                        // er stand dann als leere Pille da (2026-08-23).
                        .frame(minWidth: 150, idealWidth: 260, maxWidth: 260)
                        .help("Titel wählen")

                        Button("Öffnen…") {
                            showFileImporter = true
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(textCol)
                        // Beschriftung nie wegkuerzen: Ein Knopf ohne Aufschrift
                        // sagt nichts mehr.
                        .fixedSize()
                        .help("SID-Datei(en) öffnen")

                        Toggle("AUTO NEXT", isOn: $autoNext)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(textCol)
                            .fixedSize()   // "AUTO NEXT" einzeilig, kein haesslicher Umbruch
                            .help("Am Songende automatisch weiter — erst die Subtunes der Datei, dann der nächste Titel")

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

                        Spacer(minLength: 8)

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

                        // Transport: Shuffle · Vorheriger Titel · 15 s zurueck · Play/Pause · 30 s vor · Naechster Titel · Stop.
                        HStack(spacing: 12) {
                            Button(action: { shuffle.toggle() }) {
                                Image(systemName: "shuffle").font(.system(size: 15))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(shuffle ? accentCol : textSecCol)
                            .help(shuffle ? "Zufallswiedergabe: an" : "Zufallswiedergabe: aus")

                            Button(action: { playPreviousTrack() }) {
                                Image(systemName: "backward.end.fill").font(.system(size: 14))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(playlist.count > 1 ? textCol : textSecCol.opacity(0.35))
                            .disabled(playlist.count <= 1)
                            .help("Vorheriger Titel (⌘←)")

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

                            Button(action: { playNextTrack() }) {
                                Image(systemName: "forward.end.fill").font(.system(size: 14))
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            .foregroundColor(playlist.count > 1 ? textCol : textSecCol.opacity(0.35))
                            .disabled(playlist.count <= 1)
                            .help("Nächster Titel (⌘→)")

                            Button(action: { coordinator.stop() }) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 14))
                                    .offset(y: 2)   // wirkte optisch zu hoch — 2 px tiefer
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
                            get: { min(coordinator.elapsedSeconds, currentDuration) },
                            set: { val in coordinator.seek(seconds: val) }
                        ), in: 0...currentDuration)
                        .accentColor(accentCol)
                        .help("Position — auch im pausierten oder gestoppten Zustand nutzbar; Play startet dann von hier")

                        // Echte Songlaenge (HVSC-DB oder berechnet), sonst Fallback 6:00.
                        Text(formatTime(currentDuration))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(textSecCol)
                            .frame(width: 36)
                            .help(currentTrackLengths != nil
                                  ? "Songlänge aus der HVSC-Datenbank"
                                  : (computedLength != nil ? "Songlänge berechnet (Tune endet in Stille)" : "Keine Songlänge bekannt — Standard-Limit"))
                        
                        Text("VOL:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(textSecCol)
                        
                        Slider(value: $volume, in: 0...1.0)
                            .accentColor(accentCol)
                            .frame(width: 70)
                            .onChange(of: volume) { val in
                                coordinator.setVolume(val)
                            }
                            .help("Lautstärke")
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
            .frame(minWidth: 1140, minHeight: 540)
            }

            // Meldet das Fenster; unsichtbar und ohne Platzbedarf.
            WindowAccessor { window in
                guard hostWindow !== window else { return }
                hostWindow = window
                // Startet die App im Mini-Player, ist das Fenster noch in
                // voller Groesse — jetzt, wo es bekannt ist, zusammenziehen.
                if miniPlayer { DispatchQueue.main.async { applyMiniPlayerLayout() } }
            }
            .frame(width: 0, height: 0)

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
            // Vorher stand hier `.data` — das heisst „jede Datei" und machte den
            // Dialog nutzlos, weil er auch Bilder und Textdateien anbot.
            // `SidFileType` (Core) haelt Endung und UTI an genau einer Stelle;
            // ueber den exportierten Typ filtert macOS selbst. Ordner bleiben
            // erlaubt, weil die App auch ganze Sammlungen aufnimmt.
            allowedContentTypes: MainView.openPanelContentTypes,
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
                // Favoriten aus den Einstellungen. Die Umrechnung alter absoluter
                // Pfade auf relative Titel-IDs passiert erst, wenn die
                // Bibliothekswurzel feststeht (`migrateStoredIDs`).
                favorites = PlaylistFavorites(
                    storedValues: UserDefaults.standard.stringArray(forKey: PlaylistFavorites.userDefaultsKey) ?? [],
                    root: nil
                )
                coordinator.setVolume(volume)
                setupMenuNotificationHandlers()
                setupMediaRemoteCommands()
                // Songlengths-DB (HVSC) im Hintergrund laden — VOR der Playlist,
                // damit der erste Track seine Laenge moeglichst schon findet.
                loadSonglengthDB()
                // Die Titel-Anmerkungen der HVSC ebenfalls im Hintergrund.
                loadSTIL()
                // Start-Playlist aus dem Autoplay-Ordner laden (siehe Einstellungen)
                // und die letzte Sitzung fortsetzen.
                loadLocalAudioFolder(restoreSession: true)
            }
            // Dateien, die per Doppelklick/"Oeffnen mit" die App gestartet haben,
            // liegen schon im Puffer des AppDelegate -> jetzt nachziehen (Kaltstart;
            // Warmstart laeuft zusaetzlich ueber die "openSIDFiles"-Notification).
            drainPendingOpenURLs()
            drainPendingRemoteCommands()
            applyAppearance()
        }
        // Erscheinungsbild-Modus geaendert (Einstellungen oder Cmd+T) -> AppKit-
        // Appearance nachziehen; die SwiftUI-Farben folgen ueber `theme` von selbst.
        .onChange(of: themeModeRaw) { _ in applyAppearance() }
        // Mini-Player an/aus -> Fenstergroesse nachziehen. Erst einen Durchlauf
        // spaeter: Vorher gilt noch die Mindestgroesse der alten Ansicht, und
        // das Fenster liesse sich gar nicht auf die Leiste zusammenziehen.
        .onChange(of: miniPlayer) { _ in
            DispatchQueue.main.async { applyMiniPlayerLayout() }
        }
        // Autoplay-Ordner in den Einstellungen geaendert -> Playlist sofort aus
        // dem neuen Ordner aufbauen (statt erst beim naechsten App-Start).
        .onChange(of: autoplayFolderPath) { _ in
            clearPlaylist()
            loadLocalAudioFolder()
            // Auto-Fund der Songlengths-DB haengt am Autoplay-Ordner -> neu suchen.
            if songlengthsPath.isEmpty { loadSonglengthDB() }
            // Fuer die STIL gilt dasselbe.
            if stilPath.isEmpty { loadSTIL() }
        }
        // STIL-Datei in den Einstellungen geaendert -> neu laden.
        .onChange(of: stilPath) { _ in loadSTIL() }
        // "Now Playing"-Infos bei jedem relevanten Zustandswechsel aktualisieren
        // (nicht bei jedem elapsed-Tick — Titel/Status/Position genuegen dem System).
        .onChange(of: coordinator.isPlaying) { _ in updateNowPlayingInfo() }
        .onChange(of: coordinator.isPaused) { _ in updateNowPlayingInfo() }
        .onChange(of: coordinator.trackName) { _ in updateNowPlayingInfo() }
        // Subtune gewechselt -> Laenge des neuen Subtunes aufloesen (DB-Array wird
        // per Index gelesen; nur die berechnete Laenge muss neu ermittelt werden).
        .onChange(of: coordinator.currentSubtune) { _ in
            resolveComputedLengthIfNeeded()
        }
        // Songlengths-Datei in den Einstellungen geaendert -> DB neu laden.
        .onChange(of: songlengthsPath) { _ in
            loadSonglengthDB()
        }
        .onChange(of: coordinator.isPaused) { _ in saveSessionState() }
        .onChange(of: coordinator.elapsedSeconds) { elapsed in
            // Position alle 5 s sichern (Session-Restore), nicht bei jedem Tick.
            let bucket = Int(elapsed / 5.0)
            if bucket != lastSavedBucket {
                lastSavedBucket = bucket
                saveSessionState()
            }
            if autoNext && elapsed >= currentDuration {
                // Erst alle weiteren Subtunes DIESER SID-Datei durchspielen, dann
                // zum naechsten Playlist-Eintrag. setSubtune setzt die Position auf 0
                // zurueck und laeuft (da isPlaying) direkt weiter.
                if coordinator.currentSubtune + 1 < coordinator.subtunesCount {
                    coordinator.setSubtune(sub: coordinator.currentSubtune + 1)
                } else if playlist.count > 1 {
                    coordinator.stop()
                    loadTrack(index: playlist.nextIndex(after: currentTrackIdx, shuffle: shuffle),
                              autoplay: true)
                } else {
                    coordinator.stop()
                }
            }
        }
    }

    // MARK: - Mini-Player

    /// Die kompakte Fassung des Fensters: Titel, Transport, Spielzeit.
    ///
    /// Gedacht fuer den Betrieb nebenher — das grosse Fenster mit Playlist und
    /// Oszilloskop braucht dafuer niemand. Umgeschaltet wird ueber das Menue
    /// „Wiedergabe" (Cmd+Alt+M) oder den Pfeil rechts in der Leiste; das Fenster
    /// schrumpft dabei und nimmt beim Zurueckschalten wieder seine alte Groesse
    /// an (`applyMiniPlayerLayout`).
    private func miniPlayerBar(textCol: Color,
                               textSecCol: Color,
                               accentCol: Color,
                               bgSecondary: Color) -> some View {
        HStack(spacing: 14) {
            ViciousAppIconOverlay()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.trackName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(textCol)
                    .lineLimit(1)
                Text(coordinator.composer)
                    .font(.system(size: 11))
                    .foregroundColor(textSecCol)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer(minLength: 8)

            Text("\(formatTime(coordinator.elapsedSeconds)) / \(formatTime(currentDuration))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textSecCol)
                .fixedSize()

            HStack(spacing: 12) {
                Button(action: { playPreviousTrack() }) {
                    Image(systemName: "backward.end.fill").font(.system(size: 13))
                }
                .buttonStyle(BorderlessButtonStyle())
                .foregroundColor(playlist.count > 1 ? textCol : textSecCol.opacity(0.35))
                .disabled(playlist.count <= 1)
                .help("Vorheriger Titel (⌘←)")

                Button(action: { togglePlayPause() }) {
                    Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17))
                }
                .buttonStyle(BorderlessButtonStyle())
                .foregroundColor(coordinator.isPlaying ? accentCol : .green)
                .help(coordinator.isPlaying ? "Pause" : "Wiedergabe")

                Button(action: { playNextTrack() }) {
                    Image(systemName: "forward.end.fill").font(.system(size: 13))
                }
                .buttonStyle(BorderlessButtonStyle())
                .foregroundColor(playlist.count > 1 ? textCol : textSecCol.opacity(0.35))
                .disabled(playlist.count <= 1)
                .help("Nächster Titel (⌘→)")
            }

            Button(action: { toggleMiniPlayer() }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12))
            }
            .buttonStyle(BorderlessButtonStyle())
            .foregroundColor(textSecCol)
            .help("Zurück zum vollen Fenster (⌘⌥M)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 64, maxHeight: 64)
        .background(bgSecondary)
    }

    /// Schaltet zwischen vollem Fenster und Mini-Player um.
    ///
    /// Die Fenstergroesse zieht `applyMiniPlayerLayout` nach — angestossen von
    /// `onChange`, damit jeder Weg zum Umschalten (Knopf, Menue, Einstellung)
    /// dasselbe tut.
    private func toggleMiniPlayer() {
        miniPlayer.toggle()
    }

    /// Zieht das Fenster auf die Groesse der gewaehlten Ansicht.
    ///
    /// Die volle Groesse wird beim Wechsel in den Mini-Player gemerkt und beim
    /// Zurueckschalten wieder gesetzt — sonst muesste der Nutzer sein Fenster
    /// jedes Mal neu aufziehen. Verankert wird oben links, damit die Leiste dort
    /// stehen bleibt, wo vorher der Fensterkopf war, statt nach unten zu
    /// wandern.
    private func applyMiniPlayerLayout() {
        guard let window = hostWindow else { return }
        if miniPlayer {
            if fullWindowFrame == nil { fullWindowFrame = window.frame }
            var frame = window.frame
            let height: CGFloat = 64 + (window.frame.height - window.contentLayoutRect.height)
            frame.origin.y = window.frame.maxY - height
            frame.size = NSSize(width: max(420, min(760, frame.width)), height: height)
            window.setFrame(frame, display: true, animate: true)
        } else if var full = fullWindowFrame {
            // Wurde die App im Mini-Player beendet, ist die gemerkte Groesse
            // die der Leiste. Die volle Ansicht verlangt aber mindestens
            // 1140 x 540 — sonst zoege AppKit das Fenster gleich wieder auf und
            // die gemerkte Position waere fuer die Katz.
            full.size.width = max(full.width, 1140)
            full.size.height = max(full.height, 560)
            window.setFrame(full, display: true, animate: true)
            fullWindowFrame = nil
        }
    }

    private func selectTrack(at index: Int) {
        loadTrack(index: index, autoplay: coordinator.isPlaying)
    }

    // Erzwingt die AppKit-Fenster-/Control-Darstellung passend zum App-Theme.
    // Ohne das rendern System-Controls (Picker, Toggle) im Hell-Modus dunklen Text
    // auf dem dunklen App-Hintergrund — "schwarz auf schwarz", unlesbar. So folgt
    // die gesamte Fensterdarstellung (auch die Titelleiste) dem gewaehlten Theme.
    // Im Auto-Modus wird die Override entfernt (nil) — dann folgt AppKit dem
    // System selbst, und unsere SwiftUI-Farben folgen via systemPrefersDark.
    private func applyAppearance() {
        #if canImport(AppKit)
        switch themeMode {
        case .auto: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
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

    // Relatives Vor-/Zurueckspringen, auf [0, Songdauer] begrenzt. Funktioniert auch
    // im pausierten/gestoppten Zustand (coordinator.seek puffert die Position dann).
    private func skip(by delta: Double) {
        let target = min(currentDuration, max(0.0, coordinator.elapsedSeconds + delta))
        coordinator.seek(seconds: target)
    }

    // Vorherigen / Nächsten Titel in der Playlist abspielen.
    private func playPreviousTrack() {
        guard playlist.count > 1 else { return }
        loadTrack(index: playlist.previousIndex(before: currentTrackIdx),
                  autoplay: coordinator.isPlaying)
    }

    private func playNextTrack() {
        guard playlist.count > 1 else { return }
        loadTrack(index: playlist.nextIndex(after: currentTrackIdx, shuffle: shuffle),
                  autoplay: coordinator.isPlaying)
    }

    @discardableResult
    private func loadTrack(index: Int, autoplay: Bool) -> Bool {
        guard !isTransitioning else { return false }
        guard let track = playlist.track(at: index) else { return false }

        isTransitioning = true
        var didLoad = false
        defer {
            if didLoad {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self.isTransitioning = false
                }
            } else {
                // Ein kaputter Restore-Track darf den sofortigen Fallback auf den
                // naechsten Playlist-Eintrag nicht durch die Debounce sperren.
                isTransitioning = false
            }
        }

        self.errorMessage = nil
        // Die absolute URL entsteht erst zur Laufzeit aus Bibliothekswurzel und
        // relativem Pfad (bei hereingezogenen Fremdtiteln steht sie direkt im
        // Eintrag) — gespeichert wird sie nie.
        let fileURL = track.url

        // codereview-ok: defer haelt Scope ueber den Read; ausserdem App nicht sandboxed (2026-07-01)
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }

        do {
            // codereview-ok: synchroner Read ist ok — eine SID laedt ins 64-KB-C64-RAM,
            // ist also <=~64 KB gross; der Read dauert <1 ms und blockiert den Main-Thread
            // nicht spuerbar. Async-Umbau des mehrfach aufgerufenen loadTrack braechte nur
            // Reihenfolge-Risiko ohne Nutzen (2026-07-08)
            let data = try Data(contentsOf: fileURL)
            let sidFile = try SidParser.parse(data: data)

            // Erst nach erfolgreichem Read/Parse den laufenden Track und seine
            // Session-Auswahl ersetzen. Ein defekter Restore-Eintrag hinterlaesst
            // damit keinen halb aktualisierten Zustand.
            cancelLengthEstimate()
            coordinator.stop()
            currentTrackIdx = index
            coordinator.setSid(sidFile)
            coordinator.setVolume(volume)
            // Songlaenge aufloesen: MD5 der Datei ist der Schluessel der HVSC-DB.
            // Ohne DB-Eintrag wird die Laenge im Hintergrund berechnet/gecacht.
            let md5 = SonglengthDB.md5Hex(of: data)
            currentMD5 = md5
            currentTrackLengths = songlengthDB?.lengths(forMD5: md5)
            resolveComputedLengthIfNeeded()
            loadLog.info("loadTrack[\(index, privacy: .public)] geparst: \(fileURL.lastPathComponent, privacy: .public), autoplay=\(autoplay, privacy: .public)")
            if autoplay {
                coordinator.play()
            }
            didLoad = true
            return true
        } catch {
            loadLog.error("loadTrack[\(index, privacy: .public)] Parser-Fehler: \(error.localizedDescription, privacy: .public)")
            self.errorMessage = "Parser-Fehler: \(error.localizedDescription)"
            return false
        }
    }

    // Von aussen hereingereichte Dateien und Ordner: Drag & Drop, der
    // Oeffnen-Dialog und "Oeffnen mit". Sie werden NICHT in die Bibliothek
    // kopiert — der Nutzer will sie nur hoeren. Liegen sie unterhalb des
    // Autoplay-Ordners, bekommen sie trotzdem dessen relative Titel-ID und sind
    // damit dieselben Titel wie die aus dem Ordner-Scan.
    private func handleDroppedURLs(_ urls: [URL]) {
        loadLog.info("handleDroppedURLs: \(urls.count, privacy: .public) Eingabe-URL(s)")
        self.errorMessage = nil

        let (sidFiles, unreadable) = collectSIDURLs(from: urls)
        guard !sidFiles.isEmpty else {
            loadLog.error("handleDroppedURLs: keine .sid Dateien in der Eingabe gefunden")
            // Den unlesbaren Ast konkret nennen: „Keine .sid Dateien gefunden"
            // waere hier die falsche Auskunft.
            if let blocked = unreadable.first {
                self.errorMessage = "Keine .sid Dateien gefunden. Nicht lesbar: \(blocked)"
            } else {
                self.errorMessage = "Keine .sid Dateien gefunden."
            }
            return
        }
        // Der Pfad wird nur GEHASHT protokolliert: Er ist ein absoluter Pfad aus
        // der Sammlung des Nutzers und enthaelt damit dessen Benutzer- und
        // Ordnernamen. Das Unified Log wird gespeichert und weitergegeben,
        // `.public` haette diese Namen unmaskiert hinterlassen (Review-Fund
        // 2026-08-20). Zum Wiedererkennen zweier Meldungen reicht der Hash; den
        // wirklichen Pfad zeigt die Oberflaeche unten sowieso an, und die sieht
        // nur der Nutzer selbst.
        if let blocked = unreadable.first {
            loadLog.error("handleDroppedURLs: Ast nicht lesbar: \(blocked, privacy: .private(mask: .hash))")
        }
        loadLog.info("handleDroppedURLs: \(sidFiles.count, privacy: .public) .sid Datei(en) gefunden")

        // Duplikatpruefung und Aufnahme stehen im Core und sind dort getestet.
        let additions = playlist.append(sidFiles, root: library?.root)
        // Auch bei einer bereits geladenen Datei springt die Auswahl dorthin:
        // wer sie erneut hereinzieht, will sie hoeren.
        if let index = additions.firstIndex {
            loadTrack(index: index, autoplay: true)
        }

        // Die Teilscan-Warnung ERST JETZT setzen. `loadTrack` leert
        // `errorMessage` zu Beginn — vorher gesetzt, war die Meldung sofort
        // wieder weg, und die App spielte einen Titel, ohne zu sagen, dass Teile
        // des hereingezogenen Ordners ungelesen blieben (Review-Fund
        // 2026-08-20). Ein echter Ladefehler hat Vorrang und bleibt stehen.
        if let blocked = unreadable.first, self.errorMessage == nil {
            self.errorMessage = "Ein Ordner war nicht lesbar: \(blocked)"
        }
    }

    // Sammelt die .sid-Dateien aus einer gemischten Eingabe von Dateien und
    // Ordnern. Ordner werden rekursiv durchsucht — mit demselben Scan, den auch
    // die Bibliothek benutzt (`MusicLibrary.scanFolder`); vorher standen dafuer
    // zwei eigene Schleifen in dieser Datei.
    //
    // Sortiert wird natuerlich nach Dateiname ("Track2" vor "Track10"), damit
    // ein hereingezogener Ordner in derselben Ordnung erscheint wie die
    // Bibliothek.
    private func collectSIDURLs(from urls: [URL]) -> (urls: [URL], unreadable: [String]) {
        let fm = FileManager.default
        var found: [URL] = []
        var unreadable: [String] = []

        for url in urls {
            // codereview-ok: App nicht sandboxed -> security-scoped calls sind No-Op; latent falls je Sandbox aktiviert wird (2026-07-01)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // Teilergebnis UND Fehler getrennt: Ein einziger unlesbarer
                // Unterordner liess vorher auch alle bereits gefundenen,
                // LESBAREN Titel desselben Ordners verschwinden — die App
                // meldete dann „Keine .sid Dateien gefunden"
                // (Review-Fund 2026-08-17).
                let scan = try? MusicLibrary.scanFolderAllowingPartialResults(
                    url, fileManager: fm)
                if let scan {
                    found.append(contentsOf: scan.entries.map { $0.url(relativeTo: url) })
                    if let failure = scan.traversalError {
                        unreadable.append(failure.path)
                    }
                } else {
                    unreadable.append(url.path)
                }
            } else if SidFileType.matches(url) {
                found.append(url)
            }
        }

        return (found.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }, unreadable)
    }

    /// Probiert beim Start alle Playlist-Eintraege zyklisch. So blockiert weder
    /// ein kaputter gespeicherter Track noch ein kaputter erster Ordner-Eintrag
    /// die Wiedergabe der danach folgenden gueltigen Datei.
    @discardableResult
    private func loadFirstPlayableTrack(startingAt index: Int, autoplay: Bool) -> Bool {
        guard !playlist.isEmpty else { return false }
        let start = max(0, min(index, playlist.count - 1))
        for offset in 0..<playlist.count {
            let candidate = (start + offset) % playlist.count
            if loadTrack(index: candidate, autoplay: autoplay) { return true }
        }
        return false
    }

    /// Baut den Ordnerbaum abseits des Hauptthreads neu.
    ///
    /// Wie beim Bibliotheks-Abgleich entscheidet eine Generation, wer sein
    /// Ergebnis noch eintragen darf: Sonst ueberschriebe der Baum des
    /// gespeicherten Index den frisch gescannten, wenn er spaeter fertig wird.
    private func rebuildFolderTree(from entries: [MusicLibraryEntry]) {
        folderTreeTask?.cancel()
        folderTreeGeneration &+= 1
        let generation = folderTreeGeneration
        folderTreeTask = Task.detached(priority: .utility) {
            let tree = MusicLibrary.folderTree(for: entries)
            await MainActor.run {
                guard folderTreeGeneration == generation else { return }
                folderTreeTask = nil
                folderTree = tree
                folderTreeReady = true
            }
        }
    }

    /// Einen Ordner der Ordneransicht auf- oder zuklappen.
    private func toggleFolder(_ path: String) {
        if expandedFolders.contains(path) {
            expandedFolders.remove(path)
        } else {
            expandedFolders.insert(path)
        }
        saveExpandedFolders()
    }

    /// Alle Ordner aufklappen — bei einer HVSC sind das tausende Zeilen, aber
    /// die Liste laedt sie ohnehin nur bei Bedarf.
    private func expandAllFolders() {
        expandedFolders = LibraryOutline.allFolderPaths(of: folderTree)
        saveExpandedFolders()
    }

    private func collapseAllFolders() {
        expandedFolders.removeAll()
        saveExpandedFolders()
    }

    private func saveExpandedFolders() {
        UserDefaults.standard.set(expandedFolders.sorted(), forKey: MainView.expandedFoldersKey)
    }

    private func clearPlaylist() {
        coordinator.stop()
        cancelLengthEstimate()
        cancelLibraryScan()
        playlist.removeAll()
        folderTreeTask?.cancel()
        folderTreeTask = nil
        folderTreeGeneration &+= 1
        folderTree = MusicLibrary.folderTree(for: [])
        folderTreeReady = false
        collapseAllFolders()
        currentTrackIdx = -1
        errorMessage = nil
        // Songlaengen-Zustand des (nicht mehr vorhandenen) Tracks zuruecksetzen.
        currentMD5 = nil
        currentTrackLengths = nil
        computedLength = nil
    }

    // Start-Playlist aus dem Autoplay-Ordner aufbauen.
    //
    // Der Ordner ist in den Einstellungen (Cmd+,) konfigurierbar; ohne eigene
    // Auswahl gilt ~/Music/Vicious SID Player/. Er liegt AUSSERHALB des Repos und
    // wird nie mit ausgeliefert. Die Aufloesung steht testbar in
    // `AutoplayFolder.resolve`, der Scan in `MusicLibrary` — beide im Core.
    ///
    /// - Parameter restoreSession: nur beim allerersten Laden `true`. Beim
    ///   Wechsel des Ordners in den Einstellungen waere ein Fortsetzen falsch —
    ///   der Nutzer hat gerade eine ANDERE Sammlung gewaehlt und erwartet, dass
    ///   sie vorn beginnt.
    private func loadLocalAudioFolder(restoreSession: Bool = false) {
        let fm = FileManager.default
        guard let dir = AutoplayFolder.resolve(configuredPath: autoplayFolderPath, fm: fm) else { return }

        // Index und Caches gehoeren nicht in den Musikordner des Nutzers,
        // sondern nach "Application Support". Liefert das System den Ort nicht
        // (auf dem Mac praktisch ausgeschlossen), landet der Index im
        // temporaeren Verzeichnis: dann geht beim naechsten Start nur die
        // Abkuerzung verloren, gescannt wird ohnehin.
        let support = MusicLibraryLocation.support(fm: fm) ?? fm.temporaryDirectory
        let lib = MusicLibrary(root: dir,
                               supportDirectory: support,
                               fileManager: fm,
                               indexFileName: MusicLibrary.indexFileName(forRoot: dir))
        library = lib
        migrateStoredIDs(root: lib.root)

        // Zuerst der beim letzten Start gespeicherte Index: Er steht sofort, die
        // Liste ist damit ohne Wartezeit da und die Wiedergabe kann beginnen.
        // Beim allerersten Start gibt es ihn noch nicht — dann bleibt die Liste
        // leer, bis der Scan unten fertig ist.
        let stored = lib.entries
        playlist.setLibrary(stored, root: lib.root)
        rebuildFolderTree(from: stored)
        let startedFromStoredIndex = !playlist.isEmpty
        if startedFromStoredIndex {
            startInitialPlayback(restoreSession: restoreSession)
        }

        // Der Abgleich mit dem Dateisystem laeuft danach im Hintergrund und
        // zieht die Liste nach: neu hinzugekommene Dateien kommen dazu,
        // geloeschte verschwinden.
        refreshLibraryInBackground(lib,
                                   restoreSession: restoreSession,
                                   startPlaybackWhenDone: !startedFromStoredIndex)
    }

    /// Gleicht die Bibliothek abseits des Hauptthreads gegen das Dateisystem ab
    /// und zieht die Playlist danach nach.
    ///
    /// - Parameters:
    ///   - lib: die Bibliothek zur aktuellen Wurzel.
    ///   - restoreSession: ob die letzte Sitzung fortgesetzt werden soll (nur
    ///     beim allerersten Laden).
    ///   - startPlaybackWhenDone: `true`, wenn oben noch nichts gestartet werden
    ///     konnte, weil es keinen gespeicherten Index gab. Dann beginnt die
    ///     Wiedergabe mit dem Ergebnis dieses Scans.
    private func refreshLibraryInBackground(_ lib: MusicLibrary,
                                            restoreSession: Bool,
                                            startPlaybackWhenDone: Bool) {
        // Ein noch laufender Scan gehoert zu einer aelteren Wurzel oder ist
        // durch diesen Aufruf ueberholt: abbestellen. Der Scan selbst laesst
        // sich nicht mittendrin anhalten (`MusicLibrary.refresh` liest das
        // Dateisystem am Stueck); die Generation sorgt dafuer, dass sein
        // Ergebnis nichts mehr ueberschreibt.
        libraryScanTask?.cancel()
        libraryScanGeneration &+= 1
        let generation = libraryScanGeneration
        isScanningLibrary = true
        loadLog.info("Bibliotheks-Abgleich gestartet (Generation \(generation, privacy: .public))")
        libraryScanTask = Task.detached(priority: .utility) {
            // Scheitert der Abgleich (Ordner verschwunden, Netzlaufwerk
            // offline), bleibt der zuletzt gespeicherte Index dieser Wurzel
            // stehen — besser eine bekannte Liste als gar keine.
            do {
                _ = try lib.refresh()
            } catch {
                loadLog.error("Bibliotheks-Scan fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            }
            let entries = lib.entries
            await MainActor.run {
                guard libraryScanGeneration == generation else { return }
                libraryScanTask = nil
                isScanningLibrary = false
                applyScannedLibrary(entries,
                                    root: lib.root,
                                    restoreSession: restoreSession,
                                    startPlayback: startPlaybackWhenDone)
            }
        }
    }

    /// Traegt das Scan-Ergebnis in die Playlist ein.
    ///
    /// Der laufende Titel behaelt seine Position nicht: Die Liste wird neu
    /// sortiert. Ihn ueber seine stabile ID wiederzufinden, ist Sache des Cores
    /// (`Playlist.setLibrary(_:root:keepingTrackAt:)`) und dort getestet.
    @MainActor
    private func applyScannedLibrary(_ entries: [MusicLibraryEntry],
                                     root: URL,
                                     restoreSession: Bool,
                                     startPlayback: Bool) {
        currentTrackIdx = playlist.setLibrary(entries,
                                              root: root,
                                              keepingTrackAt: currentTrackIdx)
        rebuildFolderTree(from: entries)
        loadLog.info("Bibliotheks-Abgleich fertig: \(entries.count, privacy: .public) Titel")
        if startPlayback, !playlist.isEmpty {
            startInitialPlayback(restoreSession: restoreSession)
        }
        // Ein waehrend des Scans eingegangener `track`-Befehl gewinnt gegen die
        // wiederhergestellte Sitzung: Der Nutzer hat ihn gerade erst geschickt.
        if let id = pendingTrackCommandID {
            pendingTrackCommandID = nil
            if let index = playlist.index(forID: id) {
                selectTrack(at: index)
            } else {
                loadLog.error("Fernsteuerung: Titel auch nach dem Scan nicht in der Liste (\(id, privacy: .private(mask: .hash)))")
            }
        }
    }

    /// Bricht einen laufenden Bibliotheks-Abgleich ab und macht sein Ergebnis
    /// ungueltig. Noetig ueberall dort, wo die Liste bewusst geleert oder neu
    /// aufgebaut wird — sonst fuellte der spaeter fertig werdende Scan sie
    /// wieder auf, obwohl der Nutzer gerade auf den Papierkorb geklickt hat.
    private func cancelLibraryScan() {
        libraryScanTask?.cancel()
        libraryScanTask = nil
        libraryScanGeneration &+= 1
        isScanningLibrary = false
        // Der zurueckgestellte Fernsteuerbefehl wartete auf genau dieses
        // Scan-Ergebnis. Ohne den Scan gibt es nichts mehr, worauf er warten
        // koennte — er darf nicht in einer spaeteren, anderen Liste zuschlagen.
        pendingTrackCommandID = nil
    }

    // Womit die App nach dem Aufbau der Start-Playlist beginnt.
    //
    // Ohne Shuffle wird die letzte Sitzung fortgesetzt (Titel, Subtune,
    // Position), sofern der Titel noch da ist. Mit Shuffle beginnt jeder Start
    // bewusst zufaellig — deshalb wird dann gar nicht wiederhergestellt.
    private func startInitialPlayback(restoreSession: Bool) {
        if restoreSession, !shuffle, let id = restoredTrackID(), let restoreIdx = playlist.index(forID: id) {
            let sub = lastSubtune
            let pos = lastPosition
            if loadTrack(index: restoreIdx, autoplay: true) {
                // Nach setSid ist subtunesCount gesetzt -> Subtune/Position gezielt
                // wiederherstellen (setSubtune prueft den Bereich selbst).
                if sub > 0 { coordinator.setSubtune(sub: sub) }
                if pos > 1.0 { coordinator.seek(seconds: pos) }
                resolveComputedLengthIfNeeded()
                loadLog.info("Session-Restore: \(id, privacy: .public), Subtune \(sub, privacy: .public), Position \(Int(pos), privacy: .public) s")
                return
            }
            loadLog.error("Session-Restore fehlgeschlagen; starte mit einem anderen lesbaren Playlist-Eintrag")
        }

        // Beim Start mit aktiver Zufallswiedergabe einen zufaelligen statt des
        // ersten Titels — so beginnt jeder App-Start mit einem anderen Song.
        let start = (restoreSession && shuffle && playlist.count > 1)
            ? Int.random(in: 0..<playlist.count)
            : 0
        loadFirstPlayableTrack(startingAt: start, autoplay: true)
    }

    // Der gespeicherte Titel der letzten Sitzung, auf die aktuelle Wurzel
    // umgerechnet (frueher stand hier ein absoluter Pfad).
    private func restoredTrackID() -> String? {
        guard !lastTrackPath.isEmpty else { return nil }
        return PlaylistTrackID.migrate(lastTrackPath, root: library?.root)
    }

    // Rechnet die gespeicherten absoluten Pfade auf relative Titel-IDs um,
    // sobald die Bibliothekswurzel feststeht.
    //
    // Ohne diesen Schritt waeren nach dem Umbau alle Favoriten wertlos: sie
    // stehen als absolute Pfade in den Einstellungen, die Titel heissen jetzt
    // relativ zum Autoplay-Ordner. Die Umrechnung ist mehrfach anwendbar, ein
    // spaeterer Start findet also nichts mehr zu tun.
    private func migrateStoredIDs(root: URL) {
        let key = PlaylistFavorites.userDefaultsKey
        let stored = UserDefaults.standard.stringArray(forKey: key) ?? []
        let migrated = PlaylistFavorites(storedValues: stored, root: root)
        favorites = migrated
        if migrated.storageValue != stored.sorted() {
            UserDefaults.standard.set(migrated.storageValue, forKey: key)
            loadLog.info("Favoriten auf relative Pfade umgestellt: \(migrated.storageValue.count, privacy: .public)")
        }

        if !lastTrackPath.isEmpty {
            lastTrackPath = PlaylistTrackID.migrate(lastTrackPath, root: root)
        }
    }

    // Favorit an/aus fuer einen Titel (persistent ueber seine stabile ID).
    private func toggleFavorite(at index: Int) {
        guard let track = playlist.track(at: index) else { return }
        favorites.toggle(track.id)
        UserDefaults.standard.set(favorites.storageValue, forKey: PlaylistFavorites.userDefaultsKey)
    }

    // Sichert den Wiedergabe-Stand fuer den naechsten App-Start (Session-Restore).
    private func saveSessionState() {
        guard let track = playlist.track(at: currentTrackIdx) else { return }
        lastTrackPath = track.id
        lastSubtune = coordinator.currentSubtune
        lastPosition = coordinator.elapsedSeconds
    }

    // Laedt die Songlengths.md5 im Hintergrund: konfigurierter Pfad aus den
    // Einstellungen oder Auto-Fund (DOCUMENTS/Songlengths.md5 im/ueber dem
    // Autoplay-Ordner). Danach die Laengen des aktuellen Tracks nachziehen.
    private func loadSonglengthDB() {
        songlengthLoadTask?.cancel()
        songlengthLoadGeneration &+= 1
        let generation = songlengthLoadGeneration
        let configured = songlengthsPath
        let autoplayPath = autoplayFolderPath
        songlengthLoadTask = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let fm = FileManager.default
                let url: URL?
                if !configured.isEmpty {
                    url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
                } else {
                    let folder = AutoplayFolder.resolve(configuredPath: autoplayPath, fm: fm)
                    url = folder.flatMap { SonglengthDB.autodetect(nearFolder: $0, fm: fm) }
                }
                let db: SonglengthDB?
                if let url {
                    db = try? SonglengthDB.loadCancellable(url: url)
                } else {
                    db = nil
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard songlengthLoadGeneration == generation else { return }
                    songlengthLoadTask = nil
                    songlengthDB = db
                    if let md5 = currentMD5 {
                        currentTrackLengths = db?.lengths(forMD5: md5)
                        resolveComputedLengthIfNeeded()
                    }
                    if let db { loadLog.info("Songlengths-DB geladen: \(db.count, privacy: .public) Eintraege") }
                }
            } catch is CancellationError {
                // Erwartet bei Pfad-/Autoplay-Wechsel; die neuere Generation ist
                // bereits unterwegs und allein schreibberechtigt.
            } catch {
                await MainActor.run {
                    if songlengthLoadGeneration == generation {
                        songlengthLoadTask = nil
                    }
                }
            }
        }
    }

    // Laedt die STIL.txt im Hintergrund: konfigurierter Pfad aus den
    // Einstellungen oder Auto-Fund (DOCUMENTS/STIL.txt im/ueber dem
    // Autoplay-Ordner). Die echte Datei der HVSC hat ueber 200.000 Zeilen —
    // im Hauptthread geparst stuende die Oberflaeche dabei.
    //
    // Aufgebaut wie `loadSonglengthDB`: genau ein Task, und eine Generation
    // entscheidet, wer sein Ergebnis noch eintragen darf. Ohne sie ueberschriebe
    // ein langsames altes Laden die inzwischen gewaehlte Datei.
    private func loadSTIL() {
        stilLoadTask?.cancel()
        stilLoadGeneration &+= 1
        let generation = stilLoadGeneration
        let configured = stilPath
        let autoplayPath = autoplayFolderPath
        stilLoadTask = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                let fm = FileManager.default
                let url: URL?
                if !configured.isEmpty {
                    url = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
                } else {
                    let folder = AutoplayFolder.resolve(configuredPath: autoplayPath, fm: fm)
                    url = folder.flatMap { STILDatabase.autodetect(nearFolder: $0, fm: fm) }
                }
                let db: STILDatabase?
                if let url {
                    db = try? STILDatabase.loadCancellable(url: url)
                } else {
                    db = nil
                }
                try Task.checkCancellation()
                let root = url.map { STILDatabase.hvscRoot(forSTILFile: $0) }
                await MainActor.run {
                    guard stilLoadGeneration == generation else { return }
                    stilLoadTask = nil
                    stilDB = db
                    stilRoot = db == nil ? nil : root
                    if let db {
                        loadLog.info("STIL geladen: \(db.count, privacy: .public) Titel, \(db.folderCount, privacy: .public) Ordner")
                    }
                }
            } catch is CancellationError {
                // Erwartet bei Pfad-/Autoplay-Wechsel; die neuere Generation ist
                // bereits unterwegs und allein schreibberechtigt.
            } catch {
                await MainActor.run {
                    if stilLoadGeneration == generation { stilLoadTask = nil }
                }
            }
        }
    }

    // Berechnete Laenge fuer den aktuellen Track/Subtune aufloesen, falls die
    // HVSC-DB nichts liefert. Welche Quelle in welcher Reihenfolge gilt, steht
    // im Core; hier bleibt nur das Starten und Aufraeumen des Hintergrund-Tasks.
    private func resolveComputedLengthIfNeeded() {
        computedLength = nil
        switch lengthResolver.plan(md5: currentMD5,
                                   subtune: coordinator.currentSubtune,
                                   databaseLengths: currentTrackLengths,
                                   fileURL: playlist.track(at: currentTrackIdx)?.url) {
        case .databaseProvidesLength, .noLengthKnown:
            // Nichts zu rechnen. Eine ueberfluessig gewordene Rechnung hat der
            // Resolver bereits entwertet — der Task hier gehoert noch abgeraeumt.
            lengthEstimateTask?.cancel()
            lengthEstimateTask = nil
        case .trackNotReady, .alreadyRunning:
            // Titelwechsel noch nicht abgeschlossen, oder genau diese Analyse
            // laeuft bereits: in beiden Faellen nichts anfassen.
            break
        case .cached(let seconds):
            lengthEstimateTask?.cancel()
            lengthEstimateTask = nil
            computedLength = seconds
        case .estimate(let ticket):
            lengthEstimateTask?.cancel()
            lengthEstimateOwner = ticket
            lengthEstimateTask = startLengthEstimate(ticket)
        }
    }

    // Startet die Hintergrund-Berechnung. Sie laeuft schneller als Echtzeit; das
    // Ergebnis nimmt der Resolver entgegen und sagt, ob es noch zum laufenden
    // Titel passt.
    private func startLengthEstimate(_ ticket: SongLengthEstimateTicket) -> Task<Void, Never> {
        let resolver = lengthResolver
        return Task.detached(priority: .utility) {
            do {
                let result = try resolver.runEstimate(ticket: ticket)
                await MainActor.run {
                    // NUR den eigenen, noch aktuellen Griff leeren.
                    releaseLengthEstimateHandle(ticket)
                    if let accepted = resolver.accept(result,
                                                      ticket: ticket,
                                                      currentMD5: currentMD5,
                                                      currentSubtune: coordinator.currentSubtune) {
                        computedLength = accepted
                    }
                }
            } catch is CancellationError {
                // Track/Subtune wurde gewechselt. Der Resolver cached fuer eine
                // absichtlich abgebrochene Analyse bewusst nichts.
            } catch {
                await MainActor.run {
                    releaseLengthEstimateHandle(ticket)
                    resolver.fail(ticket: ticket)
                }
            }
        }
    }

    /// Den Griff freigeben, wenn er noch diesem Ticket gehoert.
    private func releaseLengthEstimateHandle(_ ticket: SongLengthEstimateTicket) {
        guard lengthEstimateOwner == ticket else { return }
        lengthEstimateOwner = nil
        lengthEstimateTask = nil
    }

    private func cancelLengthEstimate() {
        lengthEstimateTask?.cancel()
        lengthEstimateTask = nil
        lengthEstimateOwner = nil
        lengthResolver.cancel()
    }

    // Die Rechnung steht im Core (`PlaytimeFormat`) — iPhone-App und
    // Quick-Look-Vorschau zeigen dieselbe Spielzeit an. Frueher stand hier eine
    // eigene, schwaechere Fassung: sie liess negative Zwischenwerte des
    // Positionsreglers als "0:-5" durch und kannte keine Stunden.
    private func formatTime(_ sec: Double) -> String {
        PlaytimeFormat.string(sec)
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
                playNextTrack()
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
                playPreviousTrack()
            }
        }
        // Cmd+T schaltet FEST auf das jeweils andere Theme um (verlaesst also den
        // Auto-Modus) — Basis ist das gerade sichtbare Theme. Zurueck zu "Auto"
        // geht ueber die Einstellungen (Cmd+,).
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuToggleMiniPlayer"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { toggleMiniPlayer() }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuToggleTheme"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                themeModeRaw = (theme == .light ? ThemeMode.dark : ThemeMode.light).rawValue
            }
        }
        // System-Wechsel Hell/Dunkel (macOS-Einstellungen): verteilte Notification,
        // damit der Auto-Modus live folgt, ohne dass die App neu starten muss.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                systemPrefersDark = MainView.systemInterfaceIsDark()
            }
        }
        // WAV-Export des aktuellen Tracks (Menue "Wiedergabe" -> Cmd+E).
        NotificationCenter.default.addObserver(forName: NSNotification.Name("menuExportWAV"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                exportCurrentTrackAsWAV()
            }
        }
        // Doppelklick / "Oeffnen mit" bei bereits laufender App (Warmstart).
        NotificationCenter.default.addObserver(forName: NSNotification.Name("remoteCommands"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { drainPendingRemoteCommands() }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("openSIDFiles"), object: nil, queue: .main) { _ in
            Task { @MainActor in
                drainPendingOpenURLs()
            }
        }
        #if canImport(AppKit)
        // Beim Beenden den letzten Stand fuer den naechsten Start sichern
        // (Session-Restore) — zusaetzlich zur laufenden 5-s-Drosselung.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                saveSessionState()
            }
        }
        #endif
    }

    // Exportiert den aktuellen Track (aktueller Subtune, aktuelles SID-Modell)
    // als WAV-Datei — Ziel via Save-Panel, Render im Hintergrund (schneller als
    // Echtzeit, WavRenderer im Core). Dauer = SCRUB_MAX, wie der Scrubber.
    private func exportCurrentTrackAsWAV() {
        guard let fileURL = playlist.track(at: currentTrackIdx)?.url else {
            errorMessage = "Kein Track für den WAV-Export ausgewählt."
            return
        }
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + ".wav"
        panel.message = "Aktuellen Song als WAV exportieren (Subtune \(coordinator.currentSubtune + 1))"
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let subtune = coordinator.currentSubtune
        let model = coordinator.modelOverride
        // Echte Songlaenge, wenn bekannt — sonst das Standard-Limit.
        let seconds = currentDuration
        errorMessage = nil
        // Render abseits des Main-Threads — ein 6-min-Tune braucht nur Sekunden,
        // soll die UI aber trotzdem nicht blockieren.
        Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: fileURL)
                let sid = try SidParser.parse(data: data)
                try WavRenderer.render(sidFile: sid, subtune: subtune, seconds: seconds,
                                       modelOverride: model, to: dest)
                await MainActor.run {
                    // Fertige Datei im Finder zeigen (erwartetes Export-Feedback).
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                await MainActor.run {
                    errorMessage = "WAV-Export fehlgeschlagen: \(error.localizedDescription)"
                }
            }
        }
        #endif
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
            MPMediaItemPropertyPlaybackDuration: currentDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: coordinator.elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: coordinator.isPlaying ? 1.0 : 0.0
        ]
        infoCenter.playbackState = coordinator.isPlaying ? .playing : (coordinator.isPaused ? .paused : .stopped)
    }

    // Zieht die vom AppDelegate gepufferten Open-URLs und laedt sie wie ein Drop.
    /// Arbeitet die per URL-Schema hereingereichten Fernsteuerbefehle ab.
    ///
    /// Geprueft sind sie schon (`RemoteCommand.parse` im Core) — hier bleibt nur
    /// das Ausfuehren. Was das Schema kann und was bewusst nicht, steht dort.
    private func drainPendingRemoteCommands() {
        let commands = AppDelegate.pendingCommands
        AppDelegate.pendingCommands = []
        guard !commands.isEmpty else { return }
        loadLog.info("Fernsteuerung: \(commands.count, privacy: .public) Befehl(e)")
        for command in commands { perform(command) }
    }

    private func perform(_ command: RemoteCommand) {
        switch command {
        case .play:
            if !coordinator.isPlaying { togglePlayPause() }
        case .pause:
            if coordinator.isPlaying { togglePlayPause() }
        case .playPause:
            togglePlayPause()
        case .stop:
            coordinator.stop()
        case .next:
            playNextTrack()
        case .previous:
            playPreviousTrack()
        case .seek(let seconds):
            // Nicht ueber das Ende hinaus: Der Positionsregler kennt dieselbe
            // Grenze, und ein Sprung dahinter liesse den Titel sofort enden.
            coordinator.seek(seconds: min(seconds, currentDuration))
        case .subtune(let index):
            // setSubtune prueft den Bereich gegen die Datei selbst.
            coordinator.setSubtune(sub: index)
            resolveComputedLengthIfNeeded()
        case .track(let id):
            // Nur was wirklich in der Liste steht. Ein unbekannter Pfad wird
            // ignoriert statt geraten — es sei denn, der erste Bibliotheks-Scan
            // laeuft noch. Die Entscheidung selbst steht im Core und ist dort
            // getestet.
            switch RemoteCommand.resolveTrack(index: playlist.index(forID: id),
                                              isScanningLibrary: isScanningLibrary) {
            case .select(let index):
                pendingTrackCommandID = nil
                selectTrack(at: index)
            case .deferUntilScanFinished:
                pendingTrackCommandID = id
                loadLog.info("Fernsteuerung: Titel wird nach dem Bibliotheks-Scan erneut gesucht")
            case .unknown:
                loadLog.error("Fernsteuerung: Titel nicht in der Liste (\(id, privacy: .private(mask: .hash)))")
            }
        }
    }

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
// Die Titelliste der Seitenleiste.
//
// Sie ist aus zwei Gruenden eine EIGENE Ansicht und kennt den Koordinator
// bewusst nicht:
//
//  1. Der Koordinator schickt 50-mal je Sekunde neue Anzeigewerte (Huellkurven,
//     Frequenzen, Spielzeit). Stuende die Liste weiter im Rumpf von `MainView`,
//     baute SwiftUI sie in diesem Takt mit auf. Bei 50.000 Titeln lief dabei ein
//     Prozessorkern voll. `Equatable` plus der Aenderungszaehler der Playlist
//     entscheiden jetzt in wenigen Vergleichen, dass sich nichts geaendert hat.
//  2. `LazyVStack` statt `VStack`: Ein VStack baut jede Zeile sofort auf, auch
//     die 49.000, die niemand sieht. Bei 50.001 Titeln sprengte das den
//     Ansichtsaufbau von SwiftUI, und die App brach beim Start mit "abort()"
//     ab — am 2026-08-23 dreimal reproduziert. Gemessen wurde am selben Tag
//     auch die Alternative `List` (auf macOS eine NSTableView): Sie stuerzt
//     zwar nicht ab, legt die Zeilen aber trotzdem alle an — 804 MB gegen
//     362 MB beim LazyVStack, bei rund 20 Prozentpunkten mehr Prozessorlast.
//
// Die Auswahl arbeitet weiter mit Positionen in der VOLLEN Liste: Suche und
// Favoritenfilter aendern nur, was zu sehen ist, nicht was gespielt wird.
struct TrackListView: View {
    let playlist: Playlist
    let currentTrackIdx: Int
    let searchText: String
    let favoritesOnly: Bool
    let favorites: PlaylistFavorites
    let isLight: Bool
    /// Ordneransicht statt flacher Liste.
    let showTree: Bool
    /// Der Ordnerbaum der Bibliothek. Wird nur in der Ordneransicht gebraucht
    /// und aendert sich nur mit dem Bibliotheks-Abgleich.
    let folderTree: MusicLibraryFolder
    /// Pfade der aufgeklappten Ordner.
    let expandedFolders: Set<String>
    let onSelect: (Int) -> Void
    let onToggleFavorite: (Int) -> Void
    let onToggleFolder: (String) -> Void

    // Bewusst NICHT `Equatable` mit `.equatable()`: Der Versuch, den Neuaufbau
    // der Liste damit zu ueberspringen, hat die Seitenleiste zeitweise leer
    // stehen lassen — SwiftUI zeigte den alten, noch leeren Stand weiter
    // (2026-08-23). Gemessen hat die Abkuerzung ohnehin nichts gebracht: mit
    // und ohne sie liegt die App bei 50.001 Titeln gleichauf, auch mit ganz
    // aufgeklapptem Baum (386 MB, rund 50 Prozent Prozessorlast — das ist die
    // Grundlast der Emulation).

    private var visibleIndices: [Int] {
        playlist.visibleIndices(searchText: searchText,
                                favoritesOnly: favoritesOnly,
                                favorites: favorites)
    }

    /// Die Ordneransicht gilt nur fuer die ungefilterte Bibliothek. Sobald
    /// gesucht oder auf Favoriten eingeschraenkt wird, ist die flache Liste die
    /// richtige Antwort: Der Nutzer will die Treffer sehen, nicht die Ordner,
    /// in denen sie liegen.
    private var showsTreeNow: Bool {
        showTree && searchText.trimmingCharacters(in: .whitespaces).isEmpty && !favoritesOnly
    }

    var body: some View {
        let textCol = isLight ? Color.macLightText : Color.macDarkText
        let textSecCol = isLight ? Color.macLightSecondary : Color.macDarkSecondary
        let accentCol = isLight ? Color.macLightAccent : Color.macDarkAccent
        let surfaceCol = isLight ? Color.macLightSurface : Color.macDarkSurface

        ScrollView {
            LazyVStack(spacing: 2) {
                if showsTreeNow {
                    // Position in der Playlist je Titel-ID. Einmal je
                    // Neuaufbau der Ansicht gebaut: Die Playlist einzeln zu
                    // durchsuchen waere bei 50.000 Titeln je Zeile ein
                    // Durchlauf durch die ganze Liste.
                    let indexByID = Dictionary(playlist.tracks.enumerated().map { ($1.id, $0) },
                                               uniquingKeysWith: { first, _ in first })
                    ForEach(LibraryOutline.rows(of: folderTree, expanded: expandedFolders)) { item in
                        outlineRow(item,
                                   indexByID: indexByID,
                                   textCol: textCol,
                                   textSecCol: textSecCol,
                                   accentCol: accentCol)
                    }
                } else {
                    ForEach(visibleIndices, id: \.self) { idx in
                        row(idx, textCol: textCol, textSecCol: textSecCol, accentCol: accentCol)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(surfaceCol)
    }

    // Eine Zeile der Ordneransicht: Ordner zum Auf- und Zuklappen, oder ein
    // Titel — dann dieselbe Zeile wie in der flachen Liste, nur eingerueckt.
    @ViewBuilder
    private func outlineRow(_ item: LibraryOutlineItem,
                            indexByID: [String: Int],
                            textCol: Color,
                            textSecCol: Color,
                            accentCol: Color) -> some View {
        switch item {
        case .folder(let folder):
            Button(action: { onToggleFolder(folder.path) }) {
                HStack(spacing: 6) {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(folder.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(folder.trackCount)")
                        .font(.system(size: 10))
                        .foregroundColor(textSecCol)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(textCol)
            .padding(.leading, CGFloat(folder.depth) * 12)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .help(folder.path)

        case .track(let track):
            // Ein Titel, den die Playlist (noch) nicht kennt, wird nicht
            // gezeigt: Anklicken koennte man ihn ohnehin nicht.
            if let idx = indexByID[track.relativePath] {
                row(idx, textCol: textCol, textSecCol: textSecCol, accentCol: accentCol)
                    .padding(.leading, CGFloat(track.depth) * 12)
            }
        }
    }

    // Zeile = Auswahl-Button + separater Stern-Button (Favorit an/aus), beide
    // auf gemeinsamem Hintergrund.
    @ViewBuilder
    private func row(_ idx: Int,
                     textCol: Color,
                     textSecCol: Color,
                     accentCol: Color) -> some View {
        if let track = playlist.track(at: idx) {
            let isActive = idx == currentTrackIdx
            let isFavorite = favorites.contains(track.id)

            HStack(spacing: 4) {
                Button(action: { onSelect(idx) }) {
                    HStack(spacing: 8) {
                        Image(systemName: isActive ? "play.circle.fill" : "music.note")
                            .font(.system(size: 12))
                        Text(track.name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                // Der Ordner steht im Tooltip statt in einer zweiten Zeile: in
                // einer nach Komponisten sortierten Sammlung gibt es denselben
                // Dateinamen mehrfach, und die Seitenleiste ist zu schmal fuer
                // beides.
                .help(track.folderPath.isEmpty ? track.name : "\(track.folderPath)/\(track.name)")

                Button(action: { onToggleFavorite(idx) }) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 10))
                        .foregroundColor(isFavorite
                                         ? .yellow
                                         : (isActive ? .white : textSecCol.opacity(0.45)))
                }
                .buttonStyle(PlainButtonStyle())
                .help(isFavorite ? "Favorit entfernen" : "Als Favorit markieren")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? accentCol : Color.clear)
            .foregroundColor(isActive ? .white : textCol)
            .cornerRadius(6)
        }
    }
}

/// Reicht das AppKit-Fenster nach oben, in dem diese Ansicht haengt.
///
/// Gebraucht wird das, weil SwiftUI die Fenstergroesse nicht selbst umstellen
/// kann: Der Wechsel in den Mini-Player zieht das Fenster zusammen. Das Fenster
/// zu ERRATEN (etwa `NSApp.windows.first`) waere bruechig — Einstellungen und
/// Panels sind auch Fenster.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Beim Erzeugen haengt die Ansicht noch in keinem Fenster — deshalb
        // einen Durchlauf spaeter nachsehen.
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onWindow(window) }
        }
    }
}

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

// Ziehbarer vertikaler Trenn-Handle für die Playlist-Sidebar-Breite.
struct SidebarSplitter: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double
    let borderCol: Color

    @State private var startValue: Double? = nil

    var body: some View {
        let thickness: CGFloat = 1
        let hitSize: CGFloat = 11

        ZStack {
            Rectangle()
                .fill(borderCol)
                .frame(width: thickness)
        }
        .frame(width: hitSize)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = startValue ?? width
                    if startValue == nil { startValue = width }
                    let raw = Double(value.translation.width)
                    width = min(range.upperBound, max(range.lowerBound, base + raw))
                }
                .onEnded { _ in startValue = nil }
        )
        .onTapGesture(count: 2) {
            width = defaultWidth
        }
        .onContinuousHover { phase in
            #if canImport(AppKit)
            switch phase {
            case .active:
                NSCursor.resizeLeftRight.set()
            case .ended:
                NSCursor.arrow.set()
            }
            #endif
        }
        .help("Ziehen, um die Playlist-Breite anzupassen (Doppelklick zum Zurücksetzen)")
        .frame(width: thickness)
    }
}
