# Goal-Prompt — iOS-App für Vicious SID Player

Dieser Text ist zum Einfügen in eine frische Session im Repo-Wurzelverzeichnis
gedacht. Er ist absichtlich selbsttragend.

---

Baue im Repo `vicious_sidplayer` eine native iOS-App für iPhone, zusätzlich zur
bestehenden macOS-App. Der vollständige Plan steht in
`tasks/2026-07-26-ios-app/plan.md` — lies ihn zuerst, zusammen mit `CLAUDE.md`
(bzw. `AGENTS.md`). Der Plan ist verbindlich; wo er schweigt, gilt „wie in der
Mac-App“.

**Ziel in einem Satz:** eine iPhone-App, die SID-Musik spielt, im gesperrten
Zustand weiterläuft und dort bedienbar ist, und in die man ganze Ordner voller
`.sid`-Dateien auf einen Rutsch hineinbekommt.

## Bereits entschieden — nicht neu aufrollen

- Sideload mit eigenem Developer-Team; App Store bleibt offen (keine privaten
  APIs, Privacy-Manifest, saubere UTIs).
- Eingechecktes `.xcodeproj`, aber mit `PBXFileSystemSynchronizedRootGroup`
  (`objectVersion 77`), damit neue Swift-Dateien ohne pbxproj-Edit erfasst werden.
- Import ausschließlich über (A) rekursiven Ordner-Import in der App und
  (B) Finder-Dateifreigabe. Kein CLI-Push-Skript, kein Wi-Fi-Server.
- iOS-Minimum 17.0. Bundle-ID `com.viben.ViciousSIDPlayer`.
- Layout unter `ios/`, Skripte unter `ios/scripts/`.

## Harte Grenzen

- **Keine Musikdateien ins Repo**, keine Songlength-Datenbank, keine
  Export-Artefakte. Tests nutzen synthetisch erzeugte Fixtures.
- **Keine privaten Pfade** in Code, Doku, Tests, Screenshots oder
  Commit-Nachrichten. Import-Quellen sind reine Laufzeit-Auswahl.
- **Team-ID** nur über gitignorierte `ios/.env`, dazu eine `.env.example`.
- **jsSID- und WTFPL-Hinweise** erscheinen auch in der iOS-App (Über-Screen).
- **Kein Push zu `github`, kein Release, keine Notarisierung.** Commits gehen
  ausschließlich zum privaten Fleet-Remote, und nur mit aufgabenbezogenen
  Pfaden im Index. Kein `git add .`, kein Reset, kein Clean.
- Fremdes WIP und andere Worktrees bleiben unangetastet.

## Reihenfolge

Arbeite die Phasen 0 bis 6 aus dem Plan in dieser Reihenfolge ab.

**Phase 0 ist blockierend:** erweitere `platforms:` in `Package.swift` um
`.iOS(.v17)` und beweise, dass `ViciousSIDPlayerCore` für `iphonesimulator`
baut. Das Manifest enthält macOS-only-Targets hinter `#if os(macOS)`. Falls das
nicht auf Anhieb geht, löse es, bevor irgendetwas anderes entsteht, und
dokumentiere die Lösung im Plan. Erst danach weiterbauen.

Melde dich bei mir, bevor du Phase 5 (Feature-Parität) beginnst, mit einem
kurzen Stand: was läuft im Simulator, was ist offen. Ansonsten arbeite durch.

## Subagenten

Du darfst Opus-Subagenten parallel einsetzen — das ist hiermit ausdrücklich
beauftragt. Sinnvolle Aufteilung, jeweils ein Schreiber pro Dateibereich:

- **Core/Bibliothek:** `Sources/ViciousSIDPlayerCore/Library/` plus zugehörige
  Tests in `Tests/`.
- **Audio/Now Playing:** `ios/ViciousSIDPlayer/Player/`.
- **UI:** `ios/ViciousSIDPlayer/UI/` und `ios/ViciousSIDPlayer/Library/`.
- **Build/Skripte/Doku:** `ios/scripts/`, `.gitignore`, READMEs, VERSION.

Das `.xcodeproj` und `Package.swift` sind serielle Engpässe — dort schreibt
immer nur einer, nie parallel. Subagenten committen nicht; das machst du zentral.

## Erfolgskriterien

1. `swift test` vollständig grün, macOS-Verhalten unverändert; `bash
   build_app.sh` baut weiterhin.
2. `ios/scripts/build-simulator.sh` und `ios/scripts/run-tests.sh` laufen
   headless durch.
3. Im Simulator nachweisbar: Ordner-Import eines synthetischen, verschachtelten
   Testbaums erhält die Struktur, dedupliziert, ist abbrechbar; „Bibliothek
   zurücksetzen“ leert sauber; danach funktioniert ein erneuter Import.
4. Wiedergabe, Subtunes, Oszilloskop, Voice-Mute, Filter-Bypass, SID-Modell,
   Songlängen, Suche, Favoriten, Shuffle, Session-Restore, Theme und WAV-Export
   sind vorhanden und im Simulator bedienbar.
5. Visualisierung steht bei inaktiver Szene still, Audio läuft weiter.
6. Der getrackte Diff enthält keine Musikdateien, keine privaten Pfade, keine
   Team-ID.
7. `VERSION`, `README.md`, `README.de.md`, `RELEASE_NOTES*`, `AGENTS.md` und
   `backlog.md` sind auf dem neuen Stand; die beiden READMEs bleiben inhaltlich
   synchron.

**Was du nicht abnehmen kannst:** Hintergrundwiedergabe und Sperrbildschirm-
Steuerung sind nur auf echtem Gerät belegbar. Bereite `ios/scripts/build-device.sh`
vor, schreibe mir eine kurze Prüfliste (Sperrbildschirm-Steuerung, AirPods,
eingehender Anruf, Kopfhörer abziehen) und übergib diesen Test an mich. Behaupte
niemals, das sei verifiziert, wenn nur der Simulator lief.

## Berichten

Am Ende: was gebaut wurde, welche Gates mit welchem Ergebnis liefen, was bewusst
offen blieb und warum, und was ich am Gerät prüfen muss. Fehlgeschlagene Tests
nennst du mit Ausgabe, nicht als Randnotiz.
