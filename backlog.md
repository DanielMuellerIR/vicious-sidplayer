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
- `tasks/2026-07-26-ios-app/goal-prompt.md` ist ein Sessionauftrag an einen
  KI-Assistenten samt Subagenten-Steuerung und gehört nach den Projektregeln
  nicht in ein öffentliches Repo. Der interne Remote-Name ist entfernt; offen
  ist die Entscheidung, ob Auftrag und interner Arbeitsplan ganz herauskommen
  und nur dauerhaft relevante Architekturentscheidungen bleiben.
- Querformat funktioniert, ist aber nicht ausgereizt (Hochformat war die Vorgabe).
- App-Icon ist programmatisch erzeugt und zweckmäßig, kein gestaltetes Motiv.
- Offene Entscheidung: Die Sitzungswiederherstellung bereitet den Titel nur vor und
  spielt **nicht** von selbst los — bewusst anders als die Mac-App, damit die App beim
  Öffnen nicht ungefragt aus der Hosentasche dudelt. Umdrehen ist eine Zeile in
  `ios/ViciousSIDPlayer/Player/AppModel+Playback.swift`.
- Der Import liest jede Datei vollständig in den Speicher (nötig für MD5-Dedupe und
  für das koordinierte Lesen von File-Provider-Platzhaltern). Bei SID-Dateien
  unkritisch; erst relevant, falls je größere Formate dazukommen.

In Arbeit: Linux-Port (CLI + Audio-Backend) nach `tasks/2026-07-05-linux-port/plan.md`.

Permanent zurückgestellt, nur Kandidaten für schlimme Langeweile: Audiofingerprint/
WhatsSID (bräuchte serverseitige Fingerprint-DB über die HVSC), MUS/CGSC (eigenes Format
plus eigene Player-Routine für einen kleinen Sammlungszweig).

Gestrichen: ASID/Echt-SID-Hardware (2026-07-15) — nicht wieder aufnehmen.

Erledigte Release-/Quick-Look-/v1.5.0-Arbeit nicht zurückführen. Ebenfalls erledigt und
nicht zurückzuführen: die iOS-App selbst (früher Punkt 0) und der auf `.sid` gefilterte
Öffnen-Dialog (früher Punkt 6, gelöst über `SidFileType` im Core).
