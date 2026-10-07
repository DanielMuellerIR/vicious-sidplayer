# Aktiver Backlog

1. ~~STIL-Integration~~ **auf dem Mac erledigt am 2026-08-23 (v1.9.12).** Parser,
   Zuordnung über die HVSC-Wurzel und Auto-Fund stehen im Core (`STIL.swift`,
   18 Tests), die Mac-App zeigt Ordner-, Datei- und Subtune-Anmerkungen in der
   Seitenleiste, die iPhone-App unter dem Titelkopf; beide haben einen eigenen
   Einstellungs-Eintrag zum Auswählen der Datei. **Core-Abnahme an echter STIL v84
   erledigt am 2026-10-01:** 18.475 Dateieinträge und 246 Ordner, LF/CRLF-Parität,
   Auto-Fund, HVSC-Pfad, Subtunes und eindeutige Pfadenden geprüft. Der
   Latin-1-Fallback funktioniert seit v1.9.23 auch unter Linux. **Mac-Anzeige
   am 2026-10-07 mit synthetischen Fixtures in der nativen App geprüft:**
   Datei-/Ordnerkommentare, Subtunes, eindeutige Pfadenden sowie unbekannte und
   mehrdeutige Titel. Reine Ordnerkommentare werden seit v1.9.24 ebenfalls
   aufgelöst; breite Seitenleisten schneiden keine Beschriftungen mehr ab.
   **Die visuelle STIL-Abnahme auf iOS bleibt offen.**
2. ~~HVSC-Browser/Bibliotheksansicht~~ **erledigt am 2026-08-23 (v1.9.14).** Die
   Mac-App hat jetzt denselben aufklappbaren Ordnerbaum wie die iPhone-App,
   umschaltbar im Kopf der Seitenleiste. Das Flachklopfen des Baums steht im
   Core (`LibraryOutline`, 10 Tests) und wird von beiden Apps benutzt — vorher
   stand es ungetestet im iOS-App-Ziel. Der aufgeklappte Zustand bleibt über
   App-Starts erhalten, „alles auf-/zuklappen" gibt es im Kopf der Seitenleiste
   (v1.9.15).
3. ~~Mini-Player~~ **erledigt am 2026-08-23 (v1.9.18).** Die Mac-App schaltet über
   „Wiedergabe → Mini-Player" (⌘⌥M) oder den Pfeil in der Leiste auf eine
   kompakte Fensterleiste um: App-Symbol, Titel, Komponist, Spielzeit und
   Transport. Das Fenster schrumpft dabei und nimmt beim Zurückschalten wieder
   seine vorherige Größe an. Umgesetzt als **kompakte Fassung desselben
   Fensters**, nicht als zweites Fenster — die App ist bewusst eine
   Ein-Fenster-App (siehe `AppMain.swift`), ein zweites Fenster brächte einen
   zweiten Koordinator und damit doppelte Wiedergabe.
4. ~~Agenteneinstieg~~ **erledigt am 2026-08-23 (v1.9.19)** — als **URL-Schema**,
   nicht als HTTP-Server. `open vicioussid://next` steuert die laufende Mac-App;
   ein Netzwerkdienst bräuchte Bindeadresse, Zugangsschutz und Pflege und wäre
   die deutlich größere Angriffsfläche. Erlaubt sind Wiedergabesteuerung, Sprung,
   Subtune und die Auswahl eines Titels **aus der Bibliothek**; alles andere wird
   verworfen (`RemoteCommand` im Core, 12 Tests). Bewusst nicht dabei: Zugriff auf
   beliebige Dateien, Einstellungen, Export, Beenden — ein URL-Schema kann jede
   Webseite auslösen.
5. Filter-Cutoff-Tuning für 6581. **Offen: Hörvergleich und Referenz für die gewünschte
   Klangänderung; ohne diesen Beleg bleibt die bestehende Kurve erhalten.** Ersetzt dauerhaft einen vollständigen reSIDfp-Port
   (Entscheidung 2026-07-15): holt den hörbaren Teil des Gewinns ohne Engine-Umbau.

## iOS-Nacharbeit (Stand 2026-07-26)

- **Gerätetest steht aus**, Prüfliste in [`ios/GERAETETEST.md`](ios/GERAETETEST.md).
  Bis dahin gelten Hintergrundwiedergabe, Sperrbildschirm, AirPods, Anrufverhalten,
  Kopfhörerabziehen und der File-Provider-Import aus Nextcloud/iCloud als **unbelegt** —
  nicht als kaputt, aber eben auch nicht als geprüft.
- `setPreferredIOBufferDuration(10 ms)` ist ein Startwert aus dem Plan, kein
  Messergebnis. Auf dem Gerät nachmessen und gegebenenfalls anpassen.
