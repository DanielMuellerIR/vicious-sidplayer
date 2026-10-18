# Prüfstand 1.9.49

Stand: 2026-10-18. Nacharbeit aus der iPhone-Nutzung.

## Verhalten

Eine Bibliotheksauswahl während laufender Musik lädt und startet jetzt den
neuen Titel. Aus Pause oder Stop sowie bei der Sitzungswiederherstellung
bleibt die Auswahl vorbereitet. Fehlende oder beschädigte Dateien ersetzen
den bisherigen Titel nicht. Fehlt der SID-Header-Titel, liefern die nativen
Apps den Dateinamen ohne Erweiterung als Titel an den Koordinator.

Die iPhone-Bibliothek verwendet zwei kompakte Metadatenzeilen. Die vier
Sammlungsansichten stehen fest über der Suche. Im Wiedergabe-Tab sitzen Mute
und Solo rechts neben den drei Kurven des gewählten Chips; das Mischmenü
erhält Zugriff auf alle Chips und Stimmen in den anderen Analyseansichten.
Abschnittsschleife, vollständige Informationen und Export liegen unter
„Werkzeuge und Details“. Startpunkt, Endpunkt und Wiederholen ersetzen die
isolierten A/B-Bezeichnungen.

Bei unbekannter Songlänge gilt weiterhin das gemeinsame Limit von sechs
Minuten je Subtune. Die Positionsleiste zeigt dafür ausdrücklich „Max. 6:00“.
Eine ganze Datei spielt mit Auto-Next ihre verbleibenden Subtunes, danach
folgt der nächste Eintrag. Die Bibliothek läuft in Durchläufen weiter;
ausdrücklich gestartete Auswahlen und gespeicherte Listen enden am Listenende.

## Reproduktion und Prüfungen

- Vor der Korrektur scheitern die gezielten Erwartungen für laufende
  Bibliotheksauswahl und Dateinamen im Player. Ein unveränderter
  Vordergrundwechsel besteht bereits im Ausgangsstand.
- Core-Suite: 411 Tests, vier Überspringungen wegen einer fehlenden optionalen
  SID-Referenzdatei, keine Fehler.
- Simulator-Builds gegen iOS-SDK 26.5 und 27 sowie unsignierter generischer
  Geräte-Build gegen SDK 26.5 erfolgreich. Keine Warnung aus dem eigenen Code;
  das AppIntents-Werkzeug meldet den entfallenden Metadatenexport.
- Eine optimierte Diagnose durchläuft den echten Emulationssprung bis zur
  Sechs-Minuten-Grenze und den anschließenden Wechsel über den Hintergrundtask.
  Vier aufeinanderfolgende tatsächliche Songenden einschließlich
  Bibliotheksumlauf und Rückkehr in den Vordergrund bestehen ebenfalls.
  Der erste lange Sprung im Debug-Build überschritt das Testzeitfenster;
  daraus wird kein Produktfehler abgeleitet.
- Gesamte iOS-Suite: 80 Tests ohne Fehler. Zusätzliche Fälle durchlaufen
  fünf Shuffle-Wechsel ohne unmittelbare Wiederholung, mehrere Subtunes und
  mehrere Dateien über den echten 1-Hz-Task. Audio-Session-Callbacks sind
  dabei verdrahtet; Vordergrundwechsel erhalten laufende Wiedergabe.
- Fleet-Regeln bestanden.

Die betroffenen Ansichten wurden im tatsächlichen Simulatorlauf visuell geprüft:

- iPhone 17 Pro Max (440 × 956 pt) und iPhone 17 Pro (402 × 874 pt):
  normale Wiedergabe mit einem oder drei Chips sowie Subtunes ohne Scrollen.
  Bibliothekszeilen sind 52 pt hoch; auf der großen Ansicht bleiben im
  Beispielordner zehn vollständige Titel oberhalb des Mini-Players sichtbar.
- Musik, Listen, Folge und Verlauf bleiben auf gleicher Höhe. Suche,
  ungültiges Suchfeld und Suchhilfe sind erreichbar; Fehler stehen unter dem
  Suchfeld und ändern dessen Breite nicht.
- Laufende Auswahl startet den neuen Titel, fehlender Header-Titel erscheint
  als Dateiname. Chipwahl, Mute/Solo, Filter, Piano, Register, Mischmenü und
  die ausklappbare Abschnittsschleife wurden bedient. Die Schleife wird
  vollständig vorbereitet; Ein-/Ausschalten und Löschen funktionieren.
- Maximale Bedienungshilfen-Schrift im Dunkelmodus: Texte umbrechen und bleiben
  scrollbar. Symbole in festen 44-pt-Flächen erhalten eine passende feste
  Größe. Die erste Sichtprobe hatte dort übergroße Symbole gezeigt; die
  Korrektur ist erneut im Lauf geprüft. Ausgeklappte Details und der
  Exportknopf lassen sich vollständig über die Tab-Leiste scrollen.

Die gesamte iOS-Suite besteht auch nach dieser letzten Symbolkorrektur mit
80 Tests ohne Fehler. Die eigenen Testsimulatoren wurden nach den Läufen
heruntergefahren und die Oberfläche ausgeblendet. Die Mac-Titelübergabe ist
kompiliert und über den gemeinsamen Koordinator getestet; es gab keinen
weiteren Mac-Oberflächenumbau.

## Offene Gerätebeobachtung

Gemeldet wurden ein einmaliger Stopp bei Rückkehr nach dem Entsperren und
ein weiterer Stopp nach automatischem Titelwechsel. Die Ursache ist noch
nicht abschließend belegt. Der behobene Auswahlweg konnte laufende Musik
bereits durch bloße Titelauswahl stoppen; daraus folgt keine sichere Erklärung
für beide Gerätebeobachtungen.

Systemlog-Einträge erfassen nun Auswahl, ausdrückliche Pause, Songende,
Hörfolgenende und Audio-Unterbrechungen. Sie enthalten keine Titel oder
Dateipfade. Damit lässt sich ein erneuter Stopp einem Auslöser zuordnen.

Die Teilrückmeldung bestätigt laufende Musik bei gesperrtem Display, ersetzt
aber keine vollständige Abnahme. AirPods, Anruf, Kopfhörertrennung,
File-Provider-Import, VoiceOver und Akkulaufzeit bleiben ohne erneute
Geräteprüfung. Siehe [`ios/GERAETETEST.md`](../ios/GERAETETEST.md).
