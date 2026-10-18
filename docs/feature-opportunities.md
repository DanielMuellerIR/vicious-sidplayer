# Sinnvolle Erweiterungen des Vicious SID Player

Stand: 2026-10-16. Ausgangspunkt: v1.9.26.

Diese Analyse beschreibt den damaligen Funktionsstand und bleibt als
Entscheidungsgrundlage erhalten. Die daraus abgeleiteten Softwarepakete sind
inzwischen bis v1.9.50 umgesetzt. Den aktuellen Umsetzungs- und Prüfstand zeigt
der [Erweiterungsplan](feature-roadmap.md); offene Gerätefälle und die noch
ungeklärte iPhone-Stoppmeldung stehen im [Backlog](../backlog.md).

Den größten nächsten Nutzen bieten korrektes PAL/NTSC-Timing, eine Suche über
echte Musikmetadaten und gespeicherte Playlists mit gezielter Subtune-Auswahl.
Diese Erweiterungen verbessern Klangtreue und tägliche Nutzung und passen in
den vorhandenen gemeinsamen Core. Die Reihenfolge gewichtet häufigen Nutzen,
Aufwand, Wartbarkeit und die bestehende Ausrichtung auf lokale Sammlungen.

## Ausgangslage

STIL-Anmerkungen, Songlängen, Ordnerbaum, Favoriten, Mini-Player, 6581/8580-Wahl,
2SID/3SID-Stereo, Stimmen-Mute, WAV-Export, Medientasten und URL-Fernsteuerung sind
bereits vorhanden. Die Lücken liegen vor allem in der persönlichen Organisation
und in weitergehender Wiedergabesteuerung. Der aktuelle
[Backlog](../backlog.md) enthält außerdem Filter-Tuning und offene Geräteabnahmen.

## Prioritäten und Aufwand

Die Aufwände sind relative technische Einschätzungen, keine Terminzusagen.

| Priorität | Erweiterung | Konkreter Nutzen | Aufwand |
| --- | --- | --- | --- |
| 1 | PAL/NTSC aus der Datei und explizite Taktwahl | Passende Geschwindigkeit und Tonhöhe bei NTSC-Titeln; erkennbarer Status bei unklaren Angaben. | Mittel; empfindlicher DSP-Pfad. |
| 2 | Metadatensuche und gespeicherte Filter | Titel nach SID-Titel, Komponist, Veröffentlichung, Chipzahl oder Modell finden, unabhängig vom Dateinamen. | Mittel; Hintergrundindex und Cache nötig. |
| 3 | Gespeicherte Playlists und Warteschlange | Hörfolgen zusammenstellen, umordnen und mit exakt gewählten Subtunes wieder aufrufen. | Mittel; gemeinsame Zustandslogik nötig. |
| 4 | Repeat, Fadeout und eigene Endzeiten | Einen Subtune wiederholen, Übergänge glätten und Endlosschleifen bewusst begrenzen. | Klein bis mittel; Dauerregeln betreffen mehrere Abläufe. |
| 5 | Solo und getrennte Steuerung mehrerer SID-Chips | Eine Stimme mit einem Klick isolieren und 2SID/3SID-Musik gezielter untersuchen. | Solo klein, unabhängige Chipsteuerung mittel. |
| 6 | Batch-Export und definierte Exportoptionen | Mehrere Titel oder Subtunes in einem Auftrag mit passender Dauer und gewünschtem Mix ausgeben. | Mittel; Abbruch, Dateinamen und Filterverhalten beachten. |
| 7 | Verlauf, Lesezeichen und persönliche Anmerkungen | Gute Stellen wiederfinden, zuletzt gehörte Titel erreichen und Informationen je Subtune festhalten. | Klein bis mittel. |
| 8 | Export und Import persönlicher Sammlungsdaten | Favoriten, Playlists und Anmerkungen zwischen Mac und iPhone übertragen und sichern. | Mittel; robuste Zuordnung und Zusammenführung nötig. |

## Klangtreue und Kompatibilität

