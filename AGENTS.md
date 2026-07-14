# Vicious SID Player — dauerhafte Projektregeln

Stand: 2026-07-14. C64-SID-Musikplayer als native SwiftUI-macOS-App mit Quick
Look und als Single-File-HTML5-App. Keine SID-Musikdateien bündeln oder committen.

## Zweck und Struktur

- `Sources/ViciousSIDPlayerCore/`: Parser, SID/6502-DSP, Audio-Koordinator,
  Songlängen, WAV-Renderer und testbare Konfigurationslogik.
- `Sources/ViciousSIDPlayerApp/`: SwiftUI-App, Einstellungen, Playlist,
  Oszilloskop, Media-Tasten und Sessionzustand.
- `Sources/ViciousSIDQuickLook/`: Quick-Look-Extension.
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
  Now Playing und Export.
- Session-Restore speichert Track/Subtune/Position gedrosselt. Bei aktivem Shuffle
  nicht restaurieren; zufälliger Start ist beabsichtigt.
- Playlist-Deduplikation nach Dateiname und Favoriten-/Suchverhalten dürfen beim
  Nachladen des Autoplay-Ordners nicht auseinanderlaufen.

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
bash build_app.sh
bash build_dmg.sh
```

`build_dmg.sh --notarize` ist ein externer Release-Schritt und läuft nur nach Auftrag
und Secret-/Signatur-Preflight. Testanzahlen nicht in Daueranweisungen festschreiben.

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
- [`backlog.md`](backlog.md): verifizierte offene Arbeit.
- [`docs/archive/agent-context-legacy-2026-07-14.md`](docs/archive/agent-context-legacy-2026-07-14.md): frühere Chronik, nicht autoritativ.
