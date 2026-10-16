# Hörfolgen — Umsetzung und Prüfung in v1.9.28

Stand: 2026-10-16.

Die Mac-Seitenleiste bietet Musik, gespeicherte Listen und die laufende Folge
als Tabs desselben Bereichs. Die Wiedergabe bleibt bei einem Koordinator.
Eine Suche filtert die Ansicht; erst „Auswahl“ startet die Treffer, Favoriten,
einen Ordner oder die gesamte Bibliothek als bewusste Hörfolge.

Listen halten stabile Datei- und Eintrags-IDs. Mehrere Subtunes derselben Datei
können unabhängig vorkommen. Ein fester Subtune spielt nur diesen; ein Dateieintrag
spielt auch seine verbleibenden Subtunes. Die laufende Folge ist eine Kopie der
Liste: Spätere Änderungen an der Vorlage oder an einem Suchfilter verändern sie
nicht. „Als Nächstes“ bleibt in Eingabereihenfolge; Umordnen erhält den laufenden
Eintrag. Auswahlen und gespeicherte Listen enden, die gesamte Bibliothek wiederholt
sich in Durchläufen. Shuffle besucht jeden Eintrag einmal je Durchlauf und
vermeidet bei mehreren Einträgen die sofortige Wiederholung am Übergang.

Versionierte JSON-Daten liegen im Support-Verzeichnis. Lesen, Kodieren und
Schreiben laufen abseits des Hauptthreads; normale Beendigung sichert den letzten
Stand. Eine beschädigte oder neuere Datei bleibt erhalten und erzeugt einen
sichtbaren schreibgeschützten Zustand. Listen bleiben bei einem Bibliothekswechsel
erhalten und können nach Rückkehr zu ihrer Sammlung wieder abgespielt werden.

## Ergebnisse

- macOS: 250 Swift-Tests, 4 fehlende lokale Musikreferenzen übersprungen, keine
  Fehler. Die neuen Hörfolgenfälle verwenden ausschließlich synthetische Daten.
- 17 neue Tests prüfen Auswahlgrenzen, feste Subtunes, wiederholte Dateien,
  Shuffle-Durchläufe, FIFO, Umordnen, Bibliotheksscans, Wurzelwechsel,
  Wiederherstellung, 50.000 Einträge und den Erhalt beschädigter Originaldaten.
- Linux: 240 Tests mit Swift 6.0, 14 Fälle wegen fehlender lokaler
  Musikreferenzen, fehlender isolierter ALSA-Konfiguration oder der Ausführung
  als root übersprungen; keine Fehler. Rechteprüfungen unter root sind damit
  ausdrücklich nicht belegt.
- iOS: Build für generic/platform=iOS Simulator und 39 Simulator-Tests erfolgreich,
  keine Warnungen im eigenen Code. Der erste Teststart meldete „Busy“;
  nach gezieltem Simulator-Boot bestanden alle Fälle. Xcode meldet die nicht
  benötigte AppIntents-Metadatenextraktion.
- Mac-Release-Build, Fleet-Regeln, 11 Appcast-Prüfungen und 8 Release-Guard-/Workflow-
  Prüfungen bestanden. Das geprüfte Mac-Bundle ist signiert und notarisiert.
- Im echten Mac-Bundle geprüft: leere Listenansicht, Anlegen, Umbenennen,
  Subtune-Auswahl, Lieblings-Subtunes, Umordnen, Entfernen und Als Nächstes.
  Zwei feste Subtunes derselben einzigen Bibliotheksdatei bleiben über Weiter/
  Zurück getrennt anwählbar. Eine Listenänderung verändert die aktive Kopie nicht.
  Nach normalem Quit/Neustart sind Folge, Position und offener Als-Nächstes-Wunsch erhalten.

- Suchtreffer, Favoriten und Ordner im echten Bundle als Folgen gestartet;
  spätere Filteränderungen lassen die Folge unverändert. Ein kompletter
  Shuffle-Durchlauf über drei Testtitel enthält jeden Titel genau einmal,
  der Übergang wiederholt nicht unmittelbar den letzten Titel.
- Bibliotheksliste geleert: Queue entfernt, gespeicherte Listen erhalten.
  Zwei feste Subtunes derselben einzigen Bibliotheksdatei bleiben anwählbar.
  Bestätigungslöschung einer neu angelegten Testliste erfolgreich.
- Auto-Next spielt die festen Subtunes 2 und 3 einer synthetischen Datei mit
  jeweils vier Sekunden Dauer und hält am Listenende an.
- Fehlende Datei: gespeicherte Einträge bleiben sichtbar, sind als nicht in
  der Bibliothek markiert und führen beim Start zu einer verständlichen Meldung.
  Diese Verfügbarkeit ist auch Teil der Accessibility-Beschriftung.
- Nicht unterstützte Datenversion: sichtbarer schreibgeschützter Zustand,
  Originaldatei nach normalem Beenden bytegleich erhalten. Hell/Dunkel und
  180-Pixel-Seitenleiste visuell geprüft. Warnungen und gemerkte Subtunes
  verwenden im Hellmodus eine dunklere Farbe (5,27:1 gegen den Seitenhintergrund).
- 50.000 synthetische Bibliothekstitel: Liste und Queue sichtbar und umschaltbar.
  RSS in derselben pausierten Konfiguration: v1.9.27 299.312 KiB, v1.9.28
  Bibliothek 311.616 KiB, Queue 316.368 KiB, entsprechend etwa 292, 304 und
  309 MiB. Der native Scrollbalken bewegt die sichtbaren Zeilen von Track00000
  zu Track00050. Ein synthetisches Scrollrad-Ereignis hatte zuvor keine
  nachweisbare Wirkung und wird nicht als bestandener Scrolltest gezählt.
- Die ursprünglichen Testeinstellungen wurden exakt wiederhergestellt;
  eigene Test-Apps und große Arbeitskopien sind entfernt.

## Grenzen

Die neuen Hörfolgenansichten sind in dieser Version auf dem Mac verfügbar.
iPhone- und HTML5-Integration folgen als eigene Stufe des
[Erweiterungsplans](feature-roadmap.md). Die Core-Regeln sind portabel;
der native Zustandsadapter verwendet Combine.

Reale Hintergrundwiedergabe und Audio-Unterbrechungen auf dem iPhone sind durch
Simulator-Tests weiterhin nicht belegt. Import/Export persönlicher Hörfolgen und
Neuzuordnung verschobener Sammlungen folgen in der gesonderten Austauschstufe.

Der RSS-Vergleich ist eine Einzelmessung, keine allgemeine Leistungszusage.
Wegen hoher gemeinsamer Rechnerlast wurde kein CPU-Vergleich gewertet.
