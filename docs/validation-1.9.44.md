# Prüfstand 1.9.44

Stand: 2026-10-18. AP12 ergänzt Windows-1252, SID v5 und konkrete Formatgrenzen. Umfang und Grenzen stehen in der [Kompatibilitätsübersicht](sid-compatibility.md).

## Automatische Prüfung

- Vollständige Swift-Tests: 407 ausgeführt, vier bekannte Referenz-Skips, keine Fehler. Unter Linux: 366 ausgeführt, 14 Plattform-/Referenz-Skips, keine Fehler.
- Web: 107 Tests ohne Fehler. Beide Buildtests prüfen die minifizierte und unminifizierte Einzeldatei; die Fleet-Prüfung besteht.
- iOS: 67 tatsächliche Simulator-Tests ohne Fehler. Neue Integrationstests prüfen eingebettete Subtune-Längen, deren Exportquelle, Vorrang von HVSC/persönlicher Endzeit und den Erhalt von Titel, Position, Hörfolge und Verlauf bei einer nicht unterstützten Datei.
- Builds mit iOS-SDK 27 und 26.5 erfolgreich; nativer Mac-Bundle-Build erfolgreich. Optimierter Core mit Swift 6, macOS-13-Ziel und Warnungen als Fehler erfolgreich.
- 4.179 synthetische native/Web-Headerfälle ohne Abweichung: Windows-1252-Bytes, v1–v5, Modelle/Taktflags, v5-Konfigurationen und Customstarts, RSID-Felder, Längenanhänge und Fehlerklassifikation; ein leer angezeigter v5-Titel erhält gültige folgende Felder.
- Alle sieben v5-Layouts rendern mit beiden Chipmodellen wie entsprechende v4-Dateien: je 1.024 native Stereoframes und Web-Monosamples in 14 Konfigurationen, zusätzlich mit getrennten Registerwerten aller drei Chips.
- 529.200 native Stereoframes aus zwölf PSID-Konfigurationen (1/2/3SID, beide Modelle, PAL/NTSC) sind bitgenau zu v1.9.43. Keine Änderung an den kontinuierlich laufenden Filterzuständen aus v1.9.43.

## Referenzen und Lauf

29 vorhandene echte Dateien wurden am bestehenden Ort ausschließlich gelesen: 28 PSID v2 und eine RSID v2. Metadaten und C64-Programmbytes bleiben gegenüber v1.9.43 identisch. Die PSID-Audio-Prüfsummen bleiben identisch; die RSID-Ausgabe ändert sich durch die belegte CIA-Startkorrektur. Pro Datei wurden 44.100 Stereoframes verglichen. Alle 29 Programme wurden zusätzlich nur im Speicher in v5-Header mit Längenanhang übertragen; Programmdaten und Audio sind jeweils identisch zur AP12-Originalfassung. Gesichert wurden nur Prüfsummen, keine SID-Kopien oder realen PCM-Dateien.

Im vorhandenen Bestand gab es keine echten v3/v4/v5-Dateien. Deren Headerfälle sind synthetisch und gegen die Primärspezifikation geprüft. Ein einfacher RSID-IRQ-Test reproduzierte vor der Korrektur 50 statt 60 Aufrufe pro Sekunde bei PAL; nativ und im Web besteht er danach für v2/v5 und PAL/NTSC.

Die minifizierte Einzeldatei lief über `file://` mit echtem AudioWorklet und Dedicated Worker: lange Windows-1252-Metadaten, v5-Dreifach-SID, Wechsel zwischen bekannter und unbekannter Subtune-Länge, A/B-Vorbereitung, Ablehnung von vier Chips und zutreffende Audit-Klassifikation. Keine Laufzeitexception; die eigenen Browserprozesse wurden beendet. Breite und schmale Ansicht in beiden Themes visuell geprüft.

## Native Oberflächen und Grenzen

Die native Mac-Sichtprüfung besteht im echten Bundle: lange Windows-1252-Texte, gemeinsames v5-Chipmodell, SID3-Adresse $DE00, Subtune-Längenwechsel, Null-Länge mit Fallback, 32-Byte-Metadatenfallback und konkrete Vier-Chip-Meldung bei erhaltenem vorbereitetem Titel. Die Exportvorschau zeigt 0:03.25 und SID-Datei; auch die Erklärung der Quellenreihenfolge wurde im finalen Bundle geprüft. Hell/Dunkel visuell geprüft; Musikbytes unverändert.

Die iPhone-Sichtprüfung besteht ebenfalls: lange Windows-1252-Metadaten, gemeinsames Drei-Chip-Modell, Wechsel von eingebetteter Länge zu Null-/Sechs-Minuten-Fallback und eine echte Exportvorschau mit 0:03.25 · SID file · Stereo. Deutsche Vier-Chip-Meldung, erhaltener vorbereiteter Titel/Subtune und feste 32-Byte-Felder sind im dunklen Lauf geprüft. Englische helle und deutsche dunkle Ansichten wurden visuell geprüft. Es entstanden keine Hörereignisse; die Musikbytes bleiben unverändert.

Ein unterbrochener Simulatorstart wurde vollständig zurückgenommen. Abschließend wurden Dokumente, Supportdateien und Einstellungen byteweise gegen das ursprüngliche Backup geprüft; Erscheinungsbild, Statusleiste, Shutdown und das Ende eigener Audioassertionen sind belegt. AP12 ist abgenommen.

RSID bleibt begrenzte Hardwareemulation. Hintergrundaudio, Sperrbildschirm und Audio-Routen auf einem echten iPhone sind mit dieser Simulatorprüfung nicht belegt; dafür gilt weiterhin die [Geräteprüfliste](../ios/GERAETETEST.md).
