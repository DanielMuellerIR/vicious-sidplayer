# Persönliche Sammlungsdaten

Stand: 2026-10-16. Die Speichergrundlage für den geplanten Austausch persönlicher Sammlungsdaten ist vorbereitet. Importformat, Konfliktvorschau und Import-/Exportoberflächen folgen; diese Grundlage stellt noch keinen nutzbaren Datenaustausch bereit.

Hörlisten und Wiedergabeoptionen vergleichen ihre Datei vor jedem Schreiben mit den zuletzt erfolgreich gelesenen beziehungsweise selbst geschriebenen Bytes. Eine vorhandene Datei muss vor ihrem ersten Austausch erfolgreich dekodiert und validiert sein. Externe Änderungen einschließlich Löschungen werden beim Speichern nicht überschrieben. Beschädigte, neuere oder zu große Dateien bleiben erhalten. Ein bewusstes erneutes Laden setzt die Vergleichsbasis neu. Vorübergehende Wiedergabeoptionen und Einschlaftimer bleiben auch bei schreibgeschützter Ablage bedienbar.

`PersonalCollectionTransaction` begrenzt einen späteren Import auf die drei bekannten Dateien für Hörlisten, Wiedergabeoptionen und Verlauf. Musikdateien gehören nicht dazu. Vor dem Dateitausch liegen validierte Ersatzdaten, Originalbytes und ein begrenztes Journal im Support-Ordner. Prüfsummen erkennen beschädigte Sicherungen; sie sind keine Authentifizierung einer Importdatei.

Ein Fehler vor dem atomaren Commitmarker setzt bereits ausgetauschte Dateien zurück. Nach einem Prozessende kann dieselbe Wiederherstellung erneut ausgeführt werden. Fremde Änderungen verhindern ein blindes Zurückschreiben; Dateien und Sicherungen bleiben dann für die Klärung erhalten. Ein vollständiger Commit bleibt bis zur Übernahme der Favoriten wiederherstellbar. Die Favoritenübernahme ist idempotent, danach dürfen die Sicherungen entfernt werden.

Der spätere Aufrufer muss vor dem Austausch alle beteiligten Writer abwarten und anhalten, beim Start vor dem Laden der Controller eine offene Transaktion behandeln und anschließend die bestätigten Dokumente übernehmen. Diese Einbindung ist zusammen mit Importformat und Oberfläche noch offen. Die vorhandenen Writer sind bereits geschützt; die Transaktion wird bisher ausschließlich durch ihre gezielten Core-Tests aufgerufen.
