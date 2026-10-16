# Prüfung von v1.9.29

Stand: 2026-10-16. Hörfolgen auf iPhone und HTML5.

Die iPhone-App verwendet dieselben Auswahl-, Listen-, Queue-, Shuffle- und Subtune-Regeln wie die Mac-App. Die Sammlungsidentität bleibt beim Wechsel des App-Containers stabil. Wiederherstellung bereitet den Titel vor, ohne automatisch abzuspielen; die Eintrags-ID unterscheidet dabei mehrere Subtunes derselben Datei. Änderungen an Suchfiltern verändern eine gestartete Folge nicht.

Die HTML5-Einzeldatei speichert ausschließlich persönliche Metadaten im Browserspeicher. Nach dem Neuladen müssen Musikdateien erneut ausgewählt werden. Pfad und Inhaltsfingerabdruck erkennen bekannte Dateien; verschobene Dateien werden nur bei eindeutigem Inhalt zugeordnet. Unlesbare, neuere oder zwischenzeitlich von einer anderen Seite geänderte Daten bleiben erhalten. Fehlender Speicher und Schreibfehler sind sichtbar. Zeilen und Titelmenü sind begrenzt.

## Ausgeführt

- 251 Swift-Tests, davon vier mangels lokaler Musikreferenzen übersprungen; keine Fehler. Dazu gehört das Umordnen mehrerer nativer Listeneinträge.
- iOS-Build für `generic/platform=iOS Simulator` und 45 iOS-Tests erfolgreich. Sechs neue Integrationstests decken feste Subtunes, Filterunabhängigkeit, fehlende Dateien, ungültige Subtunes, Containerwechsel und Wiederherstellung nach Shuffle ab. Ein zunächst fehlgeschlagener Shuffle-Restore wurde mit stabiler Eintrags-ID korrigiert.
- 36 Web-Tests sowie der Minifier-Test erfolgreich. Abgedeckt sind Queue-Referenzfälle, 50.000 serialisierte Einträge, Speicherfehler, eindeutige/mehrdeutige Dateizuordnung und verspätete AudioWorklet-Anzeigenachrichten.
- Echter Chromium-Lauf unter `file://`: drei synthetische SID-Dateien, Listenanlage, zwei feste Subtunes derselben Datei, Weiter/Zurück, Als Nächstes, Umordnen, Umbenennen, Subtune ändern, Lieblings-Subtune und Wiederherstellung mit Position 12 Sekunden und offenem Wunsch. Die Zeitgrenze für Auto-Next wurde kontrolliert angestoßen; die Folge stoppte am Ende.
- Browseransichten in Hell/Dunkel, bei 1280×900, 390×844 und 1280×600 CSS-Pixeln visuell geprüft. Tastaturbedienung des Shuffle-Schalters und schreibgeschützte Datenversion geprüft. Die ursprüngliche neuere Datenversion blieb unverändert.
- Fleet-Quellprüfung und Single-File-Build erfolgreich.

## Noch offen

Die neuen iPhone-Ansichten benötigen noch die visuelle Prüfung im echten Simulatorlauf. Ein bestandener Modelltest ersetzt diese Abnahme nicht. Hintergrundwiedergabe, Sperrbildschirm und Audio-Hardware bleiben Teil der gesonderten Geräteabnahme; sie sind durch diesen Simulatorlauf nicht belegt.
