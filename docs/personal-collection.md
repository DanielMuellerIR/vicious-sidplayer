# Persönliche Sammlungsdaten

Stand: 2026-10-16. Mac, iPhone und HTML5 tauschen persönliche Sammlungsdaten über dieselbe lokale JSON-Datei aus. Die nativen Apps unterstützen zusätzlich persönliche Endzeiten; im Webplayer sind diese ausdrücklich ausgenommen.

## Bedienung

Auf dem Mac öffnet „Sammlungsdaten …“ in der Seitenleiste die gemeinsame Ansicht. Auf dem iPhone liegt „Persönliche Sammlungsdaten …“ im Menü „Bibliothek verwalten“. Export und Import haben dieselbe Bereichsauswahl; Verlauf bleibt zunächst ausgeschaltet. Ein vorbereiteter Export wird über den systemeigenen Dateidialog gesichert.

Nach Auswahl einer Importdatei zeigt die Vorschau Herkunft, Bereichszahlen, konkrete vorhandene und importierte Konfliktwerte sowie nicht zugeordnete Dateien. Vorhandene Werte sind voreingestellt. Ein vorhandener Pfad ohne Inhaltsbeleg braucht ausdrückliches Vertrauen; das Auslassen nicht zugeordneter Favoriten-/Listeneinträge muss bestätigt werden. Die Importdatei bleibt vollständig erhalten. Abbrechen verändert keine persönlichen Daten.

Während der Vorschau läuft die Wiedergabe weiter. In den nativen Apps pausiert „Zusammenführen“ sie kurz und erhält Titel, Subtune, Position, aktive Folge und Wiedergabeoptionen. Ein inzwischen abgelaufener Einschlaftimer wird nicht bestätigt; die App setzt dann nicht automatisch fort.

## HTML5-Bedienung

„Import / export personal collection“ öffnet Import und Export. Verlauf bleibt standardmäßig aus. Die Vorschau zeigt vorhandene und importierte Konfliktwerte aufklappbar in voller Länge. Eine Pfadannahme lässt sich wieder zurücknehmen; ausgelassene Favoriten-/Listeneinträge brauchen eine Bestätigung. Größere Ergebnisse erscheinen mit höchstens 20 Zeilen pro Seite. „Import selected data“ erhält die aktive Folge, Titel, Subtune und Position; vorbereitete Wiedergabe startet dabei nicht von selbst.

Der Export wird als JSON heruntergeladen. Persönliche Endzeiten werden weder importiert noch exportiert; die vollständige Importdatei bleibt erhalten und kann über „Save original file“ erneut gesichert werden. Nicht bestätigte ältere FNV-Marken, Notizen und Gehört-Werte bleiben im Browser. Der Exportbericht nennt solche Auslassungen und unbestätigte Pfadreferenzen; ein unvollständiger Export braucht eine ausdrückliche Bestätigung. Musikdateien erneut auswählen, um vollständige MD5-Inhaltsbelege zu gewinnen.

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

## Browser-Speicherung

Versionierte Browserdokumente behalten die bisherigen Track-IDs, Queue, Favoriten und Listen. Die alten v1-Speicherwerte werden bei der Migration nicht überschrieben. Vollständige Datei-MD5 werden nur aus ausgewählten Musikbytes berechnet; FNV wird nicht als MD5 umgedeutet. Ältere Referenzen können nach erneuter Musikauswahl gebunden werden. Der unabhängige ältere Gehört-Index bleibt dabei erhalten. Nicht als UUID gespeicherte ältere Eintragskennungen erhalten stabile, kollisionsgeprüfte portable Kennungen.

Alle aktuellen persönlichen Schreibzugriffe verwenden dieselbe Web-Locks-Sperre. Vor dem Schreiben werden beide bisherigen Speicherwerte und die ursprünglichen v1-Werte abgeglichen; eine andere aktuelle oder ältere Playerseite führt zum Schreibschutz. Ein begrenztes Journal hält vorherige und neue Werte der zwei Browserdokumente fest. Vor dem Commitmarker wird zurückgesetzt, danach vervollständigt der frühe Neustart die bestätigten Werte. Unbekannte fremde Änderungen verhindern blindes Zurückschreiben. Speicherknappheit verändert keine Originale; eine blockierte Wiederherstellung erhält das Journal zur Klärung.

Web Locks und Unicode-Segmentierung sind für schreibenden Sammlungsaustausch erforderlich. Fehlen sie, bleibt dieser Bereich schreibgeschützt; Musik lässt sich weiterhin auswählen. Unter file:// sind Chromium 155, zwei Seiten derselben Datei und ein vollständiger Browserprozess-Neustart geprüft. Andere Browser und andere Dateipfade sind damit nicht abgenommen.