- ~~Media-Services-Reset~~ **behoben am 2026-08-23 (v1.9.16).**
  `ViciousCoordinator.rebuildAudioEngine()` legt die `AVAudioEngine` neu an, der
  iOS-Wiederaufbau ruft sie statt `stop()`. Belegt ist auf dem Mac, dass die
  Wiedergabe nach dem Neuaufbau wieder läuft (erster Test des Koordinators
  überhaupt). Der echte Reset ist im Simulator nicht auslösbar; die Abnahme
  steht als Punkt 9 in [`ios/GERAETETEST.md`](ios/GERAETETEST.md).
- Entschieden (2026-08-06): Der Sessionauftrag `goal-prompt.md` ist aus dem
  Arbeitsstand entfernt; der Architekturplan `tasks/2026-07-26-ios-app/plan.md`
  bleibt als dauerhaft relevante Entscheidungsgrundlage im Repo.
- Querformat funktioniert, ist aber nicht ausgereizt (Hochformat war die Vorgabe).
- App-Icon ist programmatisch erzeugt und zweckmäßig, kein gestaltetes Motiv.
- Offene Entscheidung: Die Sitzungswiederherstellung bereitet den Titel nur vor und
  spielt **nicht** von selbst los — bewusst anders als die Mac-App, damit die App beim
  Öffnen nicht ungefragt aus der Hosentasche dudelt. Umdrehen ist eine Zeile in
  `ios/ViciousSIDPlayer/Player/AppModel+Playback.swift`.
- Der Import liest jede Datei vollständig in den Speicher (nötig für MD5-Dedupe und
  für das koordinierte Lesen von File-Provider-Platzhaltern). Bei SID-Dateien
  unkritisch; erst relevant, falls je größere Formate dazukommen.

## Offen aus der CodeQA-Kampagne vom 2026-08-15

Die Kampagne hat alle Bereiche des Repos abgedeckt; ihr Abdeckungsstand wird
außerhalb des Repos geführt.
Was sie bewusst **nicht** angefasst hat, steht hier — jeder Punkt ist geprüft und
belegt, keiner ist eine Vermutung.

1. ~~**Mac-App auf den Core zurückbauen.**~~ **Erledigt am 2026-08-15 (v1.9.8 und
   v1.9.9).** Playlist-Aufbau, Deduplikation, Suche, Favoriten und die Rechnung für
   den nächsten Titel stehen im Core (`Playlist`), der Ordner-Scan in
   `MusicLibrary`; `MainView` hält nur noch Zustand. Mit v1.9.9 folgte die
   **Songlängen-Auflösung**: Reihenfolge der Quellen, negativer Cache und die
   Buchführung über die laufende Berechnung stehen jetzt in `SongLengthResolver`,
   die Leiter zur effektiven Dauer in `SongLengthSelection` — beide Apps benutzen
   dieselbe Instanz der Regel, und sie ist erstmals getestet (20 Tests). Der
   Bibliotheks-Scan der Mac-App lief zuletzt noch **synchron** beim Start; das ist
   mit v1.9.11 erledigt (Hintergrund-Scan, Liste sofort aus dem gespeicherten
   Index).

2. ~~**Paralleler Abbau in `AVAudioEnginePCMSink.stop()`.**~~ **Behoben am
   2026-10-01 (v1.9.23).** Vier gleichzeitige Stop-Aufrufe reproduzierten mit
   stummen Samples ein Datenrennen und einen Absturz. Ein separates Lock
   serialisiert nun Aufbau, Pause, Fortsetzen und Abbau der Engine samt Knoten
   und Zwischenpuffer. Dieselbe ThreadSanitizer-Gegenprobe blieb danach in
   20 Runden ohne Befund; ein Core-Regressionstest deckt den Abbau ab.

3. ~~**ALSA-Startfehler lassen den Sink startbar zurück.**~~ **Behoben am
   2026-10-01 (v1.9.23).** Auf Linux vor der Korrektur reproduziert. Ungültiges
   Format und fehlendes Gerät enden nun mit `.failed`, weitere Starts werden
   abgelehnt. Aufbau und Zustandswechsel sind gemeinsam gesperrt. Die
   Linux-Regressionstests benötigen keine Soundkarte; hörbare Wiedergabe und
   Desktop-/Medientasten-Abnahme bleiben davon getrennt offen.

4. **Library Reset mit Rücknahme bei Fehlern (2026-10-07, v1.9.24).**
   Der gesamte Auftrag wird vorab auf sichere Pfade geprüft. Musik, Index und
   Cache werden zunächst auf demselben Dateisystem verschoben; ein Fehler nimmt
   die bereits ausgeführten Schritte zurück. Erst der erfolgreiche Commit leert
   Titel, Position, Session, Favoriten und den Cache im Speicher. Ein zusätzlicher
   Fehler beim Zurücklegen nennt die erhaltenen Wiederherstellungsorte. Bleibt
   nach dem erfolgreichen Reset Speicher in einem ausgeblendeten Zwischenordner
   belegt, meldet die App das ausdrücklich. Deterministische Fehler bei jedem
   Verschiebeschritt und ein iOS-Fehlerfall mit erhaltenem App-Zustand sind geprüft.

