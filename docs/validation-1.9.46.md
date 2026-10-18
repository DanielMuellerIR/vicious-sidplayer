# Prüfstand 1.9.46

Stand: 2026-10-18. AP14 reduziert Zeichenarbeit und UI-Timeraufrufe. DSP, Audiothread, Medienbefehle und Wiedergaberegeln bleiben unabhängig von den Zeichenplänen.

## Vergleich auf dem Mac

Verglichen wurden v1.9.45 und v1.9.46 auf demselben Apple M1 mit macOS 26.7.1, demselben 1000 × 700-Punkte-Fenster und identischen eigenen synthetischen 1SID-/3SID-Signalen. Alle Chips werden emuliert, angezeigt wird SID 1. Die Ausgangslautstärke ist null; die Emulation läuft weiter. Persönliche Endzeiten von 600 Sekunden schließen Hintergrund-Längenberechnungen aus. Je Zustand: zwei Sekunden Vorlauf, anschließend drei Messungen von acht Sekunden; angegeben ist jeweils der Median. Während der Messblöcke laufen keine weiteren eigenen Builds oder Simulatoren.

CPU-Zeit und Aufwachzähler stammen aus der öffentlichen [Darwin-API `proc_pid_rusage`](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h); absolute Zeitwerte werden mit `mach_timebase_info` umgerechnet und vor jedem Lauf gegen `getrusage` validiert. CPU-Prozent beziehen sich auf **einen** Kern, nicht auf die gesamte Maschine. Aufwachereignisse sind Prozesszähler, keine Wattmessung.

| SID-Chips | Ansicht | CPU vorher → nachher (% eines Kerns) | Interrupt-Aufwachereignisse/s vorher → nachher |
|---|---|---:|---:|
| 1 | Sichtbar | 49.7 → 45.2 | 103.2 → 56.8 |
| 1 | Ausgeblendet | 51.0 → 20.2 | 116.4 → 17.5 |
| 1 | Mini-Player | 18.7 → 17.3 | 53.0 → 12.9 |
| 1 | Pause | 0.0 → 0.0 | 1.5 → 1.5 |
| 3 | Sichtbar | 62.6 → 58.7 | 113.2 → 82.7 |
| 3 | Ausgeblendet | 63.4 → 34.5 | 105.7 → 27.5 |
| 3 | Mini-Player | 32.0 → 30.7 | 53.2 → 15.2 |
| 3 | Pause | 0.0 → 0.0 | 1.2 → 1.4 |

Die größten Unterschiede entstehen beim Ausblenden: Der bisherige Zeichenplan lief dort weiter. Sichtbar sind die Verbesserungen kleiner. Kurze synthetische Vergleichsläufe belegen weder allgemeine Beschleunigung aller Titel noch eine bestimmte Akkulaufzeit.

## Verhalten und Browser

Der Mac verwendet einen 30-Hz-Zeichenplan. Die eigene Fenster-Sichtbarkeit steuert Oszilloskop und Analyse: Verdeckung, Minimierung und Ausblenden pausieren sie; ein inaktives, weiterhin sichtbares Fenster bleibt aktiv. Der UI-Timer spiegelt sichtbar im 0,1-Sekunden-Takt nur die Spielzeit, verborgen einmal pro Sekunde. Stimmenwerte bleiben unveröffentlicht; der Timer bleibt im `.common`-RunLoop.

Im echten Chrome-Lauf der minifizierten `file://`-Einzeldatei wurden bei 1SID und 3SID vorher jeweils rund 59,9, nachher 30,0 Canvas-Zeichnungen pro Sekunde gemessen; pausiert vorher 59,9, nachher 10,0. Verborgene Seiten zeichneten keine Frames; Audiozeit und Rückkehr liefen weiter. Der Fortschritt in Piano/Register war zuvor an die Scope-Zeichenroutine gebunden und blieb stehen; er wird nun vor der Wahl der Analyseansicht aktualisiert. Der Vorher/Nachher-Lauf bestätigt stehende beziehungsweise fortlaufende Position bei weiterlaufender Audiozeit. Die Phase der idealisierten Kurve verwendet vergangene Zeit, damit der langsamere Zeichentakt ihre Bewegung nicht halbiert.

