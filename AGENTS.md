# Vicious SID Player — dauerhafte Projektregeln

Stand: 2026-07-14. C64-SID-Musikplayer als native SwiftUI-macOS-App mit Quick
Look und als Single-File-HTML5-App. Keine SID-Musikdateien bündeln oder committen.

## Zweck und Struktur

- `Sources/ViciousSIDPlayerCore/`: Parser, SID/6502-DSP, Audio-Koordinator,
  Songlängen, WAV-Renderer und testbare Konfigurationslogik.
  `Library/` enthält Bibliotheksindex, Import und Zurücksetzen — plattformneutral
  und von beiden Apps nutzbar.
- `Sources/ViciousSIDPlayerApp/`: SwiftUI-App, Einstellungen, Playlist,
  Oszilloskop, Media-Tasten und Sessionzustand.
- `Sources/ViciousSIDQuickLook/`: Quick-Look-Extension.
- `ios/`: native iPhone-App (eingechecktes `.xcodeproj`, iOS 17 Minimum).
  `ViciousSIDPlayer/Player/` ist das App-Modell samt Audio-Session und Now
  Playing, `UI/` und `Library/` sind SwiftUI, `ViciousSIDPlayerTests/` sind die
  Simulator-Tests, `scripts/` die Buildskripte.
- `Tests/ViciousSIDPlayerTests/`: SwiftPM-Tests.
- `src/`, `sidplayer.js`, `sid-player-worklet.js`: HTML5-Player; `build.py`
  erzeugt die gitignored Single-File-Ausgabe.
- `build_app.sh`, `build_dmg.sh`: App-/DMG-Build; `VERSION`: Version.

Die App scannt einen konfigurierbaren lokalen Autoplay-Ordner; der Default liegt
außerhalb des Repos. Persönliche Sammlung, `.sid`-Dateien, Audioexports, DMGs und
Releaseartefakte bleiben unversioniert.

## Architekturverträge

- SID-/6502-Emulation stammt aus jsSID 0.9.1 mit lokalen Korrekturen. Opcode-Maske,
  Noise-Waveform und ENV3-Readback nicht ohne Referenztest verändern.
- Zeilenbasierte Textdateien fremder Herkunft (etwa `Songlengths.md5`) unicode-korrekt
  trennen, z. B. über `split(whereSeparator: \.isNewline)`. In Swift ist `"\r\n"` ein
  einzelnes `Character`; `split(separator: "\n")` liefert bei Windows-Zeilenenden
  deshalb eine einzige Zeile. Solche Parser immer mit LF- und CRLF-Eingaben testen.
- Binärparser dürfen nicht voraussetzen, dass `Data` bei Index 0 beginnt: Ein
  `Data`-Ausschnitt hat einen eigenen `startIndex`. Offsets relativ zu
  `data.startIndex` rechnen oder die Eingabe an der Parsergrenze bewusst in ein
  neues `Data` normalisieren; Tests auch mit echten Slices füttern.
- HTML5-Engine läuft als Plain Class im AudioWorklet; Bundling muss über `file://`
  funktionsfähig bleiben. Keine Serverpflicht einführen.
- Native Wiedergabe: `play()` baut den Processor neu oder setzt einen pausierten
  Zustand fort; `pause()` erhält Emulationszustand, `stop()` setzt zurück. Seek ohne
  aktiven Processor wird gepuffert und beim nächsten Play angewandt.
- UI-/Visualizer-Timer bleibt im `.common`-RunLoop, damit Slider-Drag das
  Oszilloskop nicht anhält.
- 2SID/3SID-Stereo und Pro-Chip-Modellflags erhalten. Nutzer-Override wirkt global;
  1SID bleibt mittig. WAV-Export ist bei Multi-SID stereo, sonst mono.
- Voice-Mute entfernt nur den Mixbeitrag; Emulation läuft weiter. Filter-Bypass hält
  Filterzustand warm. Keine zustandsverändernde „Optimierung“ beim Muten.
- Songlänge: HVSC `Songlengths.md5` → berechneter Cache → 360-s-Fallback. Der
  Hintergrund-Estimator erkennt Ende erst nach mindestens drei Sekunden Stille und
  cached auch Loop-/Negativergebnisse. Diese Reihenfolge steuert Scrubber, Auto-Next,
  Now Playing und Export. Sie steht seit v1.9.9 im Core in `SongLengthResolver`
  (Reihenfolge, negativer Cache, Buchführung über die laufende Berechnung) und
  `SongLengthSelection` (Leiter zur effektiven Dauer); die Frontends halten nur noch
  den Hintergrund-Task. Neue Regeln gehören dorthin, nicht in `MainView` oder
  `AppModel+Playback`.
