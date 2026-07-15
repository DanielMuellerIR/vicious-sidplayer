# Linux-Port: Vicious SID Player

Stand: 2026-07-05 · Ziel: Das bestehende Repo läuft zusätzlich unter Linux — zuerst als
CLI-Player, optional später mehr. Kein separates Repo, kein Fork: der portable Kern
(`ViciousSIDPlayerCore`) wird plattformübergreifend genutzt, macOS-App/Quick-Look bleiben
unverändert.

## Stand 2026-07-15: Phase 2 abgeschlossen (v1.7.0)

Tastatursteuerung im CLI über `RawTerminal` (termios-Rohmodus, macOS + Linux):
Leertaste = Pause/Weiter, n/p = Subtune vor/zurück, q bzw. Strg-C = Ende. Nur aktiv,
wenn stdin an einem Terminal hängt (`isatty`) — in Skripten/CI entfällt sie.

- `ISIG` ist im Rohmodus abgeschaltet. Folge: Strg-C kommt als Byte 0x03 herein statt
  als Signal, und die Tastaturschleife MUSS darauf reagieren — sonst hängt der Player
  unkündbar. Der Gegenwert: das Terminal bleibt nie im Rohmodus zurück.
- Subtune-Wechsel greift direkt in den laufenden Processor. Sicher, weil `initSubtune`
  dieselbe `NSLock` nimmt wie `playStereo()` im Audio-Thread.
- `PCMSink` verlangt jetzt `Sendable` (vorher offener Punkt). Ein Sink wird von Natur
  aus über Thread-Grenzen benutzt — hier konkret, weil `waitUntilFinished()` auf einem
  eigenen Warte-Thread läuft, damit der Haupt-Thread Tasten lesen kann.

