# iOS-App für Vicious SID Player — Plan

Stand: 2026-07-26. Ziel: eine native iPhone-App im selben Repo, funktional so nah
an der macOS-App wie sinnvoll, mit Wiedergabe im gesperrten Zustand und einem
Weg, ganze Ordner voller `.sid`-Dateien bequem aufs Gerät zu bekommen.

## Bestätigte Entscheidungen (2026-07-26)

| Thema | Entscheidung |
|---|---|
| Distribution | Sideload mit eigenem Developer-Team. App Store bleibt offen: keine privaten APIs, Privacy-Manifest, saubere UTIs, Bundle-ID universal-purchase-fähig. |
| Projektformat | Eingechecktes `.xcodeproj` (Muster wie das iOS-Schwesterprojekt), aber mit `PBXFileSystemSynchronizedRootGroup` — neue Swift-Dateien landen ohne pbxproj-Edit im Target. |
| Import-Wege | (A) rekursiver Ordner-Import in der App, (B) Finder-Dateifreigabe. Kein CLI-Push, kein Wi-Fi-Server. |
| iOS-Minimum | 17.0 |
| Bundle-ID | `com.viben.ViciousSIDPlayer` (identisch zur Mac-App, hält Universal Purchase offen) |

## Nicht verhandelbar

- **Keine Musikdateien im Repo.** Keine `.sid`, keine Sammlungs-Dumps, keine
  Songlength-Datenbank, keine Export-Artefakte. Tests arbeiten mit synthetisch
  erzeugten Fixtures.
- **Keine privaten Pfade.** Der lokale Sammlungsordner erscheint nirgends — nicht
  im Code, nicht in Doku, nicht in Tests, nicht in Screenshots, nicht in
  Commit-Nachrichten. Import-Quellen sind ausschließlich Laufzeit-Auswahl des
  Nutzers.
- **Team-ID nicht eingecheckt.** `DEVELOPMENT_TEAM` kommt aus einer gitignorierten
  `.env`; eine `.env.example` dokumentiert das Format.
- **Lizenzhinweise erhalten.** jsSID 0.9.1 (Hermit/Mihály Horváth, WTFPL) und
  Projektlizenz WTFPL erscheinen auch in der iOS-App (Über-Screen).
- **Kein GitHub-Push, kein Release** ohne ausdrücklichen weiteren Auftrag.

## Ausgangslage (verifiziert 2026-07-26)

- `ViciousSIDPlayerCore` enthält kein AppKit und keinen `Process`-Aufruf; der
  einzige plattformkritische Punkt sind zwei `homeDirectoryForCurrentUser`-Stellen
  (`AutoplayFolder.swift:38`, `SongLengthEstimator.swift:108`).
- `Package.swift` deklariert nur `.macOS(.v13)` — iOS fehlt in `platforms:`.
- `ViciousCoordinator.swift:218` hat bereits einen `#if os(iOS)`-Zweig, der die
  `AVAudioSession` auf `.playback` setzt und aktiviert. Es fehlen Interruption-,
  Route-Change- und `mediaServicesWereReset`-Behandlung.
- `Audio/PCMSink*` ist plattformneutral und über `canImport(AVFoundation)`
  geguardet — auf iOS unverändert nutzbar.
- Die Wiedergabelogik der Mac-App steckt zu großen Teilen in `MainView.swift`
  (rund 1300 Zeilen, ~30 `@State`/`@AppStorage`). Sie wird **nicht** komplett
  umgebaut; siehe „Scope-Grenze“ unten.

## Architektur

### Repo-Layout (neu)

```
ios/
  ViciousSIDPlayer.xcodeproj/            # eingecheckt, synchronized groups
  ViciousSIDPlayer/                      # synchronized root group
    ViciousSIDPlayerApp.swift
    Library/                             # Import-UI, Bibliotheksbrowser
    Player/                              # AudioSession, Now Playing, Session
    UI/                                  # Views, Theme
    Resources/                           # Assets.xcassets, Localizable.xcstrings
    Info.plist
    PrivacyInfo.xcprivacy
  ViciousSIDPlayerTests/                 # iOS-Glue-Tests (Simulator)
  scripts/
    build-simulator.sh
    run-tests.sh
    build-device.sh
  .env.example
```

