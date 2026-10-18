# Prüfstand 1.9.42

Stand: 2026-10-18. Sammlungsprüfung und Wiederfinden auf Mac, iPhone und HTML5.

## Umfang und Schutz

Die Prüfung liest SID-Dateien neu und vergleicht den vollständigen MD5-Inhalt.
Gleichnamige Dateien in verschiedenen Ordnern bleiben getrennt. Beschädigte
Header, nicht unterstützte Versionen, Duplikate und fehlende oder verschobene
Verweise stehen als getrennte Hinweise im Bericht. Native Apps prüfen außerdem
Zuordnungen in geladenen STIL- und Songlängendatenbanken; nicht geladene Quellen
werden ausdrücklich genannt. Fehlende STIL-Einträge bedeuten keinen Dateifehler.

Die native Inventur speichert relative Pfade und Prüfsummen im Supportordner.
Offene persönliche Verweise behalten ihre bisherigen Identitäten auch über
wiederholte Prüfungen. Neuere oder beschädigte Inventuren werden erhalten und
mit einer Warnung gemeldet. Bibliotheks-Reset entfernt die zugehörige Inventur.

Nur ausgewählte, eindeutige MD5-Vorschläge dürfen persönliche Verweise ändern.
Eine frische Dateiprüfung und der Vergleich der betroffenen persönlichen
Einträge verhindern die Übernahme einer veralteten Vorschau. Favoriten, Listen,
Verlauf, Lesezeichen und Notizen werden gemeinsam über die bestehende gesicherte
Transaktion aktualisiert. IDs, Reihenfolge, Texte, Positionen und Zeitangaben
bleiben erhalten; aktive Hörfolge und Wiedergabeeinstellungen bleiben gleich.
Mehrdeutige Treffer und Pfade ohne bekannte Inhaltsidentität werden nicht geraten.
Musikdateien werden weder geschrieben noch gelöscht.

## Automatische Prüfungen

- Swift: 391 Tests, vier lokale Referenzfälle übersprungen, keine Fehler.
  Nach der Ergänzung des Inventur-Resets sind zusätzlich alle zwölf Audit- und
  Reset-Tests grün. Acht Audit-Tests prüfen unter anderem gleichnamige Dateien,
  mehrdeutige MD5s, wiederholte Inventuren, veraltete Vorschauen, Pfadgrenzen,
  Abbruch, beschädigte Inventuren und die Erhaltung persönlicher Werte.
- Linux: 350 Tests, 14 plattformspezifische oder lokale Referenzfälle
  übersprungen, keine Fehler; zusätzlich zwölf finale Audit-/Reset-Tests grün.
- Web: 94 Tests ohne Fehler. Zwei Buildtests prüfen auch die JavaScript-Syntax
  der vollständigen minimierten und unminimierten Einzeldatei.
- iOS: 65 tatsächlich ausgeführte Tests ohne Fehler; Builds gegen die
  Simulator-SDKs 27 und 26.5 erfolgreich, keine Warnungen im eigenen Code.
- Optimierter Core explizit für macOS 13 mit Swift 6 und Warnungen als Fehler
  übersetzt. Native Mac-App gebaut und ihre Developer-ID-Signatur geprüft.
  Fleet-Regeltest bestanden.

## Native Mac-Abnahme

Sieben synthetische Dateien ergeben fünf lesbare Titel und elf Hinweise,
einschließlich zweier eindeutiger Wiederzuordnungen und eines mehrdeutigen
Treffers. Filtern und beide Checkboxen verändern noch keine persönlichen Daten.
Der echte Dateiexport sichert den vollständigen JSON-Bericht. Die bewusste
Übernahme erhält Listen-/Eintrags-IDs, die 1,25-Sekunden-Marke, Notiztext und
aktive Hörfolge; Wiedergabe und Lautstärke bleiben erhalten. Hell und Dunkel
sind visuell geprüft.

Ein weiterer tatsächlicher App-Lauf prüft Abbruch, 100 lesbare Dateien,
maximal 20 Hinweise pro Seite sowie den Wechsel von Seite 1 zu Seite 2.
Die Prüfung benötigt dabei rund 1,85 Sekunden; ein Prozessspeicher-Snapshot
beträgt rund 284 MiB. Alle Musikbytes bleiben unverändert. Vorherige persönliche
Daten und Präferenzen werden nach beiden Abläufen bytegleich wiederhergestellt.

