# AGENTS.md — Vicious SID Player

Universelle Referenz und Dokumentation für alle Coding-Agents und KI-Modelle.

> **Projektname:** Vicious SID Player (Anspielung auf Sid Vicious)
> **Status:** v1.0.2 — HTML5 + native macOS SwiftUI App, komplett umbenannt.

---

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
├── README.md                 ← GitHub-README
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
│   │   └── DSP/
│   │       ├── ViciousProcessor.swift      ← C64 CPU + SID Emulator (Swift)
│   │       └── ViciousCoordinator.swift    ← AVAudioEngine Host
│   └── ViciousSIDPlayerApp/
│       ├── AppMain.swift
│       └── UI/
│           ├── Theme.swift
│           ├── MainView.swift
│           └── OscilloscopeView.swift
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

**Keine gebundelten SIDs:** Copyright-geschützte SID-Dateien werden nicht im Repo oder in Builds mitgeliefert. Die App scannt lokale `audio/`-Verzeichnisse beim Start.

**Dark/Light Mode (HTML):** CSS Custom Properties (`--bg-primary`, `--bg-panel`, etc.) mit `@media (prefers-color-scheme: dark)` Auto-Detection und manuellem Toggle via `.theme-dark` / `.theme-light` Klassen.

**DMG-Background:** Retina-kompatibel via `tiffutil -cathidpicheck` (1x 600×600 + 2x 1200×1200 TIFF).

**Duplikaterkennung:** Playlist filtert beim Hinzufügen auf doppelte Dateinamen.

---

## Lizenzen

- **jsSID 0.9.1** — Hermit (Mihály Horváth), WTFPL
- **Dieses Projekt** — WTFPL

---

## Aktuelle Todos

- [x] **Todo 1**: Release-Builds fuer macOS absichern: App und DMG per Developer ID signieren, DMG notarisieren/stapeln, Publish-Script gegen Audio-/Release-Artefakte haerten und README aktualisieren.
- [x] **Todo 2**: README klarstellen, dass GitHub-Release-DMGs notarisierte Builds sind.