`ios/build/`, `xcuserdata/`, `*.xcuserstate` und `ios/.env` kommen in `.gitignore`.

### Core-Erweiterungen (plattformneutral, `swift test`-gedeckt)

Neu unter `Sources/ViciousSIDPlayerCore/Library/`:

- `MusicLibrary.swift` — Bibliothekswurzel, rekursiver Scan, Codable-Index.
  **Stabile IDs sind relative Pfade**, keine absoluten URLs: der App-Container
  wechselt bei jeder Neuinstallation seine UUID, absolute Pfade würden Favoriten
  und Session-Restore zerreißen. Der Index liegt in `Application Support`, nicht
  in `Documents` — sonst sieht der Nutzer ihn in der Finder-Freigabe.
- `LibraryImporter.swift` — rekursiver Import mit Fortschritt und Abbruch,
  Struktur-Erhalt, Dedupe, Filter über eine zentrale Dateityp-Konstante.
- `LibraryReset.swift` — Wipe: Dateien, Index, berechnete Längen-Caches;
  Favoriten optional. Idempotent und headless testbar.

Änderungen an vorhandenem Core-Code, bewusst klein:

1. `Package.swift`: `platforms: [.macOS(.v13), .iOS(.v17)]`.
2. `AutoplayFolder`: iOS-Zweig liefert die App-Bibliothek statt
   `~/Music/Vicious SID Player`. Der macOS-Pfad bleibt Byte-gleich; die
   vorhandenen Tests müssen unverändert grün bleiben.
3. Zentrale Konstante für Endung und UTI (`sid` / `com.viben.sid-tune`). Das
   erledigt gleichzeitig Backlog-Punkt 6 (Öffnen-Dialog filtert auf `.sid`).

### Scope-Grenze für den Mac-Refactor

Es wird **nicht** die gesamte `MainView`-Logik nach Core gezogen. Erlaubt und
erwünscht ist nur, was 1:1 austauschbar und durch Tests abgedeckt ist:
Playlist-Ordnung, Shuffle-Reihenfolge, Dedupe, Suchfilter, Favoriten-Schlüssel,
Session-Restore-Kodierung. Alles Größere geht in den Backlog. Nach jeder
Core-Extraktion muss die Mac-App weiterhin über `swift test` und `bash
build_app.sh` grün sein; ein Verhaltensunterschied ist ein Fehler, kein Feature.

### iOS-Audio und Sperrbildschirm

- `Info.plist`: `UIBackgroundModes = [audio]`.
- Eigener `AudioSessionController` im iOS-Target: Kategorie `.playback`,
  `setPreferredIOBufferDuration` (Startwert 10 ms, danach messen),
  `AVAudioSession.interruptionNotification` (Anruf → pausieren, `.shouldResume`
  → fortsetzen), `routeChangeNotification` (`.oldDeviceUnavailable` → pausieren,
  Kopfhörer raus darf nicht laut über Lautsprecher weiterspielen),
  `mediaServicesWereResetNotification` (Engine neu aufbauen).
- `MPRemoteCommandCenter`: play, pause, togglePlayPause, nextTrack,
  previousTrack, changePlaybackPosition. Jeder Handler gibt einen korrekten
  Statuscode zurück, sonst blendet iOS den Button aus.
- `MPNowPlayingInfoCenter`: Titel, Autor, Copyright/Subtune, Dauer, Elapsed,
  Rate, Artwork. Elapsed nur bei Zustandswechseln und höchstens im Sekundentakt
  schreiben — jeder Schreibvorgang ist ein IPC-Aufruf.
- Der bestehende `#if os(iOS)`-Block im Coordinator bleibt; die App konfiguriert
  Kategorie und Optionen davor. Doppeltes `setActive` ist unschädlich.

### Performance

- Oszilloskop und alle UI-Timer laufen nur bei `scenePhase == .active`. Im
  Hintergrund spielt Audio weiter, die Visualisierung steht still. Das ist der
  größte Batteriehebel und muss von Anfang an drin sein.
