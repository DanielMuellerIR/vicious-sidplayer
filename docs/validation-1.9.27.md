# PAL/NTSC — Umsetzung und Prüfung in v1.9.27

Stand: 2026-10-16.

Der Parser übernimmt die Taktangabe aus PSID-/RSID-v2–v4-Dateien. Auto wählt
NTSC bei eindeutiger NTSC-Angabe, sonst PAL. Die nativen Apps und der HTML5-Player
bieten zusätzlich einen ausdrücklichen Override. Das CLI verwendet dafür
`--clock auto|pal|ntsc`.

Die gemeinsame native Taktdefinition steuert CPU und SID-Oszillatoren, VBI,
CIA-Startwert und die PAL/NTSC-Kennung im emulierten RAM. Seek, WAV-Export und
Songlängenberechnung übernehmen dieselbe Wahl. Berechnete Längen werden je
Taktmodus getrennt gespeichert; alte, stets mit PAL berechnete Einträge werden
nicht übernommen. HVSC-Dauern bleiben die kuratierten Angaben, auch bei einem
bewussten Override. Die Hertz-Anzeigen verwenden den wirksamen CPU-Takt.

Beim Browserlauf fiel außerdem auf, dass die bisherige Satzzeichen-Minifizierung
Leerzeichen innerhalb von JavaScript-Strings entfernte. String- und
Template-Literale bleiben nun auch in diesem Verarbeitungsschritt erhalten.

## Ergebnisse

- `swift test`: 233 Tests, 4 übersprungen, keine Fehler. Die übersprungenen
  Fälle benötigen eine lokale Musikdatei; die neuen Timing-Fälle sind vollständig
  synthetisch und wurden ausgeführt.
- Zehn Timing-Tests: Headerflags, Fallback, Override, VBI-Aufrufrate, CIA-Startwert,
  eigener CIA-Timer, dynamischer CIA-Latch, Tonhöhe, WAV, Seek, pausierter
  Taktwechsel, Songlängen und getrennter Cache.
- Web-Suite: 17 Tests ohne Fehler. String-Minifizierung: unabhängiger Vergleich
  der ausgeführten Original- und Build-Ausgabe erfolgreich.
- Native/HTML5-Parität für PAL und NTSC: jeweils 88.200 PCM-Samples bitgenau gleich.
- CLI-Regressionen einschließlich Taktwahl, falscher Taktoption und externer
  Stoppsignale erfolgreich. Fleet-Regeln erfolgreich.
- iOS-Build für `generic/platform=iOS Simulator` und Simulator-Tests erfolgreich;
  keine Warnungen im eigenen Code. Xcode meldet die fehlende, nicht benötigte
  AppIntents-Metadatenextraktion.
- Notarisiertes macOS-Bundle v1.9.27: Auto/NTSC, PAL und Rückkehr zu Auto bedient.
  Der synthetische Frequenzwert 8192 wird als 499 Hz bei NTSC und 481 Hz bei PAL
  angezeigt. Beide Ansichten visuell geprüft.
- iPhone-Ansicht im Simulator: Auto/NTSC und erzwungenes PAL bei NTSC-Datei
  bedient und visuell geprüft; Tab-Leiste und Analysecontrols erreichbar.
- Minifizierte Single-File-Ausgabe unter `file://` im Browser: Datei geladen,
  Auto/NTSC, PAL und Rückkehr zu Auto geprüft und visuell angesehen.

## Grenzen

VBI verwendet weiterhin die nominalen 50/60 Hz. Die Engine wird dadurch kein
vollständiger C64-Emulator; spezielle RSID-Umgebungen und weitere Taktvarianten
gehören zur gesonderten Kompatibilitätsarbeit. Reale iPhone-Audiohardware,
Sperrbildschirm und Unterbrechungen sind durch die Simulatorprüfung nicht belegt.
