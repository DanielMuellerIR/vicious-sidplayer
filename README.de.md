**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<p align="center">
  <img src="src/AppIcon.png" width="128" alt="Vicious SID Player Icon">
</p>

<h1 align="center">Vicious SID Player</h1>

<p align="center">
  <strong>Commodore-64-SID-Chiptune-Player als Single-File-HTML5-Version und native SwiftUI-macOS-App.</strong>
</p>

<p align="center">
  <img src="src/Screenshot-dark.png" width="760" alt="Vicious SID Player im Dark Mode – native macOS-App mit Echtzeit-Oszilloskop, Playlist-Suche und Favoriten, hier mit „Cybernoid“ von Jeroen Tel">
  <br><br>
  <img src="src/Screenshot-light.png" width="760" alt="Vicious SID Player im Light Mode – das Erscheinungsbild folgt automatisch der Systemeinstellung">
</p>

Ein eigenständiger Commodore-64-SID-Musikplayer in zwei Varianten:

1. **HTML5 (`vicious-sid-player.html`)** — Eine einzelne HTML-Datei (~50 KB), die ohne Webserver direkt per Doppelklick aus dem Dateisystem funktioniert.
2. **Native macOS App (`Vicious SID Player.app`)** — SwiftUI-Desktop-Anwendung mit `AVAudioEngine` und Echtzeit-Oszilloskop.

Beide Varianten enthalten keine SID-Dateien. Musikstücke werden per Drag & Drop, Datei-Dialog oder (macOS-App) Doppelklick auf eine `.sid`-Datei im Finder geladen.

---

## Download

