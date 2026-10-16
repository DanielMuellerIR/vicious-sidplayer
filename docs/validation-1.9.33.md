# Prüfstand v1.9.33

Stand: 2026-10-16. Erster AP06-Abschnitt: Schutz der bestehenden persönlichen Ablagen und vorbereitete Mehrdatei-Transaktion. AP06 ist damit noch nicht abgeschlossen; Importformat, Zusammenführung und Oberflächen sind offen.

- 322 Swift-Testfälle ohne Fehler, davon vier wegen fehlender lokaler Musikreferenzen übersprungen.
- 302 Linux-Testfälle ohne Fehler, davon 14 plattformbedingt übersprungen.
- 55 iPhone-Simulator-Tests bestanden. Die Containerumzugs-Prüfung wartet nun auf beide Controller, die die Wiederherstellung voraussetzt. Generic-iOS-Simulator-Build ohne Warnungen im eigenen Code bestanden; der SDK-Hinweis zu ungenutzten AppIntents bleibt unverändert.
- Fleet-Schutzregeln bestanden. Die App-Oberfläche wurde in diesem Abschnitt nicht geändert.
- 13 neue Persistenz-/Transaktionsfälle prüfen externe Änderungen und Löschungen, beschädigte/neue/zu große Daten, Flush vor Import, Fehler beim zweiten Dateitausch einschließlich neu angelegter Dateien, Prozessende vor/nach Commitmarker, wiederholten Abschluss, abweichende Favoriten, beschädigte Sicherungen und unzulässige Journalziele.
- Vorübergehende Wiedergabeoptionen bleiben bei geschützter Datei nutzbar; die ursprüngliche Controller-Prüfung ist unverändert bestanden.

Die Transaktion ist noch nicht an den App-Start oder eine Importoberfläche gebunden. Eine neue GUI-Abnahme wird mit den späteren Import-/Exportansichten erforderlich. Die AP05-Abnahme bleibt in [v1.9.32](validation-1.9.32.md) dokumentiert.
