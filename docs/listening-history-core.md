# Verlauf: vorbereiteter Core

Stand: 2026-10-16. Dieser Stand enthält das Datenmodell und seine Tests. Verlauf, Lesezeichen und Notizen sind noch nicht an die App-Oberflächen oder Wiedergabe angebunden. Die Produktversion bleibt deshalb v1.9.31.

`ListeningHistoryRecorder` verarbeitet Beobachtungen mit monotoner Zeit, tatsächlichem Wiedergabestatus, Datei-/Subtune-Identität und Position. Eine vorbereitete Datei erzeugt kein Ereignis. Ein Positionssprung zählt nur die inzwischen wirklich vergangene Wiedergabezeit. Pause und Subtune-Repeat behalten dieselbe Episode; nach einem Wechsel oder einer Pause über 15 Minuten beginnt eine neue. Mehr als 30 Sekunden ohne Beobachtung werden nicht nachträglich als sicher gehörte Zeit ausgegeben. Die Mindestzeit ist zehn Sekunden oder die halbe bekannte Dauer, mindestens eine Sekunde.

`ListeningHistoryDocument` hält standardmäßig höchstens 2.000 sichtbare Ereignisse aus 180 Tagen. Ein kompakter Inhaltsindex bleibt bei automatischer Aufbewahrung erhalten, damit „nie gehört“ nicht durch Kürzen falsch wird. Bewusstes Leeren entfernt auch diesen Index, erhält aber Lesezeichen und Notizen. Der aufrufende Controller muss dabei den Recorder zurücksetzen.

Referenzen tragen Sammlung, Track-ID, Datei-MD5 und optionalen Subtune. Notizen gelten für die ganze Datei oder einen Subtune und folgen demselben Inhalt auch bei einem anderen Sammlungspfad. Mehrere Lesezeichen bleiben unabhängig. Ungültige Identitäten, nicht endliche Zahlen und übergroße Texte werden abgewiesen. Der persönliche Speicher gehört in Application Support, auf iOS außerhalb der sichtbaren Musikdateien.

`ListeningHistoryStore` serialisiert Dateioperationen, prüft das Format vor dem Schreiben und schreibt atomar. Vor dem ersten Schreiben muss geladen werden. Neue, beschädigte, zu große oder zwischenzeitlich extern geänderte Dateien werden erhalten. Nach einer externen Änderung ist bewusstes Neuladen und Zusammenführen nötig. Das Dokument ist auf 32 MiB begrenzt.

Die Integration muss echte Audioausgabe von Seek-Vorbereitung unterscheiden und den bisherigen Titel vor einem Zustandswechsel abschließen. Ein Stop darf die auf null zurückgesetzte Anzeige nicht als zuletzt gehörte Position speichern. Lesezeichen bewahren ihre tatsächliche Position; der bestehende Emulator begrenzt Sprünge derzeit auf 1.200 Sekunden. Die Oberfläche darf einen begrenzten Sprung nicht als erfolgreichen Sprung zu einer späteren Marke ausgeben. Diese Frage bleibt vor der Bedienoberfläche zu lösen; die URL-Fernsteuerungsgrenzen dürfen dabei nicht erweitert werden.

Offen sind Controller, native Verlaufstabs am Bibliotheksort, Lesezeichen-/Notizbedienung, Suchfilter, HTML5-Übernahme und echte GUI-Abnahme.