5. **iPhone-Oberfläche am 2026-10-07 im Simulator visuell geprüft.** Die
   Mini-Player-Leiste muss per `safeAreaInset` am Tab-INHALT hängen (an der `TabView`
   verdeckt sie die Tab-Leiste und macht die App ab dem ersten Titel unbedienbar), und
   der Zeichentakt des Oszilloskops muss über `TimelineView(paused:)` an
   `isSceneActive` hängen. Beides ist korrekt umgesetzt, aber an SwiftUI-Strukturen
   ist kein sinnvoller Test aufzuhängen.

   Mini-Player in Bibliothek und Einstellungen, erreichbare Tabs, Pause,
   Hintergrund/Rückkehr sowie STIL für Datei/Subtune/Ordner und unbekannte
   beziehungsweise mehrdeutige Titel sind im realen Simulatorlauf belegt.
   Eine Messung der tatsächlichen Zeichenrate im Hintergrund ist damit nicht
   verbunden.

## Gemessen am 2026-08-23 an 50.001 Titeln (v1.9.11)

Der erste Lasttest der Mac-App mit einer Sammlung in HVSC-Größe. Zwei Abstürze und
der Speicherverbrauch sind behoben (siehe CLAUDE.md, Abschnitt „UI- und
Systemverhalten"). Was dabei auffiel und **offen** bleibt:

- ~~Rund 50 % eines Prozessorkerns im laufenden Betrieb~~ — **aufgeklärt und zur
  Hälfte behoben am 2026-08-23 (v1.9.17).** Es war weder die Emulation noch das
  Zeichnen: Das Oszilloskop einzufrieren änderte nichts (48 %), den 50-Hz-Takt zu
  drosseln dagegen alles (25 % bei 5 Hz). Schuld war die Zustellung der
  Anzeigewerte über `@Published` — sie warf 50-mal je Sekunde den ganzen Rumpf
  der Oberfläche neu auf. Jetzt 31 %. Der Rest ist die eigentliche
  SID-Emulation plus das Zeichnen; ob und wie weit sich das noch senken lässt,
  ist ungemessen.
- Die Titelliste wurde am **2026-10-07 mit v1.9.24 erneut gemessen**:
  1 / 5.001 / 25.001 / 50.001 synthetische Titel, jeweils derselbe pausierte
  Titel und flache Liste, ergaben 114,47 / 133,70 / 198,47 / 280,91 MiB RSS.
  Die Differenz entspricht rund **3,41 KiB je zusätzlichem Titel**. Kein
  Absturz; die früheren 362/157-MB-Werte sind wegen anderer Laufbedingungen
  kein direkter Vergleich. Die Ursache des verbleibenden Verbrauchs ist
  weiterhin unbestimmt; daraus folgt noch kein konkreter Optimierungsauftrag.
- ~~Die iOS-Testsuite hinterlässt im Simulator je Test eine eigene
  UserDefaults-Datei (`vsp-tests-<UUID>.plist`). `removePersistentDomain` leert
  sie, löscht die Datei aber nicht; nach einigen Läufen liegen dort hunderte.
  Folgenlos für die App, aber unsauber — beobachtet am 2026-08-23.~~ **Behoben am
  2026-10-01:** feste Suite je Testklasse, vor und nach jedem Test geleert.
  Die 35 Simulator-Tests bestehen; nur zwei feste Test-Suite-Dateien bleiben.
- Der Hintergrund-Scan über 50.001 Dateien dauert headless 4,2 s, in der
  laufenden App aber 3,6 bis 24 s — er läuft mit niedriger Priorität neben der
  Wiedergabe. Erträglich, aber ungemessen ist, ob ein Zwischenstand der Liste
  (statt „alles am Ende") sich lohnt.

Linux-Port (CLI, ALSA und MPRIS) implementiert nach
`tasks/2026-07-05-linux-port/plan.md`. Core und Startfehler auf Linux geprüft;
die hörbare Wiedergabe, Pause/Subtune ohne Knackser und Desktop-Medientasten
benötigen weiterhin eine echte Linux-Audio-/Desktop-Sitzung.

Permanent zurückgestellt, nur Kandidaten für schlimme Langeweile: Audiofingerprint/
WhatsSID (bräuchte serverseitige Fingerprint-DB über die HVSC), MUS/CGSC (eigenes Format
plus eigene Player-Routine für einen kleinen Sammlungszweig).

Gestrichen: ASID/Echt-SID-Hardware (2026-07-15) — nicht wieder aufnehmen.

Erledigte Release-/Quick-Look-/v1.5.0-Arbeit nicht zurückführen. Ebenfalls erledigt und
nicht zurückzuführen: die iOS-App selbst (früher Punkt 0) und der auf `.sid` gefilterte
Öffnen-Dialog (früher Punkt 6, gelöst über `SidFileType` im Core).