- Session-Restore speichert Track/Subtune/Position gedrosselt. Bei aktivem Shuffle
  nicht restaurieren; zufälliger Start ist beabsichtigt.
- Titel-IDs sind auch auf dem Mac relative Pfade (`PlaylistTrackID`): Playlist,
  Favoriten und Session-Restore erkennen einen Titel an seinem Pfad unterhalb des
  Autoplay-Ordners, hereingezogene Fremddateien an ihrem absoluten Pfad. Darüber
  läuft auch die Deduplikation — derselbe Dateiname in verschiedenen Ordnern sind
  zwei Titel (Entscheidung 2026-08-15; vorher galt der bloße Dateiname, wodurch in
  einer nach Komponisten sortierten Sammlung ganze Ordner unerreichbar blieben).
  Gespeicherte absolute Pfade rechnet die App beim Start einmalig um; diesen
  Migrationspfad nicht entfernen, sonst verliert der Nutzer seine Favoriten.
- Playlist-Logik (Aufbau, Deduplikation, Suche über Titel **und** Ordner, Favoriten,
  nächster Titel) steht im Core in `Playlist`, der Ordner-Scan in `MusicLibrary`.
  Die Frontends halten nur Zustand. Neue Korrektheitsregeln gehören dorthin, weil
  `MainView` in einem `executableTarget` liegt und aus XCTest nicht erreichbar ist.
- Der Autoplay-Ordner ist auf dem Mac frei wählbar, `MusicLibrary` wechselt ihre
  Wurzel aber nie: bei einer Änderung wird sie neu gebaut, und der Index heißt je
  Wurzel anders (`MusicLibrary.indexFileName(forRoot:)`). Ohne das zeigte ein
  fehlgeschlagener Scan die Titel der vorigen Sammlung an.

### iOS

- Die Bibliothek liegt auf iOS fest in `Documents/`, weil nur dieser Ordner über
  Finder-Dateifreigabe und Dateien-App erreichbar ist. Index und Caches gehören
  bewusst **nicht** dorthin, sonst sieht der Nutzer sie zwischen seiner Musik.
  Einzige Wahrheit über beide Orte ist `MusicLibraryLocation`.
- Titel-IDs sind **relative Pfade**, nie absolute URLs: der App-Container bekommt
  bei jeder Neuinstallation eine neue UUID. Favoriten und Session-Restore hängen
  daran.
- Der Index ist nie die einzige Wahrheit. Von außen abgelegte oder gelöschte
  Dateien müssen beim Wechsel in den Vordergrund erkannt werden.
- Audio läuft im Hintergrund weiter, gezeichnet wird dort nicht. Der Zeichentakt
  hängt an `isSceneActive`; zusätzlich fällt `ViciousCoordinator.setUIUpdateInterval`
  im Hintergrund auf 1 Hz. Auto-Next und Sperrbildschirm laufen über einen eigenen
  1-Hz-Task, der **nicht** an der Szenenphase hängt — sonst endet die Wiedergabe am
  ersten Songende.
- Kopfhörer abziehen (`.oldDeviceUnavailable`) pausiert. Niemals laut über den
  Lautsprecher weiterspielen. Nach einer Unterbrechung nur bei `.shouldResume`
  fortsetzen.
- `MPNowPlayingInfoCenter` bekommt die verstrichene Zeit nur bei Zustandswechseln
  und höchstens im Sekundentakt — jeder Schreibvorgang ist ein IPC-Aufruf.
- Die Sitzungswiederherstellung bereitet den Titel vor, **spielt aber nicht von
  selbst los** (bewusster Unterschied zur Mac-App). Bei aktivem Shuffle wird wie
  dort gar nicht wiederhergestellt.
- Die Mini-Player-Leiste hängt per `safeAreaInset` am **Tab-Inhalt**, nicht an der
  `TabView`. An der TabView verdeckt sie die Tab-Leiste vollständig und die App
  ist ab dem ersten Titel nicht mehr umschaltbar.
- Keine privaten APIs, Privacy-Manifest gepflegt: der Weg in den App Store bleibt
  offen. Team-ID und Bundle-ID stehen bewusst eingecheckt in den Target-Settings
  der pbxproj, damit der Geräte-Build direkt aus Xcode läuft. Der gitignorierte
  `ios/.env`-Weg überschreibt sie nur beim Skript-Build, weil `build-device.sh`
  sie an `xcodebuild` durchreicht — in der Xcode-GUI gewinnt die pbxproj.
  Reihenfolge und Folgen für fremde Clones stehen in `ios/Config/Signing.xcconfig`.

## Quick Look, Signatur und Release

