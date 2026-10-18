# Prüfstand 1.9.45

Stand: 2026-10-18. AP13 betrifft Tastaturbedienung, zugängliche Namen/Zustände und anpassungsfähige Ansichten. DSP und gemeinsame Wiedergaberegeln bleiben unverändert.

## Automatische Prüfung

- 107 Webtests und beide Buildtests ohne Fehler; Core-Theme-Test ohne Fehler.
- 67 tatsächlich ausgeführte iOS-Simulator-Tests ohne Fehler.
- Mac-Bundle sowie iOS-SDK 27 und 26.5 erfolgreich gebaut. Die App-Intents-Metadatenmeldung stammt vom Buildwerkzeug; der eigene iOS-Code erzeugt keine Warnung.

## Lauf und Sichtprüfung

Die minifizierte HTML-Einzeldatei läuft unter `file://` in Chrome mit echtem AudioWorklet: Dateiladen per Enter/Leertaste, Tab-Wechsel einschließlich Randumlauf/Home/End, genau ein Tabstopp der Tabgruppe und passende Panels. Kleine Formdialoge beginnen im Eingabefeld, große im Titel; Tab/Umschalt-Tab bleiben im Dialog, Escape schließt ihn. Nach einem gespeicherten Subtune wird der entfernte Zeilenknopf durch einen passenden festen Fokuspunkt ersetzt. Ctrl/Option-Kombinationen lösen weder Mute noch Wiedergabe oder Seek aus. Regler haben Namen und lesbare Werte; lange Metadaten sind beim Fokussieren vollständig sichtbar. Breite/leere sowie schmale/gefüllte Ansichten sind visuell geprüft, ohne horizontales Scrollen. Keine Laufzeitexception; eigene Browserprozesse beendet.

Die native Mac-App wurde mit Standardseitenleiste bei 800 × 580 Punkten in Hell und Dunkel geprüft. Alle Controlgruppen bleiben sichtbar. ⌘F fokussiert die Suche, eine Leertaste bleibt Bestandteil des Suchtexts, und ⌘1–4 wählen die Sammlungsseiten. Der Mini-Player verwendet vor und nach dem Umschalten dieselbe Fenster-ID.

Die finale iPhone-App wurde im Hoch-/Querformat, hell/dunkel und mit maximaler Bedienungshilfen-Schrift geprüft. Titel/Autor/Info bleiben im Bildschirm. Subtune-, Titel- und Sprungtasten haben mindestens 44-Punkt-Treffflächen; die Laufgeometrie bestätigt die vergrößerten Ziele. Transport, Wiedergabeoptionen, Analyse und Audio-Export sind durch Scrollen erreichbar; der Exportdialog lässt sich schließen. Originale Dokumente, Supportdateien und Einstellungen wurden byteweise restauriert, Schriftgröße/Erscheinungsbild/Statusleiste/Ausrichtung zurückgestellt und die eigenen Simulatoren heruntergefahren.

Die finale Mac-Tabfolge wurde mit eingeschalteter Tastaturnavigation praktisch durchlaufen: Suchansichten/Suchhilfe/Auswahl, Mute/Solo, Favorit, Filter, Titelmenü, Dateiöffnung, Optionen, Modell/Takt, Subtunes und Shuffle sind erreichbar. VoiceOver liest den Suchhilfetitel, öffnet und verlässt Menüs und bestätigt Shuffle Aus→An, Filter An→Aus sowie Subtune 2 von 3. Die Suchhilfe verwendet bewusst einen Texttitel: Ein Symbolmenü blieb trotz `accessibilityLabel` als „questionmark.circle“ angesagt.

Zusätzlich wurde die lokale Einzeldatei in einem eigenen Safari-Privatfenster mit tatsächlicher VoiceOver-Ausgabe geprüft. Dateiladen ist benannt, Lists wird als ausgewählter zweiter Tab von vier angesagt, der Sammlungsdialog als Webdialog mit Überschrift, und Escape gibt den Fokus zum Auslöser im Lists-Bereich zurück. Der Lautstärkeregler wird mit 30 Prozent benannt. Safaris Bestätigung der ausgewählten lokalen HTML-Datei wurde über den normalen Dateidialog abgeschlossen. Eigene Fenster und Prozesse wurden geschlossen; VoiceOver, Tastaturnavigation, Systemeinstellungsansicht und App-Daten sind wiederhergestellt.

Ein früherer interaktiver Prüfblock lief während der Auswertung ab; seine Zustände wurden vollständig zurückgenommen. Die finale vorbereitete Abnahme einschließlich Cleanup besteht. AP13 ist für Mac, Browser und iPhone-Simulator abgenommen; die nachstehenden Hardwarepunkte bleiben offen.

## Grenzen und Grundlagen

VoiceOver auf dem iPhone ist durch Simulator-AX-Daten nicht belegt. Apple verlangt dafür ein [echtes Gerät](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app); die [Geräteprüfliste](../ios/GERAETETEST.md) enthält dafür konkrete Punkte, einschließlich externer Tastatur. Hintergrundaudio und echte Audio-Routen bleiben ebenfalls Teil dieser Hardwareabnahme.

Die HTML-Tabs und Dialoge folgen den W3C-Mustern für [Tabs](https://www.w3.org/WAI/ARIA/apg/patterns/tabs/) und [modale Dialoge](https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/). Die vollständige Mac-Tabfolge nutzt die von Apple beschriebene [Tastaturnavigation](https://support.apple.com/de-de/guide/mac-help/kbdm162/mac). VoiceOver-Captions zeigen die tatsächliche Ausgabe des Bildschirmlesers; reine AX-Controltexte ersetzen diese Prüfung nicht.
