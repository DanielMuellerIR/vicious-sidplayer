# AGENTS.md — Vicious SID Player

Universelle Referenz und Dokumentation für alle Coding-Agents und KI-Modelle.

> **Projektname:** Vicious SID Player (Anspielung auf Sid Vicious)
> **Status:** v1.3.1 — HTML5 + native macOS SwiftUI App inkl. Quick-Look-Extension, Shuffle, Media-Tasten, Einstellungen-Dialog (Autoplay-Ordner).

---

## Typ & Zweck
- **Typ:** GUI-App
- **Zweck:** C64-SID-Musikplayer als native SwiftUI-macOS-App (mit Quick-Look) und als Single-File-HTML5-Web-App.
- **Plattform:** macOS-GUI (+ Web)

## Projektüberblick

Dieses Projekt ist ein eigenständiger C64 SID-Musikplayer in zwei Varianten:
1. **Single-File HTML5 (`vicious-sid-player.html`)**: Funktioniert ohne Webserver über `file://`, per Drag & Drop (Dateien & Ordner).
2. **Native macOS App (`Vicious SID Player.app`)**: SwiftUI-Desktop-Anwendung mit `AVAudioEngine`, Echtzeit-Oszilloskop, Dark/Light Mode.

Keine SID-Dateien werden gebundelt (Copyright). Die App scannt bei Start ein lokales `audio/`-Verzeichnis und zeigt gefundene SIDs in der Playlist.

---

## Dateilayout

```
p_sidplayer/
├── .gitignore
├── AGENTS.md                 ← diese Datei
├── VERSION                   ← Versionsnummer
├── LICENSE                   ← WTFPL
├── README.md                 ← GitHub-README (englisch, Standardfassung)
├── README.de.md              ← GitHub-README (deutsch)
├── vicious-sid-player.html    ← fertiger Single-File-Build (generiert, gitignored)
├── sidplayer.js              ← Client-seitiger SID-Player-Wrapper
├── sid-player-worklet.js     ← AudioWorklet-Prozessor (C64 CPU & SID Core)
├── build.py                  ← Bündelungs- und Minifizierungs-Skript
├── build_app.sh              ← Shell-Skript für macOS App-Bundle
├── build_dmg.sh              ← Shell-Skript für Retina-DMG
├── Package.swift             ← Swift Package Manager Manifest
├── audio/                    ← Lokale SID-Dateien (gitignored, nur zum Testen)
├── src/                      ← HTML5-Quellen
│   ├── styles.css            ← CSS (Themes: macOS Light & Dark)
│   ├── body.html             ← HTML-Layout
│   ├── app.js                ← Main Browser Controller & Drag-Drop-Logik
│   ├── AppIcon.png           ← App-Icon (1024×1024 PNG, C64-Floppy + Waveform)
│   └── DmgBackground.png     ← DMG-Hintergrundbild
├── Sources/
│   ├── ViciousSIDPlayerCore/
│   │   ├── Parser/
│   │   │   └── SidParser.swift
│   │   ├── AutoplayFolder.swift            ← Autoplay-Ordner-Auflösung (testbar)
│   │   └── DSP/
│   │       ├── ViciousProcessor.swift      ← C64 CPU + SID Emulator (Swift)
│   │       └── ViciousCoordinator.swift    ← AVAudioEngine Host
│   ├── ViciousSIDPlayerApp/
│   │   ├── AppMain.swift
│   │   └── UI/
│   │       ├── Theme.swift
│   │       ├── SettingsView.swift          ← Einstellungen (Cmd+,): Autoplay-Ordner
│   │       ├── MainView.swift
│   │       └── OscilloscopeView.swift
│   └── ViciousSIDQuickLook/
│       ├── main.swift                  ← Dummy (Einstieg ist NSExtensionMain)
│       └── PreviewViewController.swift ← Quick-Look-Preview: Autoplay + Metadaten
└── Tests/
    └── ViciousSIDPlayerTests/
        └── ViciousTests.swift
```

---

## Tech-Stack

```
HTML5:      Vanilla JS, AudioWorklet, CSS Custom Properties (Dark/Light)
Swift:      Swift 6, AVAudioEngine + AVAudioSourceNode, SwiftUI
Build:      Python 3 (HTML), swift build (App), bash (DMG)
Audio:      SID+6502-Emulation portiert aus jsSID 0.9.1 (Hermit, WTFPL)
```

---

## Build-Befehle

```bash
# HTML5 Player
python3 build.py                  # → vicious-sid-player.html (~50 KB)
python3 build.py --no-min         # unminifiziert

# macOS App
bash build_app.sh                 # → "Vicious SID Player.app"

# DMG (Retina-TIFF-Background)
bash build_dmg.sh                 # → build/Vicious SID Player.dmg
bash build_dmg.sh --notarize      # DMG signieren, notarisieren und stapeln

# Tests
swift test
```

