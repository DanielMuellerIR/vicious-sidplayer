# Prüfung von v1.9.31

Stand: 2026-10-16. Wiedergabeoptionen für macOS und iPhone.

Repeat unterscheidet aktuellen Subtune, ganze Datei und aktive Hörfolge. Persönliche Endzeiten gehören zum Dateiinhalt und Subtune; sie haben vor HVSC, positivem berechnetem Cache und Fallback Vorrang. Suche, Scrubber, Auto Next, Now Playing und WAV verwenden dieselbe Dauerregel. Die Eingabe bewahrt Sekundenbruchteile beim erneuten Bearbeiten. Ein Fade skaliert den fertigen Mono-/Stereo-Mix, ohne Emulation, Filter, Mute oder gespeicherte Nutzerlautstärke zu verändern.

Der Einschlaftimer verwendet eine monotone Frist, läuft während Pause weiter und übersteuert Repeat. Seek und Titelwechsel starten ihn nicht neu. Seine Fade-Projektion benutzt die genaue Frist zwischen den Anzeige-Ticks. Eine aktive Frist wird nicht restauriert. Nach Ablauf bleibt automatisches iPhone-Resume gesperrt; eine bewusste Play-Aktion oder Queue-Auswahl kann wieder starten. Neuere oder beschädigte Einstellungsdateien bleiben erhalten.

## Ausgeführt

- 288 Core-Tests, davon vier fehlende lokale Musikreferenzen übersprungen; keine Fehler. Auf Linux 272 Tests mit 14 plattformbedingten Skips; keine Fehler.
- 52 iOS-Tests erfolgreich. Enthalten sind persönliche Dauer vor HVSC/Berechnung, Dateirepeat mit festen Listeneinträgen und restaurierter Subtune-Position, Timerablauf, gesperrtes automatisches Resume sowie bewusster Neustart per Play und Queue-Auswahl. Abschließende Dialogänderungen zusätzlich für `generic/platform=iOS Simulator` gebaut.
- Fade: tatsächliche Mono-/Stereo-Samples gegen eine unabhängige Hüllkurve, Lautstärkeänderung, weiterlaufende SID-Register, Seek/Neustart sowie WAV-Dauer, PCM und Fehler ohne beschädigte Zieldatei. Fade aus war für PAL und NTSC bei je 88.200 Samples bitgleich zur Referenz.
- 37 Webtests und beide Single-File-Buildvarianten erfolgreich. Taktwechsel während eines portionierten Seeks behalten jetzt das vollständige Ziel, auch bei mehrfacher Umstellung.
- Native Takt-/Subtune-Kollision im echten Audio-Koordinator geprüft: Nach abgebrochener Vorbereitung läuft der neue Subtune mit dem gewählten Takt. Bibliotheksabgleich behält reguläre wiedergefundene Titel neben einmaligen Wünschen und aktualisiert die Umlaufregel nach Wachstum oder Schrumpfen.
- Automatische verzögerte Speicherung ohne Flush, neuere Datendatei unverändert, Timer genau einmal beendet und keine aktive Timerwiederherstellung geprüft.
- Mac-Bundle gebaut und Fleet-Guards einschließlich Binärprüfung erfolgreich.

## Echte Ansichten

Auf dem Mac wurden beim ersten Öffnen das richtige Endzeitziel, Eingabe und Speicherung von zwei Sekunden sowie die Repeat-Auswahl geprüft. Die kontrollierte Nachprobe am 2026-10-16 bestand mit ausgeschaltetem Auto Next: Derselbe Subtune lief bei zwei Sekunden Endzeit über zwei Enden hinaus weiter. „Nach diesem Subtune“ stoppte anschließend die Wiederholung. Exakt identifizierte Play-/Pause-Controls, unveränderte Subtune-Anzeige und eigene Fensterscreenshots belegten beide Zustände. Einstellungen und persönliche Dateien wurden danach bytegleich wiederhergestellt.

Die Hüllkurvenform ist durch die Sampletests belegt; GUI-Proben verwendeten stumme synthetische Dateien. Wiedergabeoptionen wurden im Hellmodus, Bibliotheksansichten in Hell/Dunkel und schmal geprüft. Testeinstellungen und persönliche Dateien wurden anschließend wiederhergestellt.

Auf dem iPhone wurden das richtige Ziel beim ersten Öffnen, die übernommene Endzeit, Fade-Einstellung und Repeat geprüft. Eine gesetzte Subtune-Endaktion stoppte trotz Repeat; nach App-Neustart lief Repeat ohne restaurierte Endaktion wieder weiter. Endzeit, Fade und Repeat blieben in der persönlichen Datei erhalten. Die Wiedergabeoptionen wurden im Hellmodus und die Bibliotheksansichten in Hell/Dunkel geprüft. Hardwareabhängige Hintergrund-, Anruf-, AirPods- und Medienresetfälle bleiben der realen Geräteabnahme vorbehalten.
