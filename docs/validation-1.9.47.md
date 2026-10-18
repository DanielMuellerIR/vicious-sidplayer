# Prüfstand 1.9.47

Stand: 2026-10-18. AP15: Die bisherige 44,1-kHz-Kurve ist die ausdrücklich gewählte Klangreferenz; andere Ausgaberaten werden daran angeglichen. Ziel ist die Erhaltung dieses Klangs, keine neue Nachbildung einer bestimmten 6581-Revision.

## Reproduktion und Umsetzung

Ein eigener synthetischer Sägezahnton mit Tiefpass und Resonanz 0 schaltet nach vier Sekunden den Cutoff von 190 auf 191. Vorher sinkt dabei der um den Gleichanteil bereinigte Effektivpegel bei 48 kHz um 10,5634 dB, bei 44,1 kHz um 0,1489 dB. Native und HTML5 reproduzieren denselben Fehler.

Die bisherige 44,1-kHz-Kurve wird als Referenz berechnet. Für andere Raten gilt `k = 1 − (1 − k_ref)^(44100 / samplerate)`. Bei 44,1 kHz entfällt die Umrechnung ausdrücklich, damit die ursprünglichen Werte bitgenau bleiben. Alle 2048 Koeffizienten werden einmal je Emulator erzeugt; im Audiopfad steht ein Tabellenzugriff. Die unveränderliche Tabelle hängt nur von der festen Samplerate ab und muss daher bei A/B-Rücksprüngen nicht kopiert werden.

## Prüfung

Die neuen End-to-End-Regressionen scheitern vor der Korrektur in Native und HTML5 am 48-kHz-Pegelabfall; die 44,1-kHz-PCM-Prüfsumme stimmt bereits vorher. Nach der Korrektur bestehen beide Regressionen: Bei 48 kHz beträgt der Pegelunterschied nun rund −0,1488 dB. Die nativen Koeffizientenprüfungen und der Web-Syntheselauf mit maximalem Cutoff/Resonanz decken 8/22,05/32/44,1/48/96/192 kHz ab.

- macOS: 410 Swift-Tests, vier plattform-/referenzbedingte Skips, keine Fehler; zusätzlich optimierter Core-Build mit Swift 6.4 und Warnungen als Fehler.
- HTML5: 109 Node-Tests, beide Buildvarianten und zwei Python-Buildtests bestanden. Die lokale Einzeldatei läuft unter `file://` mit echtem AudioWorklet bei 48 kHz. 397.312 abgegriffene Ausgabeframes belegen −0,14876 dB beim Cutoff-Wechsel; Mute, Fortsetzung, Worker-A/B-Schleife und Seek bestanden, keine Browserausnahme.
- Linux x86_64: 368 Swift-Tests unter Swift 6.0.3, fünf Skips, keine Fehler.
- iOS: 68 Simulator-Tests bestanden; Simulator-Builds gegen SDK 26.5 und 27 sowie unsignierter Geräte-Build gegen SDK 26.5 erfolgreich. Keine Warnung aus dem eigenen Code; das SDK-27-Werkzeug meldet lediglich den entfallenden AppIntents-Metadatenexport.
- Native Mac-App: Developer-ID-Bundle gebaut und Signatur geprüft. Eigene gefilterte 1SID-/3SID-Signale laufen sichtbar; Pause hält die Zeit an, Seek im pausierten Zustand und Fortsetzung funktionieren. Beide Ansichten visuell geprüft. Testdaten und ursprüngliche Einstellungen nach dem Lauf wiederhergestellt.
- Fleet-Regeln bestanden; keine Installation oder Notarisierung ausgeführt.

512 Cutoff-/Resonanz-/Filterkombinationen und 160 zusätzliche PAL-/NTSC-Neun-Stimmen-Fälle ergeben insgesamt 7.736.400 PCM16-Frames mit bitgenauer Native-/HTML5-Parität. Alle Rohwerte sind endlich. Acht bereits bestehende Clipping-Samples der 8580-Stressfälle bleiben unverändert; die geprüften 6581-Fälle clippen nicht.

Alle 2048 bisherigen 44,1-kHz-Koeffizienten sind bitgenau erhalten. Gegen v1.9.46 bleiben außerdem 4.358.400 ungerundete Double-Frames in 384 Konfigurationen bitgenau gleich: beide Modelle bei 44,1 kHz und 8580 bei 48 kHz. Der 6581-Referenzlauf hat weiterhin die PCM16-MD5 `96a6bebb36bf3d3756d594cc1dd96ed3`.

Ein optimierter DSP-Vergleich mit 24 Einzelmessungen (je drei Wiederholungen, 1SID/3SID, 44,1/48 kHz, vorher/nachher) zeigt keine zusätzliche Prozess-CPU-Last. Die Mediane nachher liegen bei 0,0178–0,0563 CPU-Sekunden je erzeugter Audiosekunde, vorher bei 0,0188–0,0568. Die Initialisierung bleibt bei rund 12,4–12,7 ms. Die Tabelle belegt 16 KiB je Emulator. Diese Messung betrifft die Emulation, nicht den Energieverbrauch der ganzen App oder die Akkulaufzeit.

## Grenzen

Die Umrechnung übernimmt die Zeitkonstante der bestehenden Integratorkoeffizienten. Sie behauptet weder identische zeitdiskrete Frequenzantworten bei verschiedenen Raten noch Hardwaretreue gegenüber einem realen 6581. Das lokale Vergleichssignal und die ursprüngliche Kurve bleiben als A/B-Referenz erhalten. Reale iPhone-Hintergrund-, Medien- und Kopfhörerprüfungen bleiben Geräteabnahme.
