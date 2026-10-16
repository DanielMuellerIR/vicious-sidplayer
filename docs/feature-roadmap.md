# Erweiterungsplan

Stand: 2026-10-16. Ausgangspunkt: v1.9.26.

Dieser Plan setzt die [Erweiterungsanalyse](feature-opportunities.md) um. Jede Stufe umfasst Detailentwurf, Implementierung und Abnahme. Die Budgets sind Aufwandsschätzungen.

| Paket | Ziel | Budget | Status |
|---|---|---|---|
| 01 | PAL/NTSC-Timing | 6–10 h | Abgeschlossen in v1.9.27 |
| 02 | Hörfolgen, Subtunes und Warteschlange: Core und Mac | 8–12 h | Abgeschlossen in v1.9.28 |
| 02b | Hörfolgen auf iPhone und HTML5 | 6–10 h | Abgeschlossen in v1.9.29; iPhone-Nachprüfung erfolgt |
| 03 | Metadatensuche und gespeicherte Filter | 6–10 h | Abgeschlossen in v1.9.30 |
| 04 | Repeat, Fadeout, Endzeiten und Einschlaftimer | 6–10 h | Abgeschlossen in v1.9.31; kontrollierte Mac-Nachprobe bestanden |
| 05 | Verlauf, Lesezeichen und Notizen | 6–10 h | Abgeschlossen in v1.9.32; native und HTML5-Abnahme bestanden |
| 06 | Nativer Austausch persönlicher Sammlungsdaten | 6–10 h | Auf Mac und iPhone in v1.9.35 abgenommen |
| 06b | Sammlungsaustausch in HTML5 | 4–6 h | Abgeschlossen in v1.9.36; nativer Rundlauf und Browser-Speicherschutz geprüft |
| 07 | Solo und getrennte Multi-SID-Steuerung | 4–6 h | Geplant |
| 08 | Piano-, Registeransicht und A/B-Schleifen | 8–12 h | Geplant |
| 09 | Batch-WAV-Export und Mixwahl | 6–10 h | Geplant |
| 10 | Weitere Exportformate | 4–8 h | Geplant |
| 11 | Sammlungsprüfung und Wiederfinden | 6–10 h | Geplant |
| 12 | Formatkompatibilität und klare Grenzen | 6–12 h | Geplant |
| 13 | Tastatur, VoiceOver und anpassungsfähiges Layout | 4–8 h | Geplant |
| 14 | Energie und Zeichenlast | 4–8 h | Geplant |
| 15 | Gezieltes 6581-Filter-Tuning | 6–10 h | Geplant |
| 16 | Reale iPhone-Geräteabnahme und Abschluss | 4–8 h | Geplant |

18 Pakete, insgesamt 100–170 Stunden geschätzter Aufwand. Der Verlauf erhält einen weiteren Tab an derselben Stelle wie Bibliothek/Playlist. Die App bleibt ein Player mit einem Koordinator. Gemeinsame Wiedergabe- und Sammlungsregeln liegen im Core; HTML5 bleibt als lokale Einzeldatei ohne Server nutzbar.

Wiedergabekorrektheit, reaktionsfähige große Sammlungen, übertragbare persönliche Daten und Zugänglichkeit sind durchgehende Abnahmekriterien. Geräteabhängiges iOS-Verhalten braucht echte Hardware.

## Umfang und Abnahme

- **01:** Datei-Taktflags, CPU/VBI/CIA, sichtbarer Auto-/PAL-/NTSC-Modus; Wiedergabe, Seek, Längen und Export mit synthetischen Referenzen und nativer/Web-Parität prüfen.
- **02 / 02b:** Explizite Auswahl, gespeicherte Datei-/Subtune-Listen, Als Nächstes, Reihenfolge, Shuffle ohne Wiederholung und Wiederherstellung. Zuerst Core/Mac, danach iPhone/HTML5. Filteränderungen dürfen die laufende Folge nicht verändern.
- **03:** Metadaten im Hintergrund indexieren, strukturierte Suche und gespeicherte Filter. Start aus vorhandenem Index, Entwertung geänderter Dateien und Messung an großer Sammlung.
- **04:** Repeat für Subtune/Datei/Folge, Fadeout, persönliche Endzeiten und Einschlaftimer. Eine gemeinsame Dauerregel für Scrubber, Auto-Next, Export und Now Playing.
- **05:** Verlauf im gemeinsamen Seitenleistenbereich, Positionslesezeichen und persönliche Notizen. Leere/gefüllte Zustände, fehlende Dateien, Neustart und bewusstes Leeren prüfen.
- **06:** Versioniertes lokales Austauschformat mit relativen Pfaden, Wiederfinden per Fingerabdruck, Konfliktvorschau und Zusammenführen. Musikdateien bleiben unverändert.
- **06b:** Dasselbe lokale Austauschformat in HTML5 anbinden; bisherige FNV-Referenzen erhalten, MD5 nur aus tatsächlich freigegebenen Musikbytes belegen. Konflikte, fehlende Dateien, optionalen Verlauf und tatsächlichen nativen Rundlauf unter `file://` prüfen.
- **07:** Solo und getrennte Chip-/Stimmengruppen. Muten entfernt nur den Mixbeitrag und erhält den Emulationszustand.
- **08:** Piano-/Frequenz- und Registeransicht sowie A/B-Schleifen. Aussagegrenzen bei Noise/Samples anzeigen und Rekonstruktionskosten prüfen.
- **09:** Mehrere Titel/Subtunes als WAV mit Dauer, eindeutigen Namen, Fortschritt, Abbruch und bewusster Mixwahl exportieren. Filterverhalten getrennter Stimmen festlegen.
- **10:** Weitere geeignete Exportformate nach konkreter Machbarkeitsprüfung; Metadaten, Abbruch und verständliche Fehler in denselben Exportablauf einfügen.
- **11:** Fehlende, doppelte, beschädigte und verschobene Titel erkennen, nachvollziehbare Vorschläge anbieten und niemals Musik automatisch löschen.
- **12:** Aktuelle Formatvarianten und Metadatenkodierung anhand echter Referenzen prüfen; unterstützte RSID-Fälle und Grenzen sichtbar dokumentieren.
- **13:** Vollständige Tastaturbedienung, VoiceOver, Hell/Dunkel und enge Fenster im echten Lauf prüfen; Mini-Player bleibt dasselbe Fenster.
- **14:** Zeichenlast und Energie unter gleichen Bedingungen messen und unnötige UI-Arbeit reduzieren. Audio, Auto-Next und Mediensteuerung bleiben unabhängig.
- **15:** 6581-Filter gezielt anhand festgelegter Hörreferenzen abstimmen und A/B-Vergleich dokumentieren; bestehende Kurve als Referenz behalten.
- **16:** Hintergrundwiedergabe, Sperrbildschirm, AirPods, Anruf, Kopfhörerabziehen, Medienreset und Dateiimport auf echtem iPhone abnehmen. Simulatorprüfungen ersetzen diese Fälle nicht.

Hardware-ASID, ein vollständiger reSIDfp-Port sowie die zurückgestellten Audiofingerprint- und MUS/CGSC-Projekte werden dadurch nicht neu eröffnet.
