# Vicious SID Player

Ein eigenständiger Commodore-64-SID-Musikplayer in zwei Varianten:

1. **HTML5 (`vicious-sid-player.html`)** — Eine einzelne HTML-Datei (~50 KB), die ohne Webserver direkt per Doppelklick aus dem Dateisystem funktioniert.
2. **Native macOS App (`Vicious SID Player.app`)** — SwiftUI-Desktop-Anwendung mit `AVAudioEngine` und Echtzeit-Oszilloskop.

Beide Varianten enthalten keine SID-Dateien. Musikstücke werden per Drag & Drop oder Datei-Dialog geladen.

---

## Download

Fertige Builds der macOS-App stehen als DMG auf der [Releases-Seite](https://github.com/DanielMuellerIR/vicious-sidplayer/releases) bereit. DMG herunterladen, öffnen und die App in den Programme-Ordner ziehen.

Der HTML5-Player benötigt keinen Download über die Releases hinaus: Die Datei `vicious-sid-player.html` lässt sich direkt im Browser öffnen.

---

## Funktionsumfang

- **Drag & Drop**: Einzelne `.sid`-Dateien oder ganze Ordner können auf den Player gezogen werden. Die Wiedergabe startet sofort.
- **Echtzeit-Oszilloskop**: Zeigt die Wellenformen der drei SID-Stimmen (Dreieck, Sägezahn, Puls, Rauschen) samt Frequenzen, Gate-Status und ADSR-Hüllkurven.
- **Dark / Light Mode**: Automatische Erkennung der Systemeinstellung oder manuelles Umschalten.
- **Playlist mit Duplikaterkennung**: Bereits geladene Titel werden nicht doppelt aufgenommen. Die Playlist kann jederzeit geleert werden.
- **Keine externen Assets**: Die gesamte Oberfläche (inkl. macOS-Fensterdekorationen und Icons) ist rein prozedural in CSS bzw. SwiftUI Canvas gezeichnet.

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

Die App sucht beim Start nach einem `audio/`-Verzeichnis neben der Anwendung und lädt dort gefundene `.sid`-Dateien automatisch in die Playlist.

### DMG (für Releases)

```bash
bash build_dmg.sh                 # → build/Vicious SID Player.dmg
```

Das DMG enthält ein Retina-kompatibles Hintergrundbild (1x/2x TIFF via `tiffutil`).

### Tests

```bash
swift test
```

---

## Herkunft

Die SID- und CPU-Emulation wurde aus dem JavaScript-Projekt **jsSID** von Hermit portiert und um die oben genannten Bugfixes erweitert. Die native macOS-App ist eine vollständige Neuimplementierung in Swift.

## Lizenz

**WTFPL** — siehe [LICENSE](LICENSE).