---

## Architektur-Kernpunkte

**SID-Emulation:** Portiert aus jsSID 0.9.1 mit Bugfixes:
- 6502-Opcode-Maske `IR & 0xF0` statt `IR & 0xC0` (INX/TAY/PHP/PLP)
- AudioWorklet-Engine als Plain Class (kein `extends AudioWorkletProcessor`)
- Noise-Waveform + ENV3-Readback korrigiert

**Keine gebundelten SIDs:** Copyright-geschützte SID-Dateien werden nicht im Repo oder in Builds mitgeliefert. Die App baut ihre Start-Playlist aus einem konfigurierbaren Autoplay-Ordner (rekursiv, persönliche Sammlung außerhalb des Repos): wählbar im Einstellungen-Dialog (Cmd+,, `SettingsView.swift`, UserDefaults-Key `autoplayFolderPath`), Default `~/Music/Vicious SID Player/`. Auflösungslogik testbar in `AutoplayFolder.resolve` (Core); Laden via `loadLocalAudioFolder()`/`collectSIDs()` in `MainView.swift`. Eine Änderung in den Einstellungen lädt die Playlist sofort neu.

**Wiedergabe-Zustandsmaschine (Coordinator):** `play()` baut den Processor neu ODER setzt nach `pause()` fort (Engine via `audioEngine.pause()`/`start()`, Emulations-Stand bleibt erhalten). `stop()` baut alles ab und setzt an den Anfang zurück. `seek()` springt bei aktivem Processor direkt, sonst wird die Zielposition in `pendingSeekSeconds` gepuffert und beim nächsten `play()` angewandt (Seek im gestoppten Zustand). Der UI-/Visualizer-Timer läuft im `.common`-RunLoop-Modus, damit das Oszilloskop auch während eines Slider-Drags weiterläuft.

**Zufallswiedergabe:** Toggle neben dem Play-Button; Zustand in `@AppStorage("shuffleEnabled")` (UserDefaults, persistent). Bei aktivem Shuffle wählt `advanceTrackIndex()` einen zufälligen Track (Auto-Next + Nächster-Titel), und beim App-Start (`handleDroppedURLs(isStartupLoad:)`) startet ein zufälliger Song.

**Media-Tasten / Now Playing:** Die App registriert sich via `MPRemoteCommandCenter` (Play/Pause/Stop, Titel vor/zurück → F7/F8/F9, Touch Bar, AirPods) und meldet Titel/Position an `MPNowPlayingInfoCenter` (`setupMediaRemoteCommands()`/`updateNowPlayingInfo()`). Die Remote-Kommandos posten dieselben Notifications wie die Menüpunkte. Erfordert ein echtes `.app`-Bundle (nicht das nackte `swift run`-Binary).

**App-Appearance:** fest ans Theme gekoppelt (`darkAqua`/`aqua` via AppDelegate + `applyAppearance()`), sonst rendern System-Controls (Picker/Toggle) unlesbar dunkel auf dunkel.

**Dark/Light Mode (HTML):** CSS Custom Properties (`--bg-primary`, `--bg-panel`, etc.) mit `@media (prefers-color-scheme: dark)` Auto-Detection und manuellem Toggle via `.theme-dark` / `.theme-light` Klassen.

**DMG-Background:** Retina-kompatibel via `tiffutil -cathidpicheck` (1x 600×600 + 2x 1200×1200 TIFF).

**Duplikaterkennung:** Playlist filtert beim Hinzufügen auf doppelte Dateinamen.

**Quick-Look-Extension (macOS):** `Sources/ViciousSIDQuickLook/` wird von
`build_app.sh` als `Contents/PlugIns/ViciousSIDQuickLook.appex` ins App-Bundle
verpackt (NSExtension-Point `com.apple.quicklook.preview`, sandboxed, eigener
UTI `com.viben.sid-tune` für `.sid`). Einstiegspunkt ist `NSExtensionMain`
(Linker-Flag in `Package.swift`), nicht `main()`. Wiedergabe startet automatisch
beim Preview (Quick-Look-Views sind auf macOS nicht zuverlässig klickbar) und
stoppt beim Schließen. Signierung von innen nach außen: erst `.appex` mit
Sandbox-Entitlements, dann App — **kein `codesign --deep`**, das würde die
Entitlements der Extension verwerfen. Test: `qlmanage -p audio/<datei>.sid`
(vorher ggf. `lsregister -f "Vicious SID Player.app"`).

---

## Lizenzen

- **jsSID 0.9.1** — Hermit (Mihály Horváth), WTFPL
- **Dieses Projekt** — WTFPL

---

## Aktuelle Todos