Fertige Builds der macOS-App stehen als notarisierte DMGs auf der [Releases-Seite](https://github.com/DanielMuellerIR/vicious-sidplayer/releases) bereit. DMG herunterladen, öffnen und die App in den Programme-Ordner ziehen.

Der HTML5-Player benötigt keinen Download über die Releases hinaus: Die Datei `vicious-sid-player.html` lässt sich direkt im Browser öffnen.

---

## Funktionsumfang

- **Drag & Drop**: Einzelne `.sid`-Dateien oder ganze Ordner können auf den Player gezogen werden. Die Wiedergabe startet sofort.
- **Echtzeit-Oszilloskop**: Zeigt die Wellenformen der drei SID-Stimmen (Dreieck, Sägezahn, Puls, Rauschen) samt Frequenzen, Gate-Status und ADSR-Hüllkurven.
- **SID-Modellwahl (macOS-App)**: Picker zwischen `Auto`, `6581` und `8580`. `Auto` folgt der in der SID-Datei hinterlegten Präferenz; die feste Wahl erzwingt das jeweilige Chip-Modell und wirkt live auf den laufenden Song (viele Tunes klingen nur auf dem ursprünglich gemeinten Chip korrekt).
- **Quick-Look-Vorschau (macOS-App)**: `.sid`-Datei im Finder markieren und Leertaste drücken — der Song spielt sofort, dazu erscheinen Titel, Komponist und Copyright samt Song-Umschaltung bei mehreren Subtunes. Einrichtung: siehe [Quick-Look-Vorschau](#quick-look-vorschau-für-sid-dateien-macos).
- **Echte Songlängen**: Liest die HVSC-Datenbank `Songlengths.md5` (in den Einstellungen wählbar oder automatisch neben der Sammlung gefunden) — Positions-Slider und Auto-Next nutzen dann die tatsächliche Länge. Songs ohne Datenbank-Eintrag analysiert die App beim ersten Abspielen im Hintergrund (sofern sie in Stille enden) und merkt sich das Ergebnis.
- **2SID / 3SID stereo**: Multi-SID-Tunes (PSID v3/v4) spielen mit allen Chips, im Stereo-Panorama verteilt, inklusive Chip-eigener 6581/8580-Modellwahl aus dem Datei-Header.
- **Session-Restore**: Bei ausgeschaltetem Shuffle setzt die App beim Start den letzten Song an der letzten Position fort (inklusive Subtune).
- **Suche & Favoriten**: Live-Suche in der Playlist plus Stern pro Titel (persistent) mit „nur Favoriten"-Filter.
- **Voice-Muting & Filter-Schalter**: Jede der drei SID-Stimmen einzeln stummschalten und den SID-Filter überbrücken — direkt im Oszilloskop, nützlich zum Analysieren, wie ein Tune aufgebaut ist.
- **WAV-Export**: Den aktuellen Song schneller als Echtzeit als WAV-Datei rendern — aus der GUI (⌘E) oder headless von der Kommandozeile (siehe [Headless / CLI](#headless--cli-für-skripte-und-ai-agenten)).
- **Dark / Light Mode**: Folgt automatisch der Systemeinstellung (Standard); in den Einstellungen (⌘,) lässt sich fest Hell oder Dunkel wählen, ⌘T schaltet um.
- **Playlist mit Duplikaterkennung**: Bereits geladene Titel werden nicht doppelt aufgenommen. Die Playlist kann jederzeit geleert werden.
- **Shuffle**: Zufallswiedergabe, die über Neustarts erhalten bleibt; ist sie aktiv, startet beim App-Start ein zufälliger Song.
- **Media-Tasten**: Play/Pause, Stop und Titelsprung über F7/F8/F9, Touch Bar und AirPods — die App registriert sich als *Now Playing*-App des Systems.
- **Keine externen Assets**: Die gesamte Oberfläche (inkl. macOS-Fensterdekorationen und Icons) ist rein prozedural in CSS bzw. SwiftUI Canvas gezeichnet.

---

## Bedienung & Tastenkürzel (macOS-App)

Jedes Bedienelement der App hat einen Tooltip: den Zeiger einen Moment darauf ruhen lassen, dann erscheint eine kurze Erklärung. macOS zeigt Tooltips erst nach einer Verzögerung an, deshalb übersieht man sie leicht — hier die vollständige Referenz.

**Steuerleiste**

| Element | Funktion |
|---|---|
| Tune-Menü | Titel aus der Playlist auswählen. |
| Öffnen… | Eine oder mehrere `.sid`-Dateien öffnen. |
| Auto Next | Am Songende automatisch weiter — erst durch die verbleibenden Subtunes der Datei, dann zum nächsten Titel. |
| SID: Auto / 6581 / 8580 | Chip-Modell. `Auto` folgt der Präferenz der Datei; eine feste Wahl erzwingt das Modell und wirkt live auf den laufenden Song. |
| ‹ n / m › | Subtune-Navigation. Eine `.sid`-Datei kann mehrere Songs („Subtunes") enthalten; `2 / 5` heißt Subtune 2 von 5. |
| Shuffle | Zufallswiedergabe. Die Einstellung bleibt über Neustarts erhalten; ist sie an, startet bei jedem App-Start ein zufälliger Song. |
| ↺ 15 | 15 Sekunden zurück. |
| Play / Pause | Wiedergabe starten oder pausieren (Pause behält die Position und friert das Oszilloskop ein). |
| 30 ↻ | 30 Sekunden vor. |
| Stop | Anhalten und an den Anfang zurück. |
| Positions-Slider | Springen — funktioniert auch im pausierten oder gestoppten Zustand; Play startet dann von dort. |
| Lautstärke-Slider | Wiedergabelautstärke. |
| Lautsprecher-Symbole (Oszilloskop, rechter Rand) | Jede SID-Stimme einzeln stumm-/lautschalten — die Emulation läuft weiter, nur der Audio-Beitrag entfällt. |
| FILTER: ON / OFF (Oszilloskop, unten links) | SID-Filter überbrücken; gefilterte Stimmen laufen dann ungefiltert. |
| Papierkorb (Playlist-Kopf) | Playlist leeren. |

Titel, Komponist und Info in der Seitenleiste sowie lange Titelnamen zeigen ihren vollständigen Text ebenfalls als Tooltip, wenn er abgeschnitten ist.

**Tastenkürzel**

| Taste | Aktion |
|---|---|
| Leertaste | Play / Pause |
| ⌘P | Play / Pause |
| ⌘→ | Nächster Titel |
| ⌘← | Vorheriger Titel |
| ⌘E | Aktuellen Song als WAV exportieren |
| ⌘T | Hell-/Dunkelmodus umschalten (wechselt auf feste Wahl; zurück zu *Automatisch* über die Einstellungen) |
| ⌘, | Einstellungen (Erscheinungsbild, Autoplay-Ordner) |

**Media-Tasten**

Die App registriert sich als *Now Playing*-App des Systems, daher funktionieren die Media-Tasten (F7 / F8 / F9), die Touch Bar und die AirPods-Steuerung: Play/Pause, Stop und Titel vor/zurück. Titel und Wiedergabeposition erscheinen zudem im Kontrollzentrum.

---

## Quick-Look-Vorschau für .sid-Dateien (macOS)

Das App-Bundle enthält eine Quick-Look-Erweiterung, die `.sid`-Dateien direkt in der Finder-Vorschau abspielt. Eine separate Installation ist nicht nötig:

1. `Vicious SID Player.app` in den Programme-Ordner ziehen (das DMG enthält eine Verknüpfung).
2. Die App einmal starten — dadurch registriert macOS die Erweiterung und den Dateityp `.sid`.
3. Eine `.sid`-Datei im Finder markieren und die Leertaste drücken: Der Song startet und zeigt Titel, Komponist und Copyright, mit Buttons zum Umschalten zwischen Subtunes.

Falls keine Vorschau erscheint:

- Prüfen, ob die Erweiterung aktiviert ist: Systemeinstellungen öffnen, nach „Erweiterungen“ suchen und unter Quick Look **Vicious SID Quick Look** aktivieren.
- Quick-Look-Cache im Terminal zurücksetzen: `qlmanage -r`, dann erneut die Leertaste drücken.
- Vorschau direkt im Terminal testen: `qlmanage -p /pfad/zu/tune.sid`.

Voraussetzung: macOS 13 oder neuer.

---

## Headless / CLI (für Skripte und AI-Agenten)

Der Emulations-Kern läuft auch ohne GUI. Das Werkzeug `sidcheck` macht ihn für Shell-Skripte, CI-Pipelines und AI-Agenten nutzbar — maschinenlesbare Ausgabe, skriptfreundliche Exit-Codes (`0` = Erfolg, `1` = Fehler bei `--dump`/`--wav`, `2` = Aufruf falsch):

```bash
swift build -c release          # baut .build/release/sidcheck

# Tune schneller als Echtzeit als WAV rendern (16-bit PCM mono, 44,1 kHz)
.build/release/sidcheck tune.sid --wav out.wav 180 0     # 180 Sekunden, Subtune 0

# SID-Register-Zustand (Frequenz, Gate, Waveform, Hüllkurve je Stimme) als JSON
# dumpen, ein Frame alle 20 ms — z. B. für Noten- oder Sound-Parameter-Analysen
.build/release/sidcheck tune.sid --dump analyse.json 15

# Crash-Sweep: alle Subtunes kurz anspielen; der Prozess stirbt nur bei Emulator-Traps
.build/release/sidcheck tune.sid
```

---

## Linux (CLI-Player)

Der Emulationskern ist plattformneutral, deshalb läuft der Player auch unter Linux — als Kommandozeilen-Player namens `vicious-sid`. Eine native Linux-GUI gibt es nicht; dafür ist der HTML5-Player da.

**Voraussetzungen:** Swift 6.0 und `libasound2-dev` zum Bauen, `libasound2` zur Laufzeit. Das Binary linkt immer gegen `libasound.so.2`, auch beim WAV-Export.

```bash
sudo apt install libasound2-dev

swift build     # ohne Sonderflags: die Apple-Targets (App, Quick Look) sind
swift test      # unter Linux gar nicht erst Teil des Pakets
```

Aufruf:

```bash
vicious-sid tune.sid                    # Echtzeit-Wiedergabe über ALSA
vicious-sid tune.sid --subtune 2        # Subtune wählen (0-basiert)
vicious-sid tune.sid --seconds 30       # nach 30 Sekunden beenden
vicious-sid tune.sid --wav out.wav      # schneller als Echtzeit rendern

# Rohes PCM in eine Pipe (s16le, interleaved)
vicious-sid tune.sid --stdout | aplay -f S16_LE -r 44100 -c 2
```

Läuft ein Tune am Terminal, steuern ihn einzelne Tasten: **Leertaste** pausiert und setzt fort, **n** und **p** blättern durch die Subtunes, **q** oder **Strg-C** beendet. Hängt stdin nicht an einem Terminal — in einem Skript oder CI-Job —, entfällt die Tastatursteuerung und der Player spielt einfach.

Die Wiedergabe läuft über ALSA und funktioniert damit auch mit PipeWire und PulseAudio. Alles Menschenlesbare — Titel, Autor, Fehler — geht nach stderr, damit stdout ein sauberer Audiostrom bleibt. Exit-Codes: `0` = Erfolg, `1` = Argument- oder Parser-Fehler, `2` = I/O-Fehler.

Ein eigenständiges Binary zur Weitergabe:

```bash
swift build -c release --product vicious-sid --static-swift-stdlib
```

Die WAV-Ausgabe ist zwischen dem macOS- (arm64) und dem Linux-Build (x86_64) byteidentisch — die Emulation rechnet auf beiden dieselben Samples. Geprüft auf Linux Mint 22.2 (Ubuntu-24.04-Basis), x86_64, Swift 6.0.3.

---

## Technischer Hintergrund

### SID-Emulation

Der Emulator für den MOS 6581/8580 SID-Chip und den 6502-CPU-Core basiert auf **jsSID 0.9.1** von Hermit (Mihály Horváth, 2016, WTFPL-Lizenz).

Gegenüber dem Original wurden folgende Korrekturen vorgenommen:

- **6502-Opcode-Maske**: `IR & 0xF0` statt `IR & 0xC0` für implizierte Opcodes. Die fehlerhafte Maske führte dazu, dass Befehle wie `INX`, `TAY`, `PHP` und `PLP` nicht ausgeführt wurden — viele Songs blieben stumm oder froren ein.
- **AudioWorklet-Architektur**: Die Engine wurde als eigenständige Klasse implementiert statt als Unterklasse von `AudioWorkletProcessor`, was den Konstruktorfehler im Browser beseitigt.
- **Noise-Waveform und ENV3-Readback**: An die korrekte jsSID-Referenz angeglichen.
- **Swift-Port**: Korrekte 24-Bit-XOR-Verschiebungen für kombinierte Wellenformen und Array-Schutzguards gegen Out-of-Bounds-Zugriffe.

### Architektur

| Schicht | HTML5 | macOS (Swift) |
|---|---|---|
| Parser | `sidplayer.js` | `SidParser.swift` |
| DSP / Emulator | `sid-player-worklet.js` (AudioWorklet) | `ViciousProcessor.swift` (`AVAudioSourceNode`) |
| UI | Vanilla JS + CSS Custom Properties | SwiftUI + Canvas |

---

## Build

### HTML5

```bash
python3 build.py                  # → vicious-sid-player.html (~50 KB)
python3 build.py --no-min         # ohne Minifizierung
```

### macOS App

```bash
bash build_app.sh                 # → "Vicious SID Player.app"
```

Die App baut ihre Playlist beim Start aus einem Autoplay-Ordner, rekursiv durchsucht (Unterordner inbegriffen). Der Ordner lässt sich in den App-Einstellungen frei wählen (App-Menü → „Einstellungen…", Cmd+,); ohne eigene Auswahl gilt `~/Music/Vicious SID Player/`. Die eigenen `.sid`-Dateien dort hineinlegen; sie werden beim Start automatisch geladen. Ein Ordnerwechsel in den Einstellungen lädt die Playlist sofort neu. Der Ordner liegt außerhalb des Repositorys und wird nie veröffentlicht.

Für Release-Builds signiert `build_app.sh` automatisch mit der Developer-ID
`Developer ID Application: Daniel Mueller (9QSWKSR4NQ)`, sofern sie im
Schlüsselbund verfügbar ist. Lokale unsignierte Builds sind mit
`SIGN_APP=0 bash build_app.sh` möglich.

Die Quick-Look-Erweiterung wird als Teil des App-Bundles gebaut
(`Contents/PlugIns/ViciousSIDQuickLook.appex`) und ist damit automatisch in
jedem App-Build und DMG enthalten.

### DMG (für Releases)

```bash
bash build_dmg.sh                 # → build/Vicious SID Player.dmg
NOTARY_PROFILE=<profil> bash build_dmg.sh --notarize   # DMG signieren, notarisieren und stapeln
```

Das DMG enthält ein Retina-kompatibles Hintergrundbild (1x/2x TIFF via `tiffutil`).
Für die Notarisierung wird ein notarytool-Keychain-Profil erwartet, übergeben
über die Umgebungsvariable `NOTARY_PROFILE`. Es kann einmalig interaktiv
angelegt werden:

```bash
xcrun notarytool store-credentials <profil>
```

### Tests

```bash
swift test
```

---

## GitHub-Veröffentlichung

```bash
bash publish_github.sh --dry-run --release
bash publish_github.sh --release
```

Das Veröffentlichungsskript setzt `origin` auf
`https://github.com/DanielMuellerIR/vicious-sidplayer.git`, blockt versehentlich
getrackte Audio- und Release-Artefakte und erzeugt bei `--release` den passenden
GitHub-Release-Eintrag mit DMG-Asset.

## Herkunft

Die SID- und CPU-Emulation wurde aus dem JavaScript-Projekt **jsSID** von Hermit portiert und um die oben genannten Bugfixes erweitert. Die native macOS-App ist eine vollständige Neuimplementierung in Swift.

## Lizenz

**WTFPL** — siehe [LICENSE](LICENSE).