Die Extension ist `ViciousSIDQuickLook.appex` mit Extension-Point
`com.apple.quicklook.preview`, Sandbox und eigenem `.sid`-UTI. Einstieg ist
`NSExtensionMain`, nicht `main()`. Preview startet automatisch, weil klickbare
Quick-Look-Controls auf macOS nicht zuverlässig sind, und stoppt beim Schließen.

- Von innen nach außen signieren: zuerst `.appex` mit ihren Entitlements, danach App
  und DMG. Niemals `codesign --deep`; das kann Extension-Entitlements überschreiben.
- Notarisierung verwendet nur das ausdrücklich konfigurierte `NOTARY_PROFILE` und
  darf keine projektfremden Profile erraten. Secrets nie in Argumente/Logs schreiben.
- Release-Skripte müssen Audio-/SID-/lokale Artefakte ausschließen. GitHub-Release,
  Tag, notarisiertes DMG und Publish nur nach ausdrücklichem konkreten Auftrag.
- Quick Look nach Bundle-Registrierung an einer lokalen, nicht versionierten SID-Datei
  prüfen. Keine Test-SID in Repo oder Paket aufnehmen.

## UI- und Systemverhalten

- Theme `auto` folgt dem System; Hell/Dunkel sind feste Overrides. Systemzustand aus
  globalem `AppleInterfaceStyle`, nicht aus der bereits überschriebenen
  `NSApp.effectiveAppearance`, lesen. AppKit-Appearance passend setzen, sonst werden
  Systemcontrols unlesbar. Oszilloskopfarben brauchen im Hellmodus genügend Kontrast.
- Media-Tasten/Now Playing verwenden `MPRemoteCommandCenter` und
  `MPNowPlayingInfoCenter`. Sie funktionieren vollständig nur im echten App-Bundle,
  nicht zwingend in `swift run`.
- Autoplay-Ordnerauflösung bleibt im Core testbar; eine Settings-Änderung lädt die
  Playlist sofort neu. Keine persönlichen Pfade hartkodieren.
- DMG-Hintergrund bleibt Retina-TIFF aus 1x/2x-Quellen.

## Lizenzen und öffentliche Hygiene

- jsSID 0.9.1: Hermit/Mihály Horváth, WTFPL; Projektcode: WTFPL. Attributions- und
  Lizenzhinweise nicht entfernen.
- Copyright-geschützte SID-Dateien nie bündeln, kopieren oder veröffentlichen.
- Öffentliche README ist Englisch, `README.de.md` Deutsch; beide inhaltlich synchron
  halten und Sprachumschalter erhalten.
- Gewollte öffentliche Autorenschaft ist erlaubt; private Sammlungspfade, interne
  Hosts/IPs, Kontakte, Notary-Profile und Assistentenformulierungen nicht.

## Bauen und testen

```bash
python3 build.py
python3 build.py --no-min
swift test
bash Tests/fleet-rules.sh
bash build_app.sh
bash build_dmg.sh
bash ios/scripts/build-simulator.sh
bash ios/scripts/run-tests.sh
```

`build_dmg.sh --notarize` ist ein externer Release-Schritt und läuft nur nach Auftrag
und Secret-/Signatur-Preflight. Testanzahlen nicht in Daueranweisungen festschreiben.

Drei Einstiegspunkte: `build_app.sh` baut nur, `./install.sh` installiert
notarisiert nach `/Applications`, `./release.sh` packt das DMG (installiert nie).
Beide heften zuerst der App selbst ein Ticket an. Profilname aus `NOTARY_PROFILE`
oder `git config viciousSidPlayer.notaryProfile`.

`bash Tests/fleet-rules.sh` hält die beiden Fleet-Regeln vom 2026-08-03 fest: Nach
`/Applications` gelangt nur ein Bundle mit angeheftetem Notary-Ticket (ad hoc gebaut wird
nur im Projektverzeichnis), und kein absoluter Pfad des Build-Rechners darf im
ausgelieferten Bundle landen. Der Test liest nur Quellen und baut, signiert und installiert
nichts. Diese Prüfung nie dadurch „belegen", dass der echte Installationsweg gegen
`/Applications` läuft — das ersetzt Daniels installierte App.

Änderungsspezifische Gates:

- DSP/Parser/6502: Swift-Tests plus bekannte SID-Referenzfälle; HTML5 und native
  Implementierung auf beabsichtigte Parität prüfen.
- Playback/Seek/Pause: Zustandsautomat testen, einschließlich Seek im Stopzustand und
  Pause-Fortsetzung ohne Reset.
