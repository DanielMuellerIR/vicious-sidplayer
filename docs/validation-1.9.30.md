# Prüfung von v1.9.30

Stand: 2026-10-16. Metadatensuche und gespeicherte Suchansichten auf Mac und iPhone.

Der Dateiindex bleibt vom Headercache getrennt. Der Cache lädt vorhandene Daten und ergänzt SID-Titel, Autor, Veröffentlichung, Chipzahl und Modell im Hintergrund. Datum und Dateigröße entwerten geänderte Einträge. Doppelte oder außerhalb der Sammlung liegende Indexpfade werden sicher behandelt. Geöffnete Fremddateien werden ebenfalls ausgewertet. Unbekannte Headerangaben werden nicht aus Emulator-Fallbacks abgeleitet.

Suchbegriffe und Felder sind kombinierbar; Anführungszeichen erhalten Leerzeichen in Feldwerten. Normalisierte Suchtexte vermeiden erneute Unicode-/Akzentvergleiche je Eingabe. Dauerfilter beziehen sich auf Subtune 1: HVSC vor positivem berechnetem Cache, ohne Fallback als vermeintlich bekannte Dauer. Gespeicherte Ansichten merken Query und Favoritenfilter. Neue oder beschädigte persönliche Daten bleiben erhalten. Explizite Hörfolgen verwenden dieselben Suchregeln und bleiben gegenüber späteren Filtern stabil.

## Ausgeführt

- 263 Core-Tests (vier fehlende lokale Musikreferenzen übersprungen) vor dem zusätzlichen Indexschutz erfolgreich; danach 13 gezielte Metadaten-Regressionen erfolgreich. Der gemeinsame Abschlusslauf des folgenden Entwicklungsstands v1.9.31 bestand 288 Core-Tests mit vier Skips.
- 48 iOS-Tests sowie Build für `generic/platform=iOS Simulator` erfolgreich. Der folgende Entwicklungsstand bestand 52 iOS-Tests; die abschließenden Suchdialogänderungen wurden zusätzlich für iOS gebaut. Die Tests prüfen Headeränderungen, gespeicherte Suchansichten, Filterunabhängigkeit und Erhalt einer neueren Datendatei.
- Optimierter Core mit 50.000 Suchdatensätzen: einfache Suche rund 64 ms, kombinierte Metadaten-/Dauersuche rund 36 ms. Die erste ungefaltete Debug-Fassung brauchte rund 473 ms für die einfache Suche und wurde deshalb überarbeitet.
- Tatsächlicher Bestand aus 50.000 synthetischen Dateien: erster Metadatencache rund 3,25 s; späteres Cacheeinlesen rund 0,44 s. Suchfälle rund 19–70 ms mit korrekten Treffermengen, darunter 16.666 3SID-Titel und 33.333 Titel mit 8580-Angabe. Nach zusätzlichem Indexschutz: erster Cache rund 4,38 s, warmes Einlesen rund 0,47 s und Suchfälle rund 20–70 ms.
- Neues Mac-Bundle gebaut; Fleet-Guards einschließlich Binärprüfung bestanden. Der gemeinsame Abschlusslauf des folgenden Entwicklungsstands bestand auf Linux 272 Tests mit 14 plattformbedingten Skips.
- HTML5: kurze Seitenleisten behalten mindestens 120 Pixel Listenhöhe und sind scrollbar. Echter Browserlauf bestätigt erreichbare Zeilen und Metadaten bei 1280×600 CSS-Pixeln; Hell/Dunkel und enges Layout bleiben geprüft.

## Visuelle Abnahme und großer Bestand

Die Ansichten wurden im folgenden Entwicklungsstand v1.9.31 geprüft. Auf dem Mac: 50.000 synthetische Dateien, erster/warm vorhandener Metadatencache und gezielter 3SID-/Titel-Filter. v1.9.28 benötigte rund 289 MiB RSS; der neue Stand rund 485 MiB nach kaltem Aufbau und 432 MiB beim warmen Start. Der Vergleich enthält auch die folgenden Wiedergabeoptionen und ist keine isolierte Messung eines einzelnen Cachetyps. Wegen gemeinsamer Hostlast wird kein CPU-Vergleich abgeleitet.

An einer kleinen Sammlung: Titel- und Autorfilter, gespeicherte Ansicht anlegen, anwenden, umbenennen und löschen, erneutes Umbenennen nach Neustart, unveränderte laufende Hörfolge bei Filterwechsel, schmale Seitenleiste sowie Hell/Dunkel. Eine neuere Suchdateiversion blieb nach Öffnen und Beenden bytegleich erhalten. Einstellungen und persönliche Dateien wurden nach den Mac-Proben wiederhergestellt und verglichen.

Auf dem iPhone: Bibliotheksgruppen und Metadatenzeilen, Suchhilfe, Dauerfilter und Anlage einer Suchansicht in der bestehenden Bibliotheksposition. Helle und dunkle Ansichten sind lesbar; die gespeicherte Query wurde nach App-Ende aus der Datei geprüft. Umbenennen/Löschen und Neustartregeln sind zusätzlich durch iOS-Modelltests und den Mac-Lauf abgedeckt. Geräte-Hintergrundbetrieb und Audio-Hardware gehören weiterhin zur gesonderten realen iPhone-Abnahme.