Ein separater optimierter Core-Lauf über 50.001 kleine synthetische Dateien
benötigt rund 6,12 Sekunden bei 207 MiB gemessenem maximalem Prozessspeicher.
Der vollständige Bericht enthält 50.002 Hinweise und 13.150.783 JSON-Bytes.
Dies ist eine Core-Messung; die native Oberfläche wurde mit 100 Dateien geprüft.

## Native iPhone-Abnahme

Sieben Dateien ergeben fünf lesbare Titel und elf Hinweise. Zwei echte
Schalter wählen eindeutige Vorschläge; persönliche Dokumente und Favoriten
bleiben bis zur Übernahme unverändert. Der echte Dateien-Dialog speichert den
vollständigen Bericht mit elf Hinweisen, zwei sicheren Vorschlägen und einem
mehrdeutigen Treffer im lokalen Appordner.

Die tatsächliche Übernahme erhält Listen-/Eintrags-IDs, Reihenfolge, aktive
Hörfolge, Notiztext und die 1,25-Sekunden-Marke. Der mehrdeutige Favorit bleibt
unverändert. Alle Musikbytes bleiben gleich; der vorbereitete Titel läuft
nicht los und erzeugt keinen Verlaufseintrag. Position und Lautstärke bleiben null.

Mit 100 zusätzlichen synthetischen Dateien sind tatsächlicher Abbruch und
anschließende vollständige Prüfung von 107 Dateien belegt: 105 lesbare Titel,
211 Hinweise, genau 20 Hinweiszeilen pro Seite und Wechsel von 1–20 auf 21–40.
Englisch/Hell und Deutsch/Dunkel sind visuell geprüft. Neue Aktionsknöpfe haben
mindestens 44 Punkte Höhe; Start und Übernahme reagieren auch am unteren Rand
der vergrößerten Fläche. Der vorherige Simulatorzustand wird nach dem Test
wiederhergestellt und das eigene Gerät heruntergefahren.

## Tatsächliche lokale Browserabnahme

Die erzeugte Einzeldatei läuft über `file://`. Sieben ausgewählte Dateien,
fünf lesbare Titel, elf Hinweise, zwei sichere Vorschläge und ein mehrdeutiger
Treffer sind geprüft. Der tatsächliche JSON-Download enthält alle Hinweise.
Checkboxvorschau und Übernahme erhalten Listen-/Eintrags-IDs, Notiztext,
1,25-Sekunden-Marke, aktive Folge und vorbereitete, pausierte Wiedergabe.
Echte Datei- und Ordnerdrops erhalten auch verschiedene gleichnamige Dateien.

Ein Lauf mit 50.000 synthetischen Dateien ist tatsächlich abgebrochen worden;
ein weiterer vollständiger Lauf benötigt rund 29,8 Sekunden und liefert
50.018 Hinweise bei höchstens 20 gleichzeitig aufgebauten Hinweiszeilen.
Es gibt keine JavaScript-Ausnahmen. Hell/Dunkel bei 1280 und 390 Pixeln sind
visuell und auf Überlauf geprüft; die neuen Browser-Aktionen haben mindestens
44 Pixel hohe Treffflächen. Der eigene Browserprozess ist danach beendet.

## Grenzen

Die native Prüfung liest in 64-KiB-Schritten und begrenzt jede Datei auf
32 MiB. Ein Abbruch veröffentlicht keinen Teilbericht. Eine Prüfung belegt
lesbare Header und Identitäten, keine vollständige hörbare Emulationskorrektheit.
Ein beschädigter oder unerwartet geänderter Dateiinhalt wird nicht repariert.

HTML5 prüft nur ausdrücklich ausgewählte Musikbytes. Eine nicht ausgewählte
Datei kann fehlen oder weiterhin anderswo existieren; der Browser kann dies
nicht entscheiden. STIL und HVSC-Songlängen sind dort nicht geladen.

Ohne gespeicherte Prüfsumme gibt es für einen verschwundenen Favoriten oder
Listeneintrag keine sichere Wiederzuordnung. Deshalb die native Sammlung vor
späteren Verschiebungen einmal prüfen. Ein übereinstimmender Dateiname allein
genügt nie. Dateien, persönliche Endzeiten und aktive Hörfolgen werden durch
Wiederzuordnung nicht verändert. Hardwareabhängige iPhone-Prüfungen bleiben
[GERAETETEST.md](../ios/GERAETETEST.md) vorbehalten.
