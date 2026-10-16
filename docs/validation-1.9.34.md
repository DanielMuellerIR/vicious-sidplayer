# Prüfstand v1.9.34

Stand: 2026-10-16. Zweiter AP06-Abschnitt: portables Core-Format, Dateizuordnung, Export und reine Zusammenführung. Die App-Einbindung und Import-/Exportoberflächen sind noch offen; AP06 ist nicht abgeschlossen.

- 333 Swift-Testfälle ohne Fehler, davon vier wegen fehlender lokaler Musikreferenzen übersprungen.
- 313 Linux-Testfälle ohne Fehler, davon 14 plattformbedingt übersprungen.
- Generic-iOS-Simulator-Build ohne Warnungen im eigenen Code bestanden. Die 55 iPhone-Integrationstests des unmittelbar vorangegangenen Speicherabschnitts bleiben gültig; die App-Anbindung wurde hier nicht geändert.
- Elf neue Format-/Merge-Fälle: vollständiger JSON-Rundlauf mit ISO-Zeitpunkten, Sekundenbruchteilen, langen Marken und Unicode; echte Data-Slices; optionaler Verlauf; alte/neue/beschädigte/zu große Eingaben; Traversal und doppelte Schlüssel; zwei Dateiwurzeln mit verschobenem identischem, gleichnamigem verschiedenem und doppeltem Inhalt; Konfliktwahl; fehlende Referenzen; stabile Ersatz-IDs; idempotenter Import; unabhängiger Gehört-Index und Aufbewahrung.
- Eine Liste mit 50.001 Einträgen behält alle Eintrags-IDs. Wiederholter Import ergänzt nichts. Aktive Queue, Repeat, Fade und gespeicherte Timerdauer bleiben beim Merge unverändert.

Importformat und Core-Vorschau sind keine GUI-Abnahme. Die spätere Anwendung muss aktuelle Dateiidentitäten vor der Übernahme erneut prüfen, Writer anhalten und übernehmen, offene Transaktionen vor dem Controllerstart behandeln und ausgelassene Einträge ausdrücklich bestätigen lassen. Die Speicherprüfungen stehen in [v1.9.33](validation-1.9.33.md).