- Zielbild: 30 Hz Oszilloskop im Vordergrund, SwiftUI `Canvas`. Erst messen,
  dann optimieren; Metal nur, wenn `Canvas` messbar nicht reicht.
- Der Renderblock bleibt allokationsfrei. Auf iOS zusätzlich prüfen: keine
  Dropouts über mindestens 10 Minuten Dauerlauf inklusive Bildschirmsperre.

### UI (iPhone, Hochformat zuerst)

- `TabView`: **Bibliothek**, **Now Playing**, **Einstellungen**, plus eine
  persistente Mini-Player-Leiste über der Tab-Bar (erledigt Backlog-Punkt 3).
- **Bibliothek**: Ordnerbaum mit Auf-/Zuklappen (HVSC-Sammlungen sind
  verschachtelt), Live-Suche, Favoriten-Filter, Swipe-Aktionen, Import-Button.
- **Now Playing**: Oszilloskop, Subtune-Auswahl, Voice-Mute ×3, Filter-Bypass,
  SID-Modell (Auto/6581/8580), Scrubber, Transport, Shuffle, Auto-Next.
- **Einstellungen**: Theme (Auto/Hell/Dunkel), Session-Restore, Songlengths-Datei
  importieren, Bibliothek zurücksetzen, Über/Lizenzen.
- Lokalisierung Deutsch und Englisch über `Localizable.xcstrings`, folgt der
  Systemsprache.

### Import — der eigentliche Knackpunkt

Das bekannte Problem („Teilen-Button liefert nur eine Datei nach der anderen“)
wird nicht über das Share-Sheet gelöst, sondern über zwei andere Wege:

**A — Ordner-Import in der App.**
`fileImporter(allowedContentTypes: [.folder], allowsMultipleSelection: true)`.
Der Nutzer wählt *einen* Ordner (Nextcloud, iCloud, „Auf meinem iPhone“), die App
läuft rekursiv durch und kopiert alles Spielbare samt Unterordnerstruktur in ihre
Bibliothek.

- `startAccessingSecurityScopedResource()` / `stopAccessing…` sauber paaren.
- Enumeration mit `FileManager.enumerator(at:includingPropertiesForKeys:options:)`
  und `.skipsHiddenFiles`.
- **Risiko File Provider:** Nextcloud liefert Einträge unter Umständen als
  Platzhalter ohne lokalen Inhalt. Vor dem Kopieren
  `ubiquitousItemDownloadingStatus` prüfen und das Lesen über `NSFileCoordinator`
  koordinieren, damit der Provider materialisiert. Fehler pro Datei sammeln,
  nicht den ganzen Import abbrechen.
- Import läuft abseits des Main-Threads, mit Fortschritt (n von m) und Abbruch.
  Abschlussbericht: importiert / übersprungen / fehlgeschlagen.
- Zusätzlich Mehrfach-Dateiauswahl (`allowedContentTypes: [sidType]`,
  `allowsMultipleSelection: true`) und Entgegennahme über „Öffnen mit“/AirDrop.

**B — Finder-Dateifreigabe.**
`UIFileSharingEnabled = YES` und `LSSupportsOpeningDocumentsInPlace = YES`. Die
Bibliothek liegt direkt in `Documents/`, dadurch:

- iPhone am Kabel → Finder → Dateien → App: ganze Ordner per Drag & Drop.
- Die iOS-Dateien-App zeigt die Bibliothek unter „Auf meinem iPhone“; dort
  funktioniert Mehrfachauswahl und Einfügen ganzer Ordner aus Nextcloud.
- Die App muss beim Start erkennen, dass jemand von außen Dateien abgelegt oder
  gelöscht hat, und den Index angleichen. Das ist Pflicht, sonst fühlt sich Weg B
  kaputt an.

**Zurücksetzen.** Einstellungen → „Bibliothek zurücksetzen“, zweistufig bestätigt:
löscht den Bibliotheksinhalt, den Index und die berechneten Längen-Caches;
Favoriten per Schalter optional mit. Danach wird über A oder B neu befüllt. Das
ist die geforderte „alles wegwerfen und neu vom Mac holen“-Funktion. Über den
Finder kann derselbe Ordner alternativ direkt am Mac geleert werden.

