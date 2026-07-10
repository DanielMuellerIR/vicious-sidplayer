# Recherche: SID-Player-Landschaft (hvsc.c64.org/players)

Stand: 2026-07-10. Vertiefung der Konkurrenzanalyse vom 2026-07-02 — diesmal auf
Basis der vollständigen HVSC-Players-Seite (Angular-SPA; Inhalt aus dem
Lazy-Load-Chunk der Players-Route extrahiert, Stand HVSC #85) plus Einzelrecherche
der wichtigsten Player. Kurzfassung/Priorisierung siehe AGENTS.md
(„Feature-Gaps / Roadmap-Kandidaten").

## 1. Player-Liste (Desktop, direkt relevant)

- **Sidplay5** (macOS) — *der direkte Konkurrent*: Fork von Sidplay4.2/Mac; Universal
  Binary, SLDB, Playlists (einfach + smart), Oszilloskop, Mixer/Voice-Kanäle, Export,
  HVSC-Integration, ASID-MIDI. Bekannte Schwächen laut Repo: UI-Probleme ab macOS 11,
  Digi-Tunes fehlerhaft. https://github.com/Alexco500/sidplay5
- **Sidplay/w 3** (Windows) — Neuauflage von Sidplay2; Stereo-SID (2SID/3SID), SLDB.
  https://csdb.dk/release/?id=221083
- **ACID 64 Player** (Windows) — Referenz für Echt-Hardware (HardSID/SIDBlaster/
  USBSID-Pico/Ultimate); cycle-accurate, Instant-Seeking, SLDB, STIL (formatiert),
  SID-ID (Player-Routine-Erkennung), inkrementelle Suche, Voice-Bars, Voice-Muting,
  Filter-Toggle, Silence-Skip. https://www.acid64.com/
- **JSidplay2** (Java, cross-platform + WASM + Android) — Voll-Emulator; Mono bis
  10SID, MUS/P00/PRG, HVSC- und Assembly64-Integration, WhatsSID-Musikerkennung,
  Aufnahme/Streaming, Favoriten. https://haendel.ddns.net/~ken/
- **Phosphor** (Rust; macOS/Win/Linux) — moderner Cross-Platform-Konkurrent: 4 Engines
  (USBSID-Pico, reSID, SIDLite, Ultimate-64-Netzwerk), HVSC-Browser + Assembly64-
  Livesuche, STIL + SLDB, Register-/Tracker-Visualisierung, Session-Restore, Liked
  Tracks, History, Mini-Player, HTTP-Remote-Control + MP3-Streaming, MUS mit
  Karaoke-Modus. https://github.com/sandlbn/Phosphor
- **sidplaywx** (Windows/Linux) — moderne GUI auf libsidplayfp: Instant-Seeking
  (Pre-Render), Subsongs als Playlist-Knoten, Voice-Muting, STIL, SLDB, Zip-Support.
  https://github.com/bytespiller/sidplaywx
- **TrueSID** (cross-platform) — Software-Emu + echte Hardware, HVSC-Browser,
  Playlists. https://csdb.dk/release/?id=259899
- **SidTool** (Windows) — Frontend für Sidplay/w, sidplayfp, VICE-VSID;
  datenbankgestützte Suche über Dateinamen/STIL/SID-Header. https://sidtool.de
- **CLI/Engines:** sidplayfp (2SID/3SID, 6581/8580-Wahl, WAV-Ausgabe), crSID/cSID
  (Hermit), jsSID (JS; unsere Emulations-Basis).
- **Web:** **DeepSID** (Referenz-Webplayer: umschaltbare Emulatoren, 5-Sterne-Ratings,
  STIL formatiert, CSDb-Anbindung, Suche, Direktlinks) https://deepsid.chordian.net/,
  WebSid/Tiny'R'SID, SIDAMP.
- **Plugins:** XMPlay-SIDevo, Foobar2000-foo_sid, VLC, DeaDBeeF, Audacious.
- **Mobil/Retro (Nische):** SidAMP/SIDemu/Modo/ZXTune (Android; ZXTune mit
  Online-HVSC-Streaming), Modizer (iOS), Rockbox, Wii/DS/PSP, Ultimate SID Player,
  u64SidPlayer (Amiga).

## 2. Feature-Matrix (wichtigste Desktop-/Web-Player)

| Feature | Sidplay5 (macOS) | ACID64 | JSidplay2 | Phosphor | sidplaywx | DeepSID | sidplayfp (CLI) |
|---|---|---|---|---|---|---|---|
| SLDB (Songlengths.md5) | X | X | X | X | X | X | X |
| STIL-Anzeige | X | X (formatiert) | X | X | X | X (formatiert) | — |
| HVSC-Browser/-Integration | X (+Update-Tool) | X | X (+Assembly64) | X (+Assembly64) | — | X (komplett online) | — |
| Subsong-Navigation | X | X | X | X | X (als Playlist-Knoten) | X | X |
| SID-Modell 6581/8580 + Filter | X | X | X | X | X | X | X |
| 2SID/3SID | X | X | X (bis 10SID) | X | X | X | X |
| Voice-Muting | X (Mixer) | X | X | X | X | X | X (Flag) |
| Oszilloskop/Visualisierung | X | Voice-Bars | X | Register-/Tracker-View | X | X (Scope/Piano) | — |
| Seeking / Instant-Seek | teils | X (instant) | X | X | X (Pre-Render, instant) | X (FF) | — |
| Export (WAV/MP3) | X | — | X (Aufnahme/Streaming) | MP3-Stream | geplant | — | WAV |
| MUS/CGSC-Support | — | X | X | X (+Karaoke) | — | X | — |
| Playlists/Favoriten | X (auch smart) | X | X (Favoriten) | X (+Session-Restore, History) | X | Ratings/Links | — |
| Suche (inkrementell/DB) | X | X | X | X (Live-Filter) | — | X | — |
| Echt-SID-Hardware / ASID | ASID-MIDI | X (Kernkompetenz) | Netzwerk-SID | X | — | ASID-MIDI | — |
| SID-ID (Player-Routine-Erkennung) | — | X | X | — | — | X | — |
| Musikerkennung (WhatsSID) | — | — | X | — | — | X | — |
| Remote-Control/Headless-API | — | — | Server | HTTP-Server | — | URL-Deeplinks | CLI |

## 3. Priorisierte Empfehlungen

**(a) Pflicht, um mitzuhalten** (haben praktisch alle etablierten Player):
1. **Songlength-DB** (`Songlengths.md5`) — korrekte Spieldauer + Auto-Advance.
2. **Subsong-Navigation** — vorhanden (Subtune-Pfeile); Start-Song aus Header beachten.
3. **STIL-Integration** (Kommentare/Cover-Infos pro Song aus HVSC).
4. **SID-Modell-Auswahl** — vorhanden (Auto/6581/8580); Filter-Einstellungen fehlen.
5. **HVSC-Ordner als Bibliothek** (Browser-Ansicht statt nur Datei-Liste; der
   Autoplay-Ordner ist der Ansatz dafür).
6. **Voice-Muting** und **2SID/3SID-Wiedergabe**.

**(b) Differenzierer, um zu übertreffen:**
1. **Instant-Seeking mit Pre-Render** — flüssiges Scrubbing wie bei MP3 hat kaum
   ein Player; auf Apple Silicon gut machbar (schneller-als-Echtzeit-Render).
2. **Natives, schönes macOS-Erlebnis** — Sidplay5 ist funktional, aber UI-technisch
   veraltet (dokumentierte macOS-11-Probleme); genau da ist die Lücke. Media-Tasten/
   Now-Playing haben wir schon; Mini-Player wäre der nächste Schritt.
3. **HVSC-Auto-Download/-Update in-App** (Version-API existiert:
   `hvsc.c64.org/api/v1/version/7z`) + STIL/SLDB mitpflegen — „Zero-Setup"-Onboarding
   hat auf dem Desktop niemand. ABER: kollidiert mit der Projekt-Philosophie „keine
   externen Assets bündeln" — nur als expliziter Nutzer-Download vertretbar.
4. **Headless-/CLI-/URL-Schnittstelle** (AI-Agent-Doktrin): `--play file.sid
   --subsong 3`, evtl. kleiner HTTP-Remote wie Phosphor.
5. **WAV-Export** — Sidplay5 kann es, sidplaywx erst „geplant".
6. **SID-ID/Player-Routine-Erkennung + Jahr/Tool-Anzeige** (auf Desktop selten).
7. **Session-Restore, Favoriten, History** (Phosphor zeigt, dass das geschätzt wird).

**(c) Nische** (nur bei explizitem Bedarf): Echt-SID-Hardware (USBSID-Pico/
SIDBlaster/Ultimate 64), ASID-MIDI, MUS/CGSC, 10SID, WhatsSID, MP3-Streaming-Server.

## Quellen

- https://www.hvsc.c64.org/players (SPA-Chunk extrahiert)
- https://github.com/Alexco500/sidplay5
- https://www.acid64.com/ + https://github.com/WilfredC64/acid64c
- https://haendel.ddns.net/~ken/
- https://github.com/sandlbn/Phosphor
- https://github.com/bytespiller/sidplaywx
- https://blog.chordian.net/2018/05/12/deepsid/ + https://deepsid.chordian.net/
