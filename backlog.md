# Aktiver Backlog

1. STIL-Integration aus einer vom Nutzer bereitgestellten HVSC-`STIL.txt`; Auto-Fund
   nach dem vorhandenen Songlength-Muster, kein Bundling der Datenbank.
2. HVSC-Browser/Bibliotheksansicht für große Sammlungen statt ausschließlich flacher
   Playlist — **nur noch für die Mac-App offen**. Die iPhone-App hat den aufklappbaren
   Ordnerbaum bereits, und `MusicLibrary` im Core liefert Index und Baum
   plattformneutral; die Mac-App nutzt beides noch nicht.
3. Mini-Player mit Titel und Transportsteuerung — **nur noch für die Mac-App offen**
   (auf iOS erledigt).
4. HTTP-Remote oder URL-Schema nur als kleiner, abgesicherter Agenteneinstieg; CLI ist
   bereits der primäre Headless-Weg.
5. Filter-Cutoff-Tuning für 6581. Ersetzt dauerhaft einen vollständigen reSIDfp-Port
   (Entscheidung 2026-07-15): holt den hörbaren Teil des Gewinns ohne Engine-Umbau.

## iOS-Nacharbeit (Stand 2026-07-26)

- **Gerätetest steht aus**, Prüfliste in [`ios/GERAETETEST.md`](ios/GERAETETEST.md).
  Bis dahin gelten Hintergrundwiedergabe, Sperrbildschirm, AirPods, Anrufverhalten,
  Kopfhörerabziehen und der File-Provider-Import aus Nextcloud/iCloud als **unbelegt** —
  nicht als kaputt, aber eben auch nicht als geprüft.
- `setPreferredIOBufferDuration(10 ms)` ist ein Startwert aus dem Plan, kein
  Messergebnis. Auf dem Gerät nachmessen und gegebenenfalls anpassen.
- Nach einem Media-Services-Reset (`mediaServicesWereReset`) baut die App den
  Titel zwar neu auf, verwendet dabei aber weiterhin die einmal erzeugte
  `AVAudioEngine` (`ViciousCoordinator` hält sie als `let`). Nach diesem
  System-Reset sind Engine und abhängige Audio-Objekte laut Apple-Doku ungültig
  und müssen neu erzeugt werden — sonst kann die Wiedergabe dauerhaft stumm
  bleiben, obwohl Titel und Status restauriert aussehen. Umbau im Coordinator
  (Engine neu erzeugbar machen, dann SID/Subtune/Position/Status
  wiederherstellen); im Simulator nicht auslösbar, Abnahme nur auf echter
  Hardware (Prüfliste [`ios/GERAETETEST.md`](ios/GERAETETEST.md)).
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

Die Kampagne hat alle Bereiche des Repos abgedeckt (Stand in `.codeqa/coverage.json`).
Was sie bewusst **nicht** angefasst hat, steht hier — jeder Punkt ist geprüft und
belegt, keiner ist eine Vermutung.

1. **Mac-App auf den Core zurückbauen.** Sie ist das einzige Frontend, das den
   Bibliothekscode des Cores umgeht: `MainView.swift` hält auf 1306 Zeilen 25
   `@State`/`@AppStorage`-Felder und macht Ordner-Scan, Dateilesen und
   Favoritenpersistenz direkt in der View — Aufgaben, für die `MusicLibrary` im Core
   bereits eine getestete, plattformneutrale Lösung bietet, die die iPhone-App nutzt.
   Daraus folgt auch, dass die Suche auf dem Mac nur Titelnamen erfasst, auf dem
   iPhone zusätzlich Ordnernamen. Das ist ein eigener Auftrag, kein Aufräumen
   nebenbei; er bereitet zugleich die Backlog-Punkte 2 (HVSC-Browser) und 3
   (Mini-Player) für die Mac-App vor. Aufwand mittel, Nutzen hoch — ein
   Paradigmenwechsel ist dafür ausdrücklich **nicht** nötig, die Zielstruktur
   existiert bereits zweifach im Repo.

2. **`AVAudioEnginePCMSink.stop()` baut außerhalb des Locks ab.** `sourceNode` und der
   Zwischenpuffer werden ohne Sperre freigegeben, obwohl das Protokoll ausdrücklich
   damit rechnet, dass `stop()` aus mehreren Threads kommt (Tastaturschleife,
   Signal-Handler). Zwei gleichzeitige Aufrufe könnten denselben Puffer doppelt
   freigeben. In der Praxis ruft heute nur ein Thread `stop()`, und ein
   deterministischer Test für dieses Rennen ist nicht zu bauen — deshalb bewusst
   nicht blind geändert.

3. **`ALSAPCMSink` setzt seinen Zustand später als die Schwester-Senken.** Erst nach dem
   Öffnen des Geräts steht er auf `running`; ein fehlgeschlagener `start()` lässt den
   Sink damit startbar zurück und `waitUntilFinished()` meldet `.notStarted` statt
   `.failed`. Das CLI fängt einen fehlgeschlagenen `start()` sofort ab, die Abweichung
   ist also derzeit nicht beobachtbar. Nicht geändert, weil die Datei auf einem Mac
   weder übersetzbar noch ausführbar ist.

4. **`LibraryReset` bricht beim ersten nicht löschbaren Eintrag ab** und hinterlässt
   dann eine halb geleerte Bibliothek. Das ist eine bewusste fail-closed-Entscheidung
   (lieber abbrechen als fälschlich Erfolg melden); ob stattdessen weitergeräumt und
   am Ende berichtet werden soll, ist eine Produktentscheidung. Ein Symlink innerhalb
   der Bibliothek, der nach draußen zeigt, löst genau diesen Fall aus — die
   Pfadprüfung verweigert ihn korrekt, siehe `testContainmentResolvesSymlinks`.

5. **Zwei Strukturregeln der iPhone-Oberfläche hält nur ein Kommentar.** Die
   Mini-Player-Leiste muss per `safeAreaInset` am Tab-INHALT hängen (an der `TabView`
   verdeckt sie die Tab-Leiste und macht die App ab dem ersten Titel unbedienbar), und
   der Zeichentakt des Oszilloskops muss über `TimelineView(paused:)` an
   `isSceneActive` hängen. Beides ist korrekt umgesetzt, aber an SwiftUI-Strukturen
   ist kein sinnvoller Test aufzuhängen.

In Arbeit: Linux-Port (CLI + Audio-Backend) nach `tasks/2026-07-05-linux-port/plan.md`.

Permanent zurückgestellt, nur Kandidaten für schlimme Langeweile: Audiofingerprint/
WhatsSID (bräuchte serverseitige Fingerprint-DB über die HVSC), MUS/CGSC (eigenes Format
plus eigene Player-Routine für einen kleinen Sammlungszweig).

Gestrichen: ASID/Echt-SID-Hardware (2026-07-15) — nicht wieder aufnehmen.

Erledigte Release-/Quick-Look-/v1.5.0-Arbeit nicht zurückführen. Ebenfalls erledigt und
nicht zurückzuführen: die iOS-App selbst (früher Punkt 0) und der auf `.sid` gefilterte
Öffnen-Dialog (früher Punkt 6, gelöst über `SidFileType` im Core).