## Umsetzungsphasen

**Phase 0 — Spike (blockierend, zuerst).** `platforms:` um iOS erweitern und
beweisen, dass `ViciousSIDPlayerCore` für `iphonesimulator` baut. Das Manifest
enthält macOS-only-Targets hinter `#if os(macOS)`; falls Xcode daran scheitert,
muss die Weiche vor allem anderen sitzen. Ergebnis dokumentieren.

**Phase 1 — Projektgerüst.** `.xcodeproj` mit synchronized groups, lokale
Package-Referenz auf das Repo-Wurzelpaket, drei Skripte, `.env.example`,
`.gitignore`-Ergänzung. Erfolgskriterium: leere App startet im Simulator.

**Phase 2 — Core-Bibliothek.** `MusicLibrary`, `LibraryImporter`, `LibraryReset`
inklusive Tests im vorhandenen SwiftPM-Testtarget (synthetische Fixtures).

**Phase 3 — Wiedergabe und Sperrbildschirm.** Coordinator anbinden,
`AudioSessionController`, Now Playing, Remote Commands, Hintergrund-Audio.

**Phase 4 — Import-UX.** Ordner-Picker, Fortschritt, File-Provider-Behandlung,
Finder-Freigabe, Fremdablage-Abgleich, Zurücksetzen.

**Phase 5 — Feature-Parität.** Oszilloskop, Subtunes, Voice-Mute,
Filter-Bypass, SID-Modell, Songlängen (HVSC-Import, berechneter Cache, Fallback),
Suche, Favoriten, Shuffle, Session-Restore, Theme, WAV-Export ins Share-Sheet.

**Phase 6 — Härtung.** Performance messen, Lokalisierung, Über/Lizenzen,
Privacy-Manifest, App-Icon, Doku (README.md und README.de.md synchron), VERSION,
RELEASE_NOTES, AGENTS.md („iOS ist Ist-Zustand“), Backlog aufräumen.

## Prüfgates

| Bereich | Gate |
|---|---|
| Core-Änderung | `swift test` vollständig grün, macOS-Verhalten unverändert |
| Mac-App berührt | zusätzlich `bash build_app.sh` |
| iOS-Build | `ios/scripts/build-simulator.sh` ohne Warnungen im eigenen Code |
| iOS-Logik | `ios/scripts/run-tests.sh` (Simulator, headless) |
| Import | Simulator-Durchlauf mit synthetischem Ordnerbaum: Struktur, Dedupe, Abbruch, Reset |
| Sperrbildschirm | **Nur auf echtem Gerät belegbar** — Daniels Schritt: Wiedergabe bei gesperrtem Display, Steuerung über Sperrbildschirm und AirPods, Verhalten bei Anruf und beim Abziehen der Kopfhörer |
| Öffentlichkeit | getrackter Diff frei von Musikdateien, privaten Pfaden, Team-ID und Assistentenformulierungen |

Ein Simulator-Screenshot ersetzt keinen der headless Gates. Der echte Gerätetest
ist die einzige Abnahme für Hintergrundwiedergabe.

## Risiken

- **Core baut nicht sofort für iOS** (Manifest-Weiche). Deshalb Phase 0 zuerst.
- **File-Provider-Platzhalter** bei Nextcloud: Import kann leere Dateien liefern,
  wenn nicht koordiniert gelesen wird.
- **Realtime-Thread auf iOS** ist strenger getaktet als auf dem Mac; ein Retain im
  Renderblock, der auf dem Mac unauffällig bleibt, knackst hier hörbar.
- **`objectVersion 77`** setzt Xcode 16 oder neuer voraus. Das ist akzeptiert; die
  Alternative wären pbxproj-Konflikte bei jeder neuen Datei.
- **Bibliothek in `Documents/`** heißt: der Nutzer sieht und verändert sie. Der
  Index muss das aushalten und darf nie die einzige Wahrheit sein.