Dateiladen, Subtune-Tasten, Dialogfokus, Tab-Wechsel, Reglernamen, VoiceOver-Modifiertasten sowie breite und schmale Ansichten sind mit dem finalen Web-Build erneut praktisch geprüft; keine Laufzeitexception.

## iPhone und Prüfungen

Der iPhone-Zeichenplan erhält zusätzlich die Auswahl des Wiedergabe-Tabs und pausiert außerhalb dieses Tabs oder einer aktiven Szene. Im sichtbaren Wiedergabe-Tab benötigen Spielzeit/Scrubber keinen 50-Hz-Timer; in anderen Tabs genügen wie im Hintergrund 1 Hz. Audio und der eigene 1-Hz-Lauf für Auto-Next/Now Playing werden dadurch nicht angehalten.

- 408 Swift-Tests, davon vier plattformbedingt übersprungen, ohne Fehler; der neue Audiotest belegt weiterlaufende Play-Routine und Erholung der Zeitspiegelung beim Wechsel 0,1 → 1 → 0,1 Sekunden.
- 107 Webtests, beide Buildtests und Fleet-Regeln ohne Fehler.
- Mac-Bundle sowie iOS-SDK 27 und 26.5 erfolgreich gebaut, ohne Warnungen im eigenen iOS-Code. Die App-Intents-Metadatenmeldung stammt vom Buildwerkzeug.
- 68 tatsächlich ausgeführte iOS-Simulator-Tests ohne Fehler; der neue Integrationstest bestätigt Auto-Next bei langsamer Hintergrund-UI und weiterlaufende Wiedergabe nach Rückkehr.
- Die native Mac-App behält beim Ausblenden und Minimieren ihre fortlaufende Spielzeit. Der Mini-Player verwendet dieselbe Hauptfenster-ID; nach Rückkehr zeichnet der Scope wieder. Auto-Next wechselt bei ausgeblendeter App vom kurzen Testtitel zum nächsten Titel.
Der Simulatorvergleich verwendet dieselbe eigene 3SID-Datei, denselben M1, iOS-Simulator 26.5 und Debug-Builds desselben SDK 26.5/Xcode 26.6. Pro Zustand folgen nach zwei Sekunden Vorlauf drei Messungen von fünf Sekunden; angegeben ist der Median.

| Simulatoransicht | CPU vorher → nachher (% eines Kerns) | Interrupt-Aufwachereignisse/s vorher → nachher |
|---|---:|---:|
| Wiedergabe | 73.6 → 74.8 | 164.0 → 139.7 |
| Bibliothek | 74.7 → 74.8 | 154.4 → 125.5 |
| Einstellungen | 74.8 → 75.4 | 154.6 → 124.5 |
| Hintergrund | 68.4 → 63.2 | 5.2 → 5.8 |
| Rückkehr | 75.4 → 75.3 | 140.1 → 117.1 |

In aktiven Simulatoransichten ist kein belastbarer CPU-Gewinn zu erkennen; die Prozess-Aufwachrate sinkt. Die Werte sind keine Energie- oder Akkumessung. Nach Tab- und Szenenwechseln läuft die Wiedergabe weiter; die Rückkehr zeigt wieder Scope, laufende Spielzeit und Pause-Control. Der eigene Simulator wurde heruntergefahren und seine ursprünglichen Dokumente, Supportdateien und Einstellungen byteweise restauriert.

Echte iPhone-Hintergrundwiedergabe, Sperrbildschirm, Medienzubehör und Energie bleiben ausdrücklich Teil der [Geräteabnahme](../ios/GERAETETEST.md). Simulatorwerte erlauben keine Aussage zur Akkulaufzeit oder zum Verhalten bei realer Suspendierung. Eigene Testdaten werden restauriert und eigene Prozesse beendet; SID-Musik und Audioaufnahmen werden nicht versioniert.