**Erfolgskriterium erfüllt** („Start/Pause/Subtune-Wechsel ohne Knackser auf Linux"):
über ein Pseudoterminal echte Tasten geschickt, Ausgabe über echtes ALSA in eine
PipeWire-Null-Senke, Mitschnitt per `parec` ausgewertet. Der Pegelverlauf zeigt Musik
bei ~10500, während der Pause **exakt 0** (ALSA hört auf zu liefern, statt zu
wiederholen oder zu rauschen), danach sauberen Wiedereinstieg und beim Subtune-Wechsel
den erwarteten Pegelsprung. Keine Aussetzer während der Wiedergabe. Nicht belegbar
bleibt, ob die Übergangskante minimal knackst — das hört nur ein Mensch.

## Stand 2026-07-15: Phase 0 und 1 erledigt, ALSA aus Phase 2 erledigt (v1.6.0)

Verifiziert auf dem lokalen Linux-Testrechner (Mint 22.2, x86_64) im Container
`swift:6.0` (Swift 6.0.3):

- **Phase 0 erfüllt:** `swift build` und `swift test` laufen auf Linux grün, ohne
  Sonderflags. 22 Tests auf Linux, 24 auf macOS — die Differenz sind exakt die zwei
  CryptoKit-Kreuzvergleiche der MD5, die es auf Linux nicht gibt.
- **Phase 1 erfüllt:** `vicious-sid` baut und läuft. Die WAV-Ausgabe ist zwischen
  macOS-arm64 und Linux-x86_64 **byteidentisch** (gleiche MD5, gleiche Größe) — die
  Emulation rechnet auf beiden Architekturen bitgenau dasselbe.
- **ALSA (Phase 2) erledigt und laufzeitgeprüft:** Wiedergabe über eine temporäre
  PipeWire-Null-Senke, Mitschnitt per `parec`: 5,2 s, Spitzenpegel 14121/32767,
  79 % Nicht-Null-Samples, sauberes Ende mit `.sourceFinished`. Alle neun unsicheren
  ALSA-C-Signaturen sind gegen echte Header verifiziert (der Build beweist sie).
- Statisches Binary (`--static-swift-stdlib`, ~65 MB) läuft nativ auf dem Host und
  hängt nur noch an System-Bibliotheken inklusive `libasound.so.2`.

### Noch offen

- **Phase 3:** MPRIS2, .desktop-Datei, AppImage — weiterhin optional.
- **CI:** GitHub-Actions-Job `ubuntu-latest` fehlt noch (Build + Tests +
  Determinismus-Check). Nur nach ausdrücklichem Auftrag, da GitHub-Bezug.
- ~~Kein Determinismus-Test in der Testsuite.~~ **Erledigt 2026-07-16** (`d965aac`):
  `Tests/ViciousSIDPlayerTests/DeterminismTests.swift` baut eine synthetische PSID
  zur Laufzeit (handgeschriebene 6502-Routine, keine Datei im Repo) und nagelt den
  MD5 einer Sekunde 16-Bit-PCM fest. Auf macOS-arm64 ermittelt, auf Linux-x86_64
  unverändert bestätigt. Schlägt er fehl, ist entweder die Emulation bewusst geändert
  (Hash nur nach Abgleich mit den SID-Referenzfällen neu setzen!) oder die
  Plattform-Unabhängigkeit kaputt — dann NICHT den Hash anpassen.
- **Pfeiltasten** werden nicht ausgewertet: `readKey()` liefert bewusst ein Byte,
  Escape-Sequenzen (`0x1B [ A`) bräuchten das Einsammeln der Folgebytes.
- **Ehrlichkeitslücke in `ALSAPCMSink`:** wird `waitUntilFinished()` aus dem
  Renderblock heraus gerufen, kann es nicht warten und liefert `.notStarted`, obwohl
  gerade gespielt wird. Im Code benannt.
- Der CLI-Renderpfad zieht immer stereo. Bei 1SID sind beide Kanäle identisch — das
  ist doppelte Arbeit gegenüber `play()`, aber gewollt einfach. Falls Messungen es
  rechtfertigen, wäre mono bei 1SID die Optimierung.

## Nachtrag 2026-07-15 (Umsetzungsbeginn)

Beim Angehen von Phase 0 gefunden, im Ist-Stand unten noch nicht enthalten:

- **CryptoKit-Blocker:** `Songlength.swift` importiert `CryptoKit` (`Insecure.MD5`) für
  den MD5-Schlüssel des HVSC-Lookups. Auf Linux nicht verfügbar — blockiert den
  gesamten Core-Build, nicht nur den Coordinator. Entscheidung (Daniel, 2026-07-15):
  **eigene MD5 im Core**, keine Fremdabhängigkeit; das Repo bleibt abhängigkeitsfrei.
  MD5 ist hier kein Sicherheitsmerkmal, sondern nur ein Lookup-Schlüssel. Abgesichert
  über RFC-1321-Vektoren plus Kreuzvergleich gegen CryptoKit auf macOS.
- **`RealtimeVisualsBuffer` bleibt ungeguardet:** steht zwar in `ViciousCoordinator.swift`,
  braucht aber nur Foundation. Nur `ViciousCoordinator` selbst ist AVFoundation-geguardet,
  damit der Linux-CLI-Pfad den Puffer nutzen kann.
- **Der Linux-Testrechner braucht einmalig eine Einrichtung mit Root-Rechten:** Docker-
  Gruppenmitgliedschaft für den Benutzer und `libasound2-dev`. Ohne Docker-Zugriff und
  ALSA-Header lässt sich der Port weder bauen noch prüfen.
- **App/Quick-Look blockieren den Linux-Build** (SwiftUI/AppKit). Gelöst in `Package.swift`:
  Die Apple-Targets kommen per `#if os(macOS)` gar nicht erst ins Paket, deshalb genügen
  auf beiden Plattformen `swift build` und `swift test` ohne Sonderflags. (Der ältere
  Vorschlag „auf Linux nur `--product vicious-sid` bauen" ist damit hinfällig.)

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