- [x] **Todo 1**: Release-Builds fuer macOS absichern: App und DMG per Developer ID signieren, DMG notarisieren/stapeln, Publish-Script gegen Audio-/Release-Artefakte haerten und README aktualisieren.
- [x] **Todo 2**: README klarstellen, dass GitHub-Release-DMGs notarisierte Builds sind.

- [x] **Todo 3**: GitHub-Auftritt mit README-Icon und Social-Preview-Bild aus dem App-Icon aufwerten.

- [x] **Todo 5**: README zweisprachig machen: `README.md` als englische
  Standardfassung, `README.de.md` als deutsche Fassung, beide mit
  Sprachumschalt-Zeile oben (Konvention Skill `github-publish`). Beide
  Fassungen enthalten zudem eine Quick-Look-Installationsanleitung.

- [x] **Todo 4**: Player-Konkurrenzanalyse durchgefuehrt (2026-07-02). Ergebnis als
  Feature-Gap-Liste unten unter „Feature-Gaps / Roadmap-Kandidaten".

- [x] **Todo 6**: Public-Repo-Hygiene: entschieden 2026-07-05. Die Treffer auf
  den Autorennamen (LICENSE, READMEs, About-Dialog, Signing-Identity) sind
  gewollte oeffentliche Autorenschaft — das Repo steht dafuer als `report-only`
  in der zentralen Ausnahme-Liste, und der Session-Start-Hook schweigt bei
  dieser Policy jetzt. Zusaetzlich bereinigt: privater Nextcloud-Pfad (jetzt
  Einstellungen-Dialog) und projektfremder Notary-Profilname (`NOTARY_PROFILE`
  ist jetzt Pflicht-Env fuer `build_dmg.sh --notarize`, Fail-fast vor dem Build).

- [x] **Todo 7**: Quick-Look-Buttons im Finder per Klick testen — von Daniel
  manuell getestet, funktioniert (2026-07-05).

---

## Feature-Gaps / Roadmap-Kandidaten

Ergebnis der Konkurrenzanalyse (2026-07-02) gegen gaengige SID-Player
(libsidplayfp/sidplayfp, JSIDPlay2, DeepSID, WebSID, ACID64, SIDPLAY/Mac u. a.).
Groesste echte Luecken dieses Players, nach Nutzen/Aufwand priorisiert:

1. **Audio-Export (WAV) + Headless-CLI-Ausbau** — kein Export vorhanden. WAV via
   schneller-als-Echtzeit-Render ist klein–mittel im Aufwand, benoetigt kein
   externes Asset und passt zum Ziel der Skript-/Headless-Steuerbarkeit. Baut auf
   `Tools/sidcheck/main.swift` auf (dort gibt es bereits einen `--dump`-Modus).
2. **Multi-SID / Stereo (2SID/3SID)** — aktuell nur 1 SID; Multi-SID-Tunes werden
   unvollstaendig wiedergegeben. Groesster *Korrektheits*-Gewinn, philosophiekonform
   (reine Emulation). Groesserer Aufwand: zweite/dritte SID-Instanz, Adress-Dekodierung
   aus dem PSID/RSID-Header (v3/v4), Stereo-Mixing. Verwandt: Pro-Chip-Modellwahl
   (`preferred_SID_model[0/1/2]` schreibt aktuell denselben Wert).
3. **Optionale Songlength-DB (`Songlengths.md5`)** — ersetzt das feste Scrub-Limit
   durch echte Laengen. Nur philosophiekonform, wenn der Nutzer die DB-Datei selbst
   auswaehlt (kein Buendeln — es werden bewusst keine externen Assets ausgeliefert).
   MD5 ueber die Datei + INI-Parser, mittlerer Aufwand.
   *Bekannte Folge der fehlenden DB (Code-Review F19, 2026-07-08):* `SCRUB_MAX = 360 s`
   ist zugleich die Auto-Next-Schwelle. Auto-Next/Subtune-Wechsel feuert daher erst
   nach 6 min — kuerzere Tunes (HVSC-Mehrheit) laufen bis dahin weiter, statt am
   tatsaechlichen Songende zu wechseln. Behebt sich mit dieser Songlength-DB.
4. **Voice-Muting + Filter-Toggle** — einzelne der 3 Stimmen live stummschalten und
   den SID-Filter an/aus. Zwei sehr kleine, synergetische Ergaenzungen zum
   Oszilloskop (Analyse-Nutzen).
5. **Fast-Forward / genaueres Seek** — Emulation schneller-als-Echtzeit laufen lassen.
   Kleiner UX-Gewinn, gut mit der Emulations-Schleife kombinierbar.

Bewusst niedrig/nicht empfohlen: STIL-Infos (externes Asset + HVSC-Pfad-Abhaengigkeit),
Hardware-/ASID-Ausgabe (Nische), Audio-Fingerprint-Erkennung (sehr grosser Aufwand),
reSIDfp-Vollport (nur inkrementelle Filter-Verbesserung realistisch).
