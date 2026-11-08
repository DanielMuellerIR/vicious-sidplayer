# Prüfstand 1.9.54

Stand: 2026-11-08. Flüssigeres Linux-Oszilloskop mit gespeicherter Wahl zwischen
Flüssig (ca. 60 FPS), Sparsam (15 FPS) und Aus in den Einstellungen.

## Ursache und Änderung

Die bisherige Linux-Ansicht zeichnete erst nach einer Core-Antwort neu, nominal
alle 33 ms. Die Mac-Ansicht verwendet ebenfalls einen 30-Hz-Zeichenplan, aber
einen eigenen Animationstakt. Eine Linux-Vorgabe zur Begrenzung besteht nicht.
Zusätzlich war das Rastern dicht gefalteter `QPainterPath`-Konturen teuer.

Die Kurven werden nun unabhängig mit einem präzisen lokalen Timer gezeichnet.
Einzelne geglättete Liniensegmente mit gleicher sichtbarer Linienstärke ersetzen
die aufwendige zusammenhängende Kontur. Stille Stimmen benötigen nur eine Linie;
unveränderte Symbole werden wiederverwendet. Die Kurvengleichungen und die
Audio-Emulation bleiben erhalten. Dies ist eine aus SID-Registern erzeugte
Visualisierung, keine Darstellung aufgenommener PCM-Samples.

Flüssig fragt den Core weiter mit etwa 30 Hz ab, Sparsam mit 15 Hz. Aus,
Mini-Player und unsichtbare/minimierte Fenster überspringen SID-Anzeigesnapshots.
Pause hält die Animation an und reduziert Abfragen auf 10 Hz. Piano und Register
bleiben bei laufender Wiedergabe unabhängig von der Oszilloskop-Einstellung mit
etwa 30 Hz versorgt; unveränderte Ansichten werden nicht erneut gezeichnet.

## Prüfung und Messung

Linux x86-64, Python 3.12.3, Qt/PySide 6.12.0, isoliertes X11/Xvfb und D-Bus,
lautlose eigene PipeWire-Senke. Vergleich gegen die Python-Oberfläche von
`904afbe`, mit derselben Release-Engine und derselben synthetischen SID-Datei.
Ein fester Dreieckton und eine mitgelieferte synthetische Längenangabe verhindern
Tonwechsel und eine parallele Hintergrundschätzung während der Messung.
Je Modus wurden nach kurzer Beruhigung zwei Sekunden gemessen. CPU-Werte sind
Prozent eines logischen Kerns, getrennt für Oberfläche und Audio-Engine.

| Zustand | Tatsächliche Zeichenereignisse/s | CPU Oberfläche | CPU Engine |
| --- | ---: | ---: | ---: |
| Vorher | 31,0 | 91,0 % | 9,5 % |
| Flüssig | 62,9 | 26,4 % | 9,8 % |
| Sparsam | 14,7 | 7,8 % | 5,8 % |
| Aus | 0,0 | 1,9 % | 4,2 % |

Die längste Bildpause im gemessenen Flüssig-Abschnitt betrug 16,8 ms. Die Werte
sind kurze Vergleichsmessungen, keine allgemeine Last- oder FPS-Garantie.

- Release-Engine und Linux-App erfolgreich gebaut. Bekannte Linkerwarnung aus
  Swift Foundation zu `mktemp`, keine neue Warnung im eigenen Swift-Code.
- `linux/tests/scope_animation.py`: Zeichentakt unabhängig vom Core, beide
  Sparoptionen per Tastatur, weiter verfügbare Piano-/Registerdaten, Piano-Reaktion
  bei Stopp, eingefrorene Pause, Mini-Player, Minimieren und Wiederherstellen,
  Aus-/Einblenden und gespeicherter Modus nach Neustart bestanden. Der direkte
  Pipe-Test belegt das Weglassen von `chips` sowie den kompatiblen Standardwert.
- `linux/tests/gui_smoke.py`: Transport, Pause/Seek, Lautstärke, Modell/Takt,
  Subtune, Favorit/Suche, 3SID, Mute/Solo, Hörliste/Hörfolge, Marken/Notizen und
  Mini-Player bestanden.
- Helle und dunkle Kurven, Einstellungen und abgeschaltetes Oszilloskop bei
  800 × 560 visuell anhand der tatsächlich gerenderten Fenster geprüft.
- Fleet-Regelprüfung, Python-Kompilierung und Diff-Whitespace-Prüfung bestanden.

## Grenzen

Xvfb belegt Zeichenereignisse und Reaktionen der echten Qt-Oberfläche, aber weder
die Präsentation am physischen Monitor noch Compositor-Timing, Wayland oder
Akkulaufzeit. Die installierte Anwendung wurde nicht ersetzt. Keine Änderungen
an macOS, iOS oder dem anderen Player; kein Release veröffentlicht.
