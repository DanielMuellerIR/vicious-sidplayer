# Prüfstand v1.9.32

Stand: 2026-10-16. AP05 ist auf macOS, iPhone und HTML5 umgesetzt und abgenommen.

- 309 Swift-Core-Testfälle ohne Fehler, davon vier wegen fehlender lokaler Musikreferenzen übersprungen.
- 290 Linux-Testfälle ohne Fehler, davon 14 plattformbedingt übersprungen.
- 55 iOS-Tests bestanden, darunter prepare-only, exakter Subtune-/Positionsaufruf, geänderter Dateiinhalt, lange Marken, Neustart, Notizen und Gehört-Filter. Generic-iOS-Simulator-Build erfolgreich; keine Warnung im eigenen Code. Die SDK-Meldung zur ausgelassenen AppIntents-Extraktion betrifft eine nicht verwendete Funktion.
- 45 Webtests bestanden. Unter anderem echte Hörzeit statt Seek-Differenz, Pause/Repeat, lange Beobachtungslücken, Aufbewahrung, persönliche Daten nach Neustart, beschädigter/neuer Speicher und veraltete Seek-Rückmeldungen.
- Minifizierter und unminifizierter Single-File-Build erfolgreich.
- Echter Chromium-Lauf unter `file://`: zwei synthetische SID-Dateien, gut elf Sekunden erfasste Hörzeit, Sprung auf 200 Sekunden ohne zusätzliche scheinbare Hörzeit, Lesezeichen, ganze-Datei-Notiz, Neustart, fehlende Datei, „Never heard“ und bewusstes Leeren bei erhaltenen Marken/Notizen. Keine JavaScript-Ausnahme. Helle und dunkle Ansichten visuell geprüft.
- macOS-Release-Bundle gebaut und Developer-ID-Signaturen geprüft. Fleet-Schutzregeln bestanden; kein Build-Heimatpfad im Bundle.
- Echter Mac-Lauf: gut zwölf Sekunden Hörzeit, benanntes Lesezeichen und Datei-Notiz, unmittelbares Beenden mit gespeichertem Ergebnis, Wiederaufruf von Datei/Subtune/Position, fehlende Datei ohne falsche Wiedergabe, Leeren bei erhaltenen Marken/Notizen und unverändert erhaltene neuere Datendatei. Einstellungen und persönliche Dateien anschließend bytegleich wiederhergestellt. Die Prüfung wartet auf die verzögerte Speicherung beziehungsweise den Abschluss beim Beenden.
- Leere und gefüllte Mac-Ansichten mit 180 und 240 Pixeln Seitenleiste in Hell/Dunkel sowie der Notizeditor visuell geprüft. Die bei 320 Pixeln gefundene zu kleine Mindestbreite ist korrigiert und nachgeprüft: Das volle Fenster bleibt bei 1.340 × 640 Pixeln ohne abgeschnittene Controls; der Mini-Player mit 760 × 92 Pixeln kehrt über seinen Knopf zur vollen Ansicht zurück.
- Echter iPhone-Simulatorlauf mit synthetischen SID-Dateien: 66,167 Sekunden tatsächliche Hörzeit, benannte Marke, Datei- und Subtunenotiz, Hintergrund-Speicherabschluss und Neustart. Aufruf ab Anfang und ab gespeicherter Position trifft Datei und Subtune. „Noch nie gehört“ zeigt die beiden ungespielten Titel. Abbrechen erhält den Verlauf; bestätigtes Leeren setzt Ereignisse und Gehört-Index zurück und erhält Marke sowie beide Notizen. Vorbereitung ohne Play erfasst nichts. Eine neuere Datendatei bleibt bytegleich erhalten und wird schreibgeschützt angezeigt.
- iPhone-Verlauf, Marken, Notizen, leerer Zustand und Schreibschutz-Hinweis in Hell/Dunkel visuell geprüft. Tab-Leiste und Mini-Player bleiben erreichbar. Reale Hardware-Hintergrundfälle sind damit nicht abgenommen.
- Finale HTML5-Kurzsicht unter `file://` mit v1.9.32: verständlicher Dateipfad statt Fingerabdruck in Marken und Notizen, beide Themes nach abgeschlossener Umschaltung geprüft, keine JavaScript-Ausnahme.

Die bestandene kontrollierte Mac-Endprobe von AP04 ist gesondert in [v1.9.31](validation-1.9.31.md) festgehalten. Reale iPhone-Hintergrundwiedergabe, Unterbrechungen und Suspendierung gehören weiterhin zur Geräteabnahme; Simulator und Core-Tests belegen diese Fälle nicht.
