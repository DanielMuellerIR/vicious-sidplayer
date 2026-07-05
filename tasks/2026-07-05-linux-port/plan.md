# Linux-Port: Vicious SID Player

Stand: 2026-07-05 · Ziel: Das bestehende Repo läuft zusätzlich unter Linux — zuerst als
CLI-Player, optional später mehr. Kein separates Repo, kein Fork: der portable Kern
(`ViciousSIDPlayerCore`) wird plattformübergreifend genutzt, macOS-App/Quick-Look bleiben
unverändert.

## Ausgangslage (verifiziert 2026-07-05)

- `Sources/ViciousSIDPlayerCore/` ist bis auf **eine Datei** reines Foundation:
  nur `DSP/ViciousCoordinator.swift` importiert `AVFoundation` + `Combine` (beides auf
  Linux nicht verfügbar). `ViciousProcessor.swift` (6502-CPU + SID-DSP), `SidParser.swift`,
  `AutoplayFolder.swift`, `DropURLDecoder.swift` sind plattformneutral.
- `Package.swift` (swift-tools 6.0) hat bereits getrennte Targets: Core-Library,
  App, `sidcheck` (headless), Quick-Look, Tests.
- Tests (`Tests/ViciousSIDPlayerTests/`) hängen nur am Core.
- Eine HTML5-Variante (`vicious-sid-player.html` + `sidplayer.js`) existiert und deckt
  „GUI auf Linux" übergangsweise ab — ein natives Linux-GUI ist NICHT Teil dieses Plans.

## Architektur-Entscheidung

Ein Repo, drei Schichten:

1. **Core** (bestehend, plattformneutral): Emulation + Parser. Änderung: die eine
   AVFoundation-Datei plattform-guarden.
2. **Audio-Backend-Abstraktion** (neu, klein): ein Protokoll `PCMSink` (o. ä.) mit zwei
   Implementierungen — macOS behält den AVAudioEngine-Weg, Linux bekommt zunächst
   **PCM-auf-stdout** (Pipe an `aplay`/`paplay`), später optional eine echte
   ALSA/PortAudio-Anbindung. Bewusst minimal halten (kein spekulatives Framework).
3. **CLI** (neu): Executable-Target `sidplay-cli`, läuft auf macOS UND Linux — damit ist
   der Linux-Pfad auf dem Mac mitentwickel- und mittestbar.

## Phasen (jede endet mit prüfbarem Erfolgskriterium)

### Phase 0 — Core kompiliert auf Linux (~0,5 PT)
- `ViciousCoordinator.swift` komplett in `#if canImport(AVFoundation)` … `#endif` hüllen
  (Datei-weiter Guard; Datei NICHT verschieben — chirurgisch bleiben).
- `Package.swift`: `platforms: [.macOS(.v13)]` bleibt (wirkt auf Linux nicht); prüfen,
  dass App-/QuickLook-Targets den Linux-Build der Library nicht blockieren — falls doch,
  Produkt-Definitionen so lassen und Linux nur `swift build --target ViciousSIDPlayerCore`
  bzw. das CLI-Target bauen lassen.
- Tests durchsehen: alles, was AVFoundation/Coordinator berührt, ebenfalls guarden.
- **Erfolgskriterium:** `swift build` + `swift test` grün in einem
  `swift:6.0`-Docker-Container (linux/arm64 reicht für den Anfang).

### Phase 1 — CLI mit PCM-Ausgabe (~1–2 PT)
- Neues Target `sidplay-cli` (Name des Binaries: `vicious-sid`):
  `vicious-sid <datei.sid> [--subtune N] [--seconds S] [--wav out.wav] [--stdout]`.
- Rendering direkt über `ViciousProcessor` (Blöcke von Float/Int16-Samples ziehen —
  am Muster von `Tools/sidcheck/main.swift` und dem WAV-Export orientieren).
- `--wav`: WAV-Datei schreiben (eigener Mini-Writer, 44-Byte-Header — kein AVAudioFile).
- `--stdout`: rohes PCM (s16le, Samplerate dokumentieren) → auf Linux
  `vicious-sid tune.sid --stdout | aplay -f S16_LE -r 44100 -c 2`, auf macOS via `ffplay`.
- Metadaten (Titel/Autor aus PSID-Header, Subtune-Anzahl) auf stderr ausgeben, damit
  stdout sauberes PCM bleibt. Exit-Codes: 0 ok, 1 Parse-Fehler, 2 I/O.
- **Erfolgskriterium:** bekannte .sid-Datei spielt hörbar korrekt via aplay im
  Linux-Container/Rechner; `--wav`-Ausgabe byteident zwischen macOS- und Linux-Build
  (Determinismus-Check als Test).

### Phase 2 — Echtzeit-Playback + Steuerung (~1–2 PT)
- ALSA-Anbindung über ein SwiftPM-`systemLibrary`-Target (`libasound`), Callback-Modell
  analog zum AVAudioSourceNode-Muster. Alternative, falls zäh: PortAudio.
- Tastatursteuerung im CLI (Pause, Subtune +/-, Quit) über Terminal-Raw-Mode.
- **Erfolgskriterium:** Start/Pause/Subtune-Wechsel ohne Knackser auf Linux.

### Phase 3 (optional, erst bei Bedarf) — Desktop-Integration
- MPRIS2 (D-Bus) für Media-Tasten; .desktop-Datei + Icon; Paketierung als statisches
  Binary (`swift build -c release --static-swift-stdlib`) oder AppImage.
- Kein GTK/Qt-GUI geplant — dafür gibt es die HTML5-Variante.

## Rahmenbedingungen

- **CI:** GitHub-Actions-Job `ubuntu-latest` mit Swift-Setup ergänzen (Build + Tests +
  Determinismus-Check). Erst wenn lokal grün.
- **Testumgebung lokal:** Docker (`swift:6.0`) genügt für Build/Tests/WAV-Vergleich;
  hörbares Audio braucht einen echten Linux-Rechner.
- **README:** Linux-Abschnitt (Build, aplay-Beispiel) in README.md + README.de.md,
  erst wenn Phase 1 fertig ist.
- **Stil:** bestehende Kommentar-Dichte übernehmen (ausführliche deutsche Kommentare);
  keine Umbauten an App/Quick-Look; Versions-Bump in `VERSION` pro Phase.
- **Delegation:** Phasen sind als Junior-Dev-Briefs geeignet (klar abgegrenzte Dateien,
  harte Erfolgskriterien); Review vor Merge obligatorisch.

## Reihenfolge-Hinweis

Dieses Projekt ist Blaupause für den savage_modplayer-Port (identisches Muster).
Die PCMSink-Abstraktion aus Phase 1/2 dort per Copy übernehmen; erst wenn sie sich in
BEIDEN Repos bewährt hat, über ein gemeinsames Package nachdenken (nicht vorab).