Die Engine verwendet derzeit fest PAL-CPU-Takt und 50 Hz in
[ViciousProcessor](../Sources/ViciousSIDPlayerCore/DSP/ViciousProcessor.swift).
[SidParser](../Sources/ViciousSIDPlayerCore/Parser/SidParser.swift) wertet die
Modellflags aus, transportiert aber keine PAL/NTSC-Präferenz in `SidFileData`.
Die [HVSC-Formatspezifikation](https://www.hvsc.de/download/C64Music/DOCUMENTS/SID_file_format.txt)
unterscheidet Taktangaben sowie VBI- und CIA-Timing. Hier liegt eine konkrete
Erweiterung der Wiedergabekorrektheit vor.

Sinnvoll sind ein Auto-Modus nach Datei und ein bewusster PAL/NTSC-Override.
CPU-Takt, VBI und CIA müssen zusammen behandelt werden; nur die Aufrufrate auf
60 Hz zu setzen reicht nicht. Native und HTML5-Engine brauchen gemeinsame
Referenzfälle, auch für Seek und WAV-Export.

Die am 2026-10-09 aktualisierte Formatspezifikation beschreibt außerdem Version 5
und Windows-1252-Metadaten. Der aktuelle Parser akzeptiert Versionen 1 bis 4 und
liest Latin-1. Vor einer Erweiterung sollten reale Referenzdateien und die
Verbreitung der neuen Varianten geklärt werden. RSID wird als Kennung erkannt;
seine tatsächlich unterstützten C64-Sonderfälle verdienen eine ausdrückliche
Kompatibilitätsübersicht. Das ist von einem vollständigen C64-Emulator zu trennen.

Das bestehende 6581-Filter-Tuning bleibt sinnvoll, sobald geeignete Hörreferenzen
und ein gewünschtes Ergebnis vorliegen. Die bestehende Kurve sollte bis dahin
erhalten bleiben.

## Musik finden und organisieren

Die heutige [Playlist-Suche](../Sources/ViciousSIDPlayerCore/Library/Playlist.swift)
durchsucht Dateiname und Ordner. Komponisten werden dadurch gefunden, wenn sie im
Ordnernamen stehen. Titel und Autoren aus dem SID-Header gehören bislang nicht
zum [Bibliotheksindex](../Sources/ViciousSIDPlayerCore/Library/MusicLibrary.swift).
Ein ergänzender Metadatencache würde auch umbenannte Dateien und unsortierte
Sammlungen erschließen. Daraus lassen sich Filter wie „nur 3SID“, „bestimmter
Komponist“ oder „noch nie gehört“ und gespeicherte Suchansichten ableiten.

Die Liste muss weiterhin sofort aus dem bestehenden Index erscheinen. Metadaten
werden danach im Hintergrund ergänzt und bei Dateiänderungen entwertet. Ein
vollständiges Parsen aller Titel beim Start würde das Ziel großer Sammlungen
gefährden. Zusätzliche Felder brauchen einen Vergleich von Startzeit,
Suchreaktion und Speicherbedarf an derselben großen Sammlung.

Gespeicherte Playlists sollten Einträge aus stabiler Datei-ID und Subtune halten.
Damit wird etwa der Lieblingssubtune einer Datei direkt erreichbar. Eine
separate Warteschlange erlaubt „als Nächstes“ und Umordnen, während der
Bibliotheksbaum weiter die Sammlung abbildet. Die heutige Zufallswahl vermeidet
direkte Wiederholungen; ein gemischter Durchlauf mit Buchführung könnte darüber
hinaus alle ausgewählten Titel einmal spielen, bevor ein neuer Durchlauf beginnt.

Verlauf, persönliche Notizen und Positionslesezeichen ergänzen diese Organisation.
Sie gehören in den Support-Speicher, mit Datei-ID und Subtune als Zuordnung.
Musikdateien bleiben dabei unverändert. Für den Austausch zwischen Geräten ist
zunächst eine lokale Export-/Importdatei sinnvoll. Relative Pfade bleiben die
primäre Identität; ein Inhaltsfingerabdruck könnte beim Wiederfinden verschobener
Dateien helfen. Der bestehende Favoriten-Migrationsweg bleibt erhalten.

## Wiedergabe und Analyse

Repeat sollte zwischen Titel, Subtune und einer bewusst gewählten Folge
unterscheiden. Ein kurzer konfigurierbarer Fadeout verhindert harte Abbrüche an
einer Endzeit. Eigene Endzeiten wären besonders für Endlosschleifen nützlich.
Ihre Priorität gegenüber HVSC-Dauer und berechnetem Cache muss ausdrücklich
festgelegt werden und zentral in `SongLengthResolver` und `SongLengthSelection`
gelten, damit Scrubber, Auto-Next, Export und Now Playing dieselbe Dauer verwenden.

Die Oberfläche besitzt derzeit drei Mute-Schalter. Ein Solo-Knopf wäre eine
kleine, häufig brauchbare Ergänzung. Bei 2SID/3SID wären getrennte Chipgruppen
mit eigenen Stimmen sinnvoll. Die Emulation muss beim Muten weiterlaufen und
ihren Zustand behalten. [DeepSID](https://deepsid.chordian.net/) zeigt, wie sich
Solo, mehrere Chips und eine Piano-/Registerdarstellung verbinden lassen.

Eine Piano- oder Frequenzansicht wäre eine spätere Erweiterung für die Analyse.
Sie sollte Wellenform, Gate, Hüllkurve und Registeränderungen sichtbar machen;
aus der SID-Frequenz folgt bei Noise, Ringmodulation und Samples keine verlässliche
Partitur. Zeichendaten bleiben außerhalb von hochfrequentem `@Published`-Zustand.
A/B-Schleifen sind ebenfalls interessant, benötigen aber wegen des rekonstruierten
Seek-Zustands eine eigene Leistungsprüfung.

## Export und Bedienung

[WavRenderer](../Sources/ViciousSIDPlayerCore/WavRenderer.swift) exportiert bereits
mono oder stereo und berücksichtigt die Modellwahl. Die Oberfläche exportiert
einen ausgewählten Subtune; Mute und Filterwahl sind keine Parameter des Renderers.
Ein Batch-Export könnte alle gewählten Subtunes mit ihrer aufgelösten Dauer,
eindeutigen Namen und Abbruchmöglichkeit ausgeben. „Gesamter Mix“ und „aktueller
Abhörmix“ sollten ausdrückliche Optionen sein. Für getrennte Stimmenexporte muss
das Verhalten des gemeinsam wirkenden SID-Filters definiert werden. Weitere
Formate wie M4A oder FLAC folgen nach diesem vollständigen Ablauf.

Eine anpassungsfähigere Hauptansicht, vollständige Tastaturbedienung und klare
VoiceOver-Beschriftungen verbessern den Zugang zu diesen Funktionen. Der
Mini-Player bleibt dabei Teil desselben Fensters. Eine sparsame Zeichenrate bei
ausgeblendeten Ansichten ist ein Kandidat für Messungen; Audio, Auto-Next und
Sperrbildschirmsteuerung müssen davon unabhängig bleiben.

## Empfohlene Reihenfolge

Zuerst PAL/NTSC mit Referenztests absichern. Danach Metadatencache und Suche
erweitern, anschließend gespeicherte Playlists mit Subtunes und Warteschlange.
Solo, Repeat und Fadeout sind passende kleinere Meilensteine. Batch-Export und
der Austausch persönlicher Sammlungsdaten bauen darauf auf.

Für iOS bleibt die offene reale Geräteabnahme aus
[GERAETETEST.md](../ios/GERAETETEST.md) vorrangig, bevor zusätzliche Funktionen
für Hintergrundbetrieb und Audio-Hardware hinzukommen. Die bestehenden
Backlog-Entscheidungen bleiben bestehen: Hardware-ASID ist gestrichen;
Audiofingerprint und MUS/CGSC sind zurückgestellt, und gezieltes Filter-Tuning
ersetzt den geplanten vollständigen reSIDfp-Port.
