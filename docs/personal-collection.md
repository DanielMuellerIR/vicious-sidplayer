# Persönliche Sammlungsdaten

Stand: 2026-10-16. Auf Mac und iPhone lassen sich persönliche Sammlungsdaten über eine lokale JSON-Datei austauschen. Die HTML5-Oberfläche behält ihre bisherigen lokalen Daten; ihr Sammlungsaustausch wird separat ergänzt.

## Bedienung

Auf dem Mac öffnet „Sammlungsdaten …“ in der Seitenleiste die gemeinsame Ansicht. Auf dem iPhone liegt „Persönliche Sammlungsdaten …“ im Menü „Bibliothek verwalten“. Export und Import haben dieselbe Bereichsauswahl; Verlauf bleibt zunächst ausgeschaltet. Ein vorbereiteter Export wird über den systemeigenen Dateidialog gesichert.

Nach Auswahl einer Importdatei zeigt die Vorschau Herkunft, Bereichszahlen, konkrete vorhandene und importierte Konfliktwerte sowie nicht zugeordnete Dateien. Vorhandene Werte sind voreingestellt. Ein vorhandener Pfad ohne Inhaltsbeleg braucht ausdrückliches Vertrauen; das Auslassen nicht zugeordneter Favoriten-/Listeneinträge muss bestätigt werden. Die Importdatei bleibt vollständig erhalten. Abbrechen verändert keine persönlichen Daten.

Während der Vorschau läuft die Wiedergabe weiter. „Zusammenführen“ pausiert sie kurz und erhält Titel, Subtune, Position, aktive Folge und Wiedergabeoptionen. Ein inzwischen abgelaufener Einschlaftimer wird nicht bestätigt; die App setzt dann nicht automatisch fort.

## Austauschformat

Das UTF-8-JSON-Dokument trägt den Bezeichner `vicioussid.personal-collection` und `version: 1`. Es enthält einen Sammlungsnamen, einen ISO-8601-Erstellungszeitpunkt, Dateifavoriten, geordnete Hörlisten mit Eintrags-UUIDs, benannte Positionsmarken, Datei-/Subtunenotizen und persönliche Endzeiten. Dateireferenzen verwenden relative SID-Pfade und optional einen MD5 des vollständigen Dateiinhalts. Musikbytes, absolute Wurzeln, lokale Sammlungs-IDs, aktive Queue, Lautstärke und Timer werden nicht übertragen. Zeitpunkte werden mit Millisekundenauflösung kodiert; Sekundenpositionen bleiben ungerundet.

Hörverlauf ist standardmäßig ausgeschlossen. Sein ausdrücklicher Export enthält die zur Sammlung gehörenden Episoden und die gesamte unabhängige Gehört-Kennzeichnung. Der Gehört-Index besitzt keine Sammlungszuordnung und wird daher nicht aus den sichtbaren Episoden rekonstruiert. Nicht zuordenbare Endzeiten und Referenzen ohne Inhaltsbeleg werden im Exportergebnis gezählt beziehungsweise benannt.

Das Format ist auf 32 MiB begrenzt. Absolute Pfade, Traversal, ungültige Zahlen, doppelte IDs und Notizschlüssel sowie unbekannte Versionen werden abgewiesen. Neue Austauschversionen brauchen eine ausdrücklich ergänzte Migration.

## Zuordnung und Zusammenführung

Ein Pfad mit passendem Inhalt wird direkt zugeordnet. Ansonsten zählt nur ein eindeutiger Inhaltsfund. Fehlende Dateien, geänderter Inhalt, doppelte Inhaltsfunde und Pfadtreffer ohne Inhaltsbeleg bleiben getrennte Ergebnisse. Unbestätigte Pfadtreffer brauchen eine bewusste Auswahl. Nicht zugeordnete Favoriten-/Listeneinträge werden gezählt und ausgelassen; Marken und Notizen bleiben mit Inhaltsbeleg erhalten und können keine andere Datei allein wegen ihres Namens abspielen.

Die reine Vorschau verändert keine Ablage und startet keine Wiedergabe. Favoriten und Subtune-Favoriten werden vereinigt. Reguläre Listen erhalten Reihenfolge, Eintragsidentitäten und bewusst wiederholte Titel. Abweichende Listen, Marken, Notizen, Endzeiten und kollidierende Hörepisoden bleiben bei den vorhandenen Werten, bis eine Auswahl getroffen ist. Eine Liste einer anderen Sammlung oder Listenart wird bei einer Kennungskollision geschützt. Wiederholter Import derselben Daten ergänzt nichts; fortgesetzte Hörepisoden verwenden die größere belegte Hörzeit statt einer Summe. Aktive Queue und Wiedergabeoptionen bleiben unverändert.

## Speicherung

Hörlisten und Wiedergabeoptionen vergleichen ihre Datei vor jedem Schreiben mit den zuletzt erfolgreich gelesenen beziehungsweise selbst geschriebenen Bytes. Eine vorhandene Datei muss vor ihrem ersten Austausch erfolgreich dekodiert und validiert sein. Externe Änderungen einschließlich Löschungen werden beim Speichern nicht überschrieben. Beschädigte, neuere oder zu große Dateien bleiben erhalten. Ein bewusstes erneutes Laden setzt die Vergleichsbasis neu. Vorübergehende Wiedergabeoptionen und Einschlaftimer bleiben auch bei schreibgeschützter Ablage bedienbar.

`PersonalCollectionTransaction` begrenzt den Import auf die drei bekannten Dateien für Hörlisten, Wiedergabeoptionen und Verlauf. Musikdateien gehören nicht dazu. Vor dem Dateitausch liegen validierte Ersatzdaten, Originalbytes und ein begrenztes Journal im Support-Ordner. Prüfsummen erkennen beschädigte Sicherungen; sie sind keine Authentifizierung einer Importdatei.

Ein Fehler vor dem atomaren Commitmarker setzt bereits ausgetauschte Dateien zurück. Nach einem Prozessende kann dieselbe Wiederherstellung erneut ausgeführt werden. Fremde Änderungen verhindern ein blindes Zurückschreiben; Dateien und Sicherungen bleiben dann für die Klärung erhalten. Ein vollständiger Commit bleibt bis zur Übernahme der Favoriten wiederherstellbar. Die Favoritenübernahme ist idempotent, danach dürfen die Sicherungen entfernt werden.

Die nativen Apps behandeln offene Transaktionen gemeinsam vor dem ersten Laden der drei Controller. Vor einer Übernahme warten sie betroffene Writer ab und halten sie an; verzögerte alte Aufträge sind entwertet. Erst nach bestätigtem Dateitausch und Favoritenübernahme verwenden die Controller die neuen Dokumente. Bei einer blockierten Wiederherstellung bleiben Dateien und Sicherungen erhalten; weitere Änderungen warten auf einen Neustart beziehungsweise die Klärung der fremden Änderung.
