# Prüfstand 1.9.50

Stand: 2026-10-18. Die iPhone-Stimmensteuerung liegt direkt auf den Kurven.

## Änderung

Das Oszilloskop zeichnet wieder über die gesamte Inhaltsbreite und erhält höhere Stimmenzeilen. Tippen auf eine Kurve schaltet die jeweilige Stimme stumm oder wieder ein. Der Solo-Knopf liegt als dezentes S rechts über der Kurve; seine Trefferfläche ist 44 Punkte breit und so hoch wie die Stimmenzeile. Aktive Solos erhalten eine orange Hervorhebung. Beide Aktionen bleiben getrennt und über zugängliche Namen und Zustände bedienbar. Die vorhandenen Regeln für gemeinsam spielende Solos und Vorrang von Mute bleiben erhalten.

## Prüfungen

- Simulator-Build einschließlich Testziel mit SDK 26.5 und 27 sowie unsignierter Geräte-Build erfolgreich; keine Warnungen im eigenen Code. Der bekannte AppIntents-Metadatenhinweis bleibt.
- Alle 80 iOS-Tests bestanden; keine Fehler.
- Echte Simulatorläufe auf iPhone 17 Pro (402 × 874 Punkte) und 17 Pro Max (440 × 956 Punkte): Ein- und Drei-Chip-Dateien, direkte Kurventipps auf unterschiedlichen Positionen, mehrere Solos, Mute mit aktivem Solo, Chip- und Dateiauswahl sowie Wiederherstellung aller Stimmen geprüft.
- Die normale Wiedergabeseite passt einschließlich Subtunes ohne Scrollen; auf dem kleineren Gerät bleibt die vollständige Werkzeuge-Trefferfläche gut zwölf Punkte oberhalb der Tab-Leiste. Die Stimmenzeilen sind dort gut 60 Punkte hoch, Solo ist 44 Punkte breit.
- Heller und dunkler Modus sowie größte Schrift visuell geprüft. Die großen Textansichten scrollen tatsächlich bis zu den unteren Controls; die Solo-Beschriftung bleibt kompakt. Zugängliche Namen und Zustände sind vorhanden. Das ersetzt keine echte VoiceOver-Geräteabnahme.

## Grenzen

Core, DSP, Songende und Audioereignisse wurden nicht verändert. Die bereits in 1.9.49 geprüften automatischen Wechsel werden dadurch nicht als neue Korrektur des sporadischen echten iPhone-Stopps gewertet. Dessen Ursache bleibt ungeklärt; die Playback-Systemlogs aus 1.9.49 sind für eine neue Beobachtung vorhanden. Nicht durchgeführte Gerätefälle aus AP16 bleiben unbelegt.