- Songlängen: HVSC-Treffer, berechneter Cache, Loop-Negativcache und Fallback abdecken.
- Multi-SID/Mute/Filter/WAV: Kanalzahl, Pan, Modellflags und zustandserhaltendes Mute
  testen; Exportheader und Dauer prüfen.
- Theme/UI/Media: Core-Theme-Test plus echter App-Bundle-Smoke-Test; Media-Commands
  nicht nur über nacktes Swift-Binary abnehmen.
- Quick Look: Bundle-Inhalt, Entitlements, Signaturreihenfolge, Registrierung, Öffnen
  und Stop beim Schließen prüfen.
- HTML: Build reproduzierbar, Single-File startet unter `file://`, Drag & Drop von
  Datei und Ordner funktioniert.
- iOS: `ios/scripts/build-simulator.sh` ohne Warnungen im eigenen Code und
  `ios/scripts/run-tests.sh` grün. Core-Änderungen zusätzlich gegen
  `generic/platform=iOS Simulator` bauen — `swift test` allein übersetzt den Core
  nie für iOS und übersieht genau die Foundation-Lücken, die dort auftreten.
- Hintergrundwiedergabe, Sperrbildschirm, AirPods, Anruf und Kopfhörerabziehen sind
  **im Simulator nicht belegbar**. Diese Abnahme läuft ausschließlich über
  [`ios/GERAETETEST.md`](ios/GERAETETEST.md) auf echter Hardware; niemals als geprüft
  ausgeben, wenn nur der Simulator lief.

## Code- und Git-Regeln

- Korrektheitslogik in Core statt SwiftUI halten. Identifier Englisch; Doku und
  Kommentare Deutsch; komplexe Emulations-/Audioabschnitte anfängerfreundlich
  kommentieren. Kommentare bei Rename/Refactor erhalten und anpassen.
- Nur aufgabenbezogene Pfade stagen. Fremdes WIP, lokale Audio-/Releaseartefakte und
  andere Worktrees unangetastet; kein `git add .`, `git add -A`, Reset oder Clean.
- Nach verifizierter Produktänderung `VERSION` nach Repo-Konvention erhöhen, committen
  und zum kanonischen privaten Fleet-Remote pushen. Reine AGENTS-/Doku-Reorganisation braucht
  keinen Produktversions-Bump.
- `origin`/GitHub nur nach ausdrücklichem konkreten Auftrag. Vor Veröffentlichung
  Artefaktinhalt und ausgehenden Diff auf private Pfade/Daten prüfen.

## Aktiver Backlog

Kanonisch in `backlog.md`. Priorität: STIL-Integration; Bibliotheks-/HVSC-Browser;
Mini-Player; HTTP-Remote/URL-Schema; Filter-Tuning. Hardware-ASID, Audiofingerprint,
voller reSIDfp-Port und MUS/CGSC sind bewusst niedrige Priorität. Erledigte Release-
und Featurechronik gehört in Changelog/Release Notes, nicht hierher.

## Progressive Details und Scope

- Konkurrenz-/Featureanalyse: `tasks/2026-07-10-player-recherche/recherche.md`.
- Release-/Nutzungseinstieg: READMEs und Buildskripte.
- Architekturvertrag: Tests direkt neben betroffenen Core-Komponenten.
- Historie: Changelog, Releases und abgeschlossene Tasks.

Ein unter `.claude/worktrees/` gefundenes verschachteltes AGENTS-Dokument gehört zu
einem prunebaren Worktree-Eintrag mit fehlendem Gitdir. Es ist nicht autoritativ und
nicht in diese Root-Regeln zu integrieren. Worktree-Metadaten nur separat und bewusst
bereinigen; niemals dabei Nutzerdateien löschen.

Die frühere Status- und Releasechronik liegt unverändert unter
`docs/archive/agent-context-legacy-2026-07-14.md`; sie ist Referenz, keine aktive
Anweisung.

## Verzeichnisstruktur

- [`README.md`](README.md) / [`README.de.md`](README.de.md): Nutzer- und Projektüberblick.
- `Package.swift`: Swift-Paket, Targets und Abhängigkeiten.
- `sidplayer.js`, `sid-player-worklet.js`, `vicious-sid-player.html`: Web-Player.
- `build.py`, `build_app.sh`, `build_dmg.sh`: Build- und Paketwerkzeuge.
- `ios/`: iPhone-App; [`ios/GERAETETEST.md`](ios/GERAETETEST.md) ist die
  Prüfliste für die Abnahme auf echter Hardware.
- [`backlog.md`](backlog.md): verifizierte offene Arbeit.
- [`docs/archive/agent-context-legacy-2026-07-14.md`](docs/archive/agent-context-legacy-2026-07-14.md): frühere Chronik, nicht autoritativ.
