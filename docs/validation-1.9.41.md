# Prüfstand 1.9.41

Stand: 2026-10-18. Weitere native Exportformate auf Mac und iPhone.

## Umfang

WAV bleibt voreingestellt. FLAC übernimmt dieselben 16-Bit-Samples verlustfrei;
M4A verwendet AAC mit 128, 192 oder 256 kbit/s. Alle Formate verwenden den
Batch-Plan für Dauer, A/B, Mix, Filter, Fade, Dateinamen und Zielschutz. M4A und
FLAC speichern Titel, Autor, SID-Info sowie Subtune-Nummer und -Anzahl.
Die Codierung verwendet öffentliche System-APIs ohne zusätzliche Abhängigkeit.

Unfertige Dateien liegen in einem eigenen temporären Nachbarordner und werden
bei Abbruch oder Fehler entfernt. Fertige Ausgaben bleiben erhalten. Erst nach
Codierung, Metadaten und Prüfung wird das Ziel atomar veröffentlicht.

## Automatische Prüfungen

- Swift: 382 Tests, vier Referenzfälle ohne lokale Musik übersprungen, keine
  Fehler. Nach der Korrektur der AAC-Dauerprüfung sind zusätzlich alle 19
  betroffenen Exporttests grün.
- Linux: 343 Tests, 14 plattformspezifische oder lokale Referenzfälle
  übersprungen, keine Fehler. Nach der finalen AAC-Prüfung sind zusätzlich
  alle 14 Linux-Exporttests grün. Nicht verfügbare M4A-/FLAC-Encoder verändern weder
  Quellen noch vorhandene Ziele; WAV bleibt verfügbar.
- iOS: tatsächliche 63 Tests nach der finalen AAC-Prüfung grün. Builds gegen
  iOS-Simulator-SDK 27 und 26.5 erfolgreich. Keine Warnungen im eigenen Code.
- Der vollständige Core lässt sich explizit für macOS 13 mit Swift 6 und
  Warnungen als Fehler übersetzen.
- AAC mit einem Sample, 4410 und 59346 Frames; alle drei Bitraten mono/stereo;
  FLAC mit 192, 4410, 4607, 4608, 4609 und 44100 Frames bitgenau decodiert.
  Falsche AAC-Samplezahlen werden zurückgewiesen.
- FLAC-Kommentare erhalten fremde Metadatenblöcke und Audioframes. Unicode,
  Little-/Big-Endian-Längen, abgeschnittene und ungültige Header geprüft.
- Formatwechsel erhalten Auswahl, Dauer, Kollisionsschutz und einen noch
  ungültigen manuellen Eingabewert. Abbruch während der Codierung erhält die
  erste fertige Datei und entfernt Arbeitsdateien; ein nach der Vorschau
  erzeugtes Ziel bleibt erhalten.

## Unabhängige Dateiprüfung

20 Ausgaben mit kurzen Mono-/Stereo-Dateien und A/B-Ausschnitten wurden mit
FFmpeg unabhängig decodiert: zusammen 637560 Frames, korrekte Kanalzahl,
44,1 kHz und Titel-/Autor-/Album-/Kommentar-/Subtune-Tags. Alle vier FLAC-Dateien
stimmen bitgenau mit WAV überein. Dies gilt auch für einen optimierten Core mit
der SDK-Kennung des Mac-Bundles.

AAC enthält Encoder-Vorlauf und Restpadding. `AVAsset.duration` zählt diese
Samples in älteren SDK-Kompatibilitätsmodi mit. Die Prüfung verwendet deshalb
`AudioFilePacketTableInfo.mNumberValidFrames` statt dieses Anzeigewerts. Die
Metadaten-Neuverpackung erhält die decodierten Audiodaten unverändert.

## Native Mac-Abnahme

- Tatsächliche M4A-Einzeldatei über den Save-Dialog: 256 kbit/s, Stereo,
  59346 Frames bei präziser manueller Dauer; die Vorschau zeigt 0:01.346.
- 128-kbit/s-Batch mit drei Subtunes und je einer Sekunde. Vorhandenes Ziel
  bleibt bytegleich erhalten, die neue Datei erhält den Zusatz `(2)`.
- Tatsächlicher Abbruch nach der ersten fertigen 60-Sekunden-M4A-Datei:
  genau eine fertige Ausgabe, keine unvollständigen Arbeitsdateien.
- FLAC mono/stereo mit je 4410 Frames. Bei einer Millisekunde ist Export
  deaktiviert und die Mindestdauer verständlich angezeigt.
- Hell/Dunkel visuell geprüft. Wiedergabe und Lautstärke bleiben beim Export
  erhalten. Präferenzen und vorherige persönliche Daten nach dem Test
  wiederhergestellt.
- Sieben tatsächliche GUI-Ausgaben unabhängig decodiert: 2846466 Frames,
  Metadaten und Kanalzahlen korrekt; beide FLAC-Dateien bitgenau zu WAV.

## Native iPhone-Abnahme

- M4A mit 256 kbit/s, Stereo und präziser manueller Dauer: 59346 Frames;
  die Vorschau zeigt 0:01.346. Deutscher Mono-Export mit 128 kbit/s und
  einer Sekunde: 44100 Frames.
- FLAC-Batch mit drei Subtunes und je einer Sekunde. Native Teilenansicht
  erkennt alle drei Dokumente. M4A und die drei FLAC-Dateien wurden über den
  tatsächlichen Dateien-Dialog im lokalen Appordner gespeichert; alle vier
  Kopien stimmen bytegleich mit den Exporten überein.
- Hell/Dunkel und Deutsch/Englisch visuell geprüft, einschließlich deutscher
  FLAC-Mindestdauer mit deaktiviertem Export. Der vorbereitete Titel bleibt
  pausiert, die Lautstärke bleibt null; alle SID-Quelldateien bleiben bytegleich.
- Fünf tatsächliche GUI-Ausgaben unabhängig decodiert: 235746 Frames,
  Kanalzahl, 44,1 kHz und Metadaten korrekt. Alle drei FLAC-Dateien stimmen
  bitgenau mit WAV überein.
- Vorherige Testgerätedaten, Präferenzen und Erscheinung nach dem Test
  restauriert; eigener Simulator heruntergefahren und Audioassertions frei.

## Grenzen

FLAC benötigt mindestens 192 Samples (ca. 4,36 ms); es wird kein Padding
angehängt, um diese Grenze zu umgehen. AAC ist verlustbehaftet. Die Dateigröße
von FLAC hängt vom Inhalt ab, die M4A-Vorschau ist eine Schätzung. Die nativen
Formate ändern den bisherigen WAV-Weg der Kommandozeile nicht.

Die Abnahme im Simulator belegt keine Audio-Unterbrechungen, Kopfhörerwechsel
oder Hintergrundwiedergabe auf echter iPhone-Hardware; dafür bleibt
[GERAETETEST.md](../ios/GERAETETEST.md) maßgeblich.

Quellen zu den verwendeten Formaten/APIs:
[FLAC-Spezifikation RFC 9639](https://datatracker.ietf.org/doc/html/rfc9639),
[AudioToolbox-Dateicodierung](https://developer.apple.com/documentation/audiotoolbox/encoding-and-decoding-audio),
[AudioFilePacketTableInfo](https://developer.apple.com/documentation/audiotoolbox/audiofilepackettableinfo),
[AVAssetExportSession-Metadaten](https://developer.apple.com/documentation/avfoundation/avassetexportsession/metadata).
