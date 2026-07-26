# Gerätetest der iPhone-App — Prüfliste für Daniel

Diese Punkte sind **im Simulator nicht belegbar**. Der Simulator hat keinen
echten Sperrbildschirm, keine AirPods, keinen eingehenden Anruf und keine
Kopfhörerbuchse. Wer hier „geprüft“ schreibt, ohne ein echtes iPhone in der Hand
gehabt zu haben, hat nichts geprüft.

## Vorbereitung

```bash
cp ios/env.example ios/.env
```

Dann `DEVELOPMENT_TEAM` in `ios/.env` eintragen (Apple-Developer-Team-ID,
zehn Zeichen) und die Konfiguration erzeugen:

```bash
bash ios/scripts/apply-env.sh
```

App für das Gerät bauen:

```bash
bash ios/scripts/build-device.sh
```

Danach das iPhone anstecken und die App aus Xcode heraus starten (Play-Knopf mit
dem Gerät als Ziel). Beim ersten Mal fragt iOS nach Vertrauen für das
Entwicklerzertifikat: Einstellungen → Allgemein → VPN & Geräteverwaltung.

Zum Testen ein paar `.sid`-Dateien in die App bekommen — beide Wege einmal gehen:

- **Weg A:** in der App auf „Importieren“ und einen Ordner wählen.
- **Weg B:** iPhone am Kabel → Finder → Gerät → Reiter „Dateien“ → Vicious SID
  aufklappen → ganze Ordner per Drag & Drop hineinziehen.

## Prüfliste

Jeder Punkt ist einzeln zu quittieren. Ein „läuft schon irgendwie“ zählt nicht.

### 1. Wiedergabe bei gesperrtem Display

- [ ] Titel starten, Sperrknopf drücken. **Die Musik läuft ohne Aussetzer weiter.**
- [ ] Zehn Minuten am Stück gesperrt laufen lassen. Kein Knacksen, keine
      Aussetzer, kein Abbruch. (Der Realtime-Thread ist auf iOS strenger
      getaktet als auf dem Mac — ein Fehler, der auf dem Mac unhörbar bleibt,
      knackst hier.)
- [ ] Auto-Next schaltet auch bei gesperrtem Display zum nächsten Titel weiter.

### 2. Steuerung über den Sperrbildschirm

- [ ] Sperrbildschirm zeigt Titel, Autor und ein Bild.
- [ ] Play/Pause funktioniert.
- [ ] Weiter und Zurück funktionieren und wechseln den Titel.
- [ ] Die Position lässt sich über den Sperrbildschirm-Regler verschieben.
- [ ] Die verstrichene Zeit läuft mit und springt nicht.
- [ ] Dasselbe im Kontrollzentrum.

### 3. AirPods und Bluetooth

- [ ] Wiedergabe kommt auf den AirPods an.
- [ ] Einmal tippen (bzw. Stiel drücken) pausiert und setzt fort.
- [ ] Doppelt tippen springt zum nächsten Titel.
- [ ] AirPods aus dem Ohr nehmen und wieder einsetzen: kein Absturz, kein
      Dauerstummschalten.

### 4. Eingehender Anruf

- [ ] Während der Wiedergabe anrufen lassen. **Die Musik pausiert.**
- [ ] Anruf beenden. **Die Musik setzt von selbst fort** (das ist der
      `.shouldResume`-Fall der Unterbrechungsbehandlung).
- [ ] Anruf annehmen und wieder auflegen: gleiches Verhalten, kein doppeltes
      Starten, keine zwei gleichzeitig laufenden Wiedergaben.
- [ ] Dasselbe mit einer Sprachnachricht oder Siri.

### 5. Kopfhörer abziehen

- [ ] Kabelkopfhörer (oder AirPods trennen) während der Wiedergabe abziehen.
      **Die Musik pausiert und spielt NICHT laut über den Lautsprecher weiter.**
      Das ist der klassische Peinlichkeitsfehler und der Grund für die
      Behandlung von `.oldDeviceUnavailable`.

### 6. Batterie und Wärme

- [ ] 20 Minuten mit gesperrtem Display spielen. Das Gerät wird nicht spürbar
      warm, der Batteriestand fällt nicht auffällig schnell.
- [ ] Mit offenem Bildschirm auf „Now Playing“ läuft das Oszilloskop flüssig;
      beim Sperren steht es still (nur so ist der Batterieverbrauch in Ordnung).

### 7. Import auf echter Hardware

- [ ] Ordner-Import aus Nextcloud oder iCloud Drive: Dateien kommen **mit
      Inhalt** an, nicht als leere Platzhalter. (File-Provider liefern Einträge
      unter Umständen erst nach dem Herunterladen — genau dafür gibt es die
      Behandlung im Importer.)
- [ ] Import eines grossen, verschachtelten Ordners: Fortschritt läuft,
      Abbrechen funktioniert, die Ordnerstruktur bleibt erhalten.
- [ ] Über die Finder-Dateifreigabe einen Ordner hinzufügen, dann die App in den
      Vordergrund holen: **die neuen Titel tauchen ohne Neustart auf.**
- [ ] Über den Finder eine Datei löschen: sie verschwindet aus der Bibliothek,
      ohne dass die App abstürzt.

### 8. Zurücksetzen

- [ ] „Bibliothek zurücksetzen“ (zweistufig bestätigt) leert die Bibliothek.
- [ ] Danach funktioniert ein erneuter Import.
- [ ] Mit „Favoriten behalten“ bleiben die Favoriten erhalten, ohne sie sind sie weg.

## Was tun, wenn etwas nicht stimmt

Fehlerbild notieren (welcher Punkt, was passiert stattdessen) und dazu, falls
greifbar, das Konsolenprotokoll:

```bash
xcrun devicectl device info details
```

bzw. in Xcode über Window → Devices and Simulators → View Device Logs.
