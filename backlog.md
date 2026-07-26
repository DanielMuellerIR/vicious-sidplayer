# Aktiver Backlog

0. iOS-App fürs iPhone: Plan und Goal-Prompt liegen in
   [tasks/2026-07-26-ios-app/](tasks/2026-07-26-ios-app/plan.md). Entschieden sind
   Sideload mit offener App-Store-Option, eingechecktes `.xcodeproj` mit
   synchronized groups, Import über rekursiven Ordner-Picker plus
   Finder-Dateifreigabe und iOS 17 als Minimum. Blockierender erster Schritt ist
   der Nachweis, dass der Core für `iphonesimulator` baut. Erledigt nebenbei die
   Punkte 2 und 3 dieser Liste für iOS.
1. STIL-Integration aus einer vom Nutzer bereitgestellten HVSC-`STIL.txt`; Auto-Fund
   nach dem vorhandenen Songlength-Muster, kein Bundling der Datenbank.
2. HVSC-Browser/Bibliotheksansicht für große Sammlungen statt ausschließlich flacher
   Playlist.
3. Mini-Player mit Titel und Transportsteuerung.
4. HTTP-Remote oder URL-Schema nur als kleiner, abgesicherter Agenteneinstieg; CLI ist
   bereits der primäre Headless-Weg.
5. Filter-Cutoff-Tuning für 6581. Ersetzt dauerhaft einen vollständigen reSIDfp-Port
   (Entscheidung 2026-07-15): holt den hörbaren Teil des Gewinns ohne Engine-Umbau.
6. Öffnen-Dialog auf `.sid` filtern (`MainView.swift:532`): `fileImporter` nutzt
   `allowedContentTypes: [.data]` und zeigt daher jede Datei. Den in der Info.plist
   deklarierten UTI `com.viben.sid-tune` (bzw. `UTType(filenameExtension: "sid")`) als
   zentrale Konstante nutzen, dann filtert macOS nativ. Quelle: Code-Review-Triage
   2026-07-24.

In Arbeit: Linux-Port (CLI + Audio-Backend) nach `tasks/2026-07-05-linux-port/plan.md`.

Permanent zurückgestellt, nur Kandidaten für schlimme Langeweile: Audiofingerprint/
WhatsSID (bräuchte serverseitige Fingerprint-DB über die HVSC), MUS/CGSC (eigenes Format
plus eigene Player-Routine für einen kleinen Sammlungszweig).

Gestrichen: ASID/Echt-SID-Hardware (2026-07-15) — nicht wieder aufnehmen.

Erledigte Release-/Quick-Look-/v1.5.0-Arbeit nicht zurückführen.
