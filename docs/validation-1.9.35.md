# Prüfstand v1.9.35

Stand: 2026-10-16. Der Sammlungsaustausch auf Mac und iPhone ist implementiert und abgenommen. Der HTML5-Austausch folgt als eigener Abschnitt AP06b.

- 345 Swift-Testfälle ohne Fehler, davon vier wegen fehlender lokaler Musikreferenzen übersprungen.
- 314 Linux-Testfälle ohne Fehler, davon 14 plattformbedingt übersprungen. Die danach ergänzten Controller-Integrationstests verwenden Combine und gehören zum vollständigen Swift-Lauf auf macOS.
- 55 iPhone-Integrationstests ohne Fehler. Generic-iOS-Simulator-Build ohne Warnungen im eigenen Code bestanden.
- Mac-App-Bundle erfolgreich gebaut, signiert und notarisiert; angeheftetes Ticket und Gatekeeper-Prüfung bestanden. Die Fleet-Quellprüfung besteht.
- Gemeinsame Startup-Wiederherstellung vor allen drei Controller-Ladevorgängen geprüft, einschließlich bereits bestätigter Datenübernahme und nachzuziehender Favoriten.
- Import hält betroffene Writer an, wartet ihre Aufträge ab und übernimmt die bestätigten Dokumente. Verzögerte alte Schreibaufträge ersetzen das Importergebnis nicht. Eine laufende Hörepisode kann nach importierter größerer Hörzeit korrekt weitergeführt werden.
- Bereichsauswahl erhält Queue, Repeat, Fade und laufenden Einschlaftimer. Ein während der Übernahme abgelaufener Timer verhindert automatisches Fortsetzen. Eine nicht ausgewählte neuere Verlaufsdatei bleibt unangetastet.
- Nach der Vorschau geänderte Musikbytes verhindern bereits die Pause und sämtliche persönlichen Änderungen. Extern geänderte persönliche Dateien bleiben geschützt.
- Schließen während des letzten Dateiabgleichs verwirft die Übernahme vor Pause oder Mutation. Eine erneuerte Vorschau verwirft Entscheidungen zu inzwischen geänderten Konfliktwerten.
- Verlauf bleibt ohne ausdrückliche Auswahl unverändert. Nach Auswahl wird dieselbe Hörepisode beim wiederholten Import einmal geführt. Ein fehlender Subtune lässt sich auch bei einer Referenz ohne MD5 nicht durch bloßes Vertrauen auf den Pfad bestätigen.

Auf dem Mac sind echte Import-/Exportdialoge einschließlich Abbruch, konkrete Notiz-/Endzeitwahl und Risikoübernahme geprüft. Die aktive Folge blieb gleich, die Position lief ohne Reset weiter; Repeat, Fade, Timeroption und Musikbytes blieben erhalten. Der Wiederholungsimport war ohne neue Änderungen, der Verlauf blieb bis zur ausdrücklichen Auswahl aus. Beide tatsächlichen Mac-Exportdateien bestehen den nativen Codec-Rundlauf. Die abschließende Sichtprüfung bestätigt aufklappbare vollständige Konfliktwerte, widerrufbares Pfadvertrauen und lesbare Schutzgründe im Dunkelmodus; die neuere Verlaufsdatei blieb bytegleich.

Auf dem iPhone wurde eine echte Mac-Exportdatei über den systemeigenen Dateipicker importiert. Eindeutig verschobene Inhalte wurden ihren neuen relativen Pfaden zugeordnet. Zwei Favoriten, eine Liste mit zwei bewusst gleichen Subtunes und verschiedenen Eintrags-IDs, eine Marke bei 42,125 Sekunden, zwei Notizen einschließlich fehlender Datei und eine Endzeit von 125,5 Sekunden blieben erhalten. Aktive Folge, vorbereitete Position und Musikbytes änderten sich nicht. Der Wiederholungsimport zeigte null Ergänzungen und null Aktualisierungen.

Verlauf blieb zunächst leer; erst die bewusste Auswahl übernahm vier Hörepisoden mit ihren ursprünglichen IDs und der unabhängigen Gehört-Kennzeichnung. Eine konkrete Notizwahl mit anschließendem Schließen sowie der echte Dateipicker-Abbruch ließen die persönlichen Dokumente bytegleich. Helle und dunkle Ansichten, vollständig aufgeklappte lange Konfliktwerte und lesbare Schutzgründe wurden visuell geprüft. Nach Neustart blieb Subtune 3 bei 0:42 vorbereitet, ohne Autostart; die persönliche Endzeit erschien als 2:05. Eine neuere Verlaufsdatei blieb auch nach Beenden bytegleich.

Der tatsächlich über den iPhone-Dateidialog gesicherte Rückexport wurde auf dem Mac mit dem aktuellen nativen Codec dekodiert und erneut kodiert. Inhaltsidentitäten, Listen-/Eintrags-/Marken-/Notiz-/Episoden-IDs, Subtunes, Texte, genaue Sekundenwerte, Zeitpunkte und Hörzeiten stimmen mit dem ursprünglichen Mac-Export überein. Nur die relativen Pfade wurden an die Zielsammlung angepasst. Die Testdaten wurden nach der Abnahme wiederhergestellt.

Der HTML5-Austausch benötigt AP06b: Die bisherigen Browserdaten verwenden FNV-Fingerabdrücke und dürfen nicht als native MD5-Identitäten ausgegeben werden.

Geräteabhängige iPhone-Audiofälle bleiben Teil der Hardwareabnahme in `ios/GERAETETEST.md`.
