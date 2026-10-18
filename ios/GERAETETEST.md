# Gerätetest der iPhone-App — Prüfliste für Daniel

Diese Punkte sind **im Simulator nicht belegbar**. Der Simulator hat keinen
echten Sperrbildschirm, keine AirPods, keinen eingehenden Anruf und keine
Kopfhörerbuchse. Wer hier „geprüft“ schreibt, ohne ein echtes iPhone in der Hand
gehabt zu haben, hat nichts geprüft.

Auch VoiceOver muss auf einem echten Gerät geprüft werden: [Apple unterstützt
VoiceOver nicht im iOS-Simulator](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app).

## Kurztest

- 10–20 Minuten gesperrt spielen: keine Aussetzer, Auto-Next; Wärme/Akku beobachten.
- Sperrbildschirm und AirPods: Play/Pause, Titelsprung und Positionssprung.
- Kopfhörer trennen: pausiert, kein Ton aus dem Lautsprecher.
- Anruf/Siri: pausiert; ein ausdrückliches „Pause“ verhindert späteres Autostart.
- Ordner importieren, App neu starten; VoiceOver-Controls kurz prüfen.

Die vollständige Abnahme unten bleibt einzeln offen, bis Ergebnisse vorliegen.

## Vorbereitung

Für den direkten Xcode-Lauf `ios/ViciousSIDPlayer.xcodeproj` öffnen, das iPhone
anstecken und als Ziel wählen. Unter „Signing & Capabilities“ das passende
Apple-Team prüfen, dann die App mit dem Play-Knopf starten. Team und Bundle-ID
stehen im App-Target; bei einem fremden Clone müssen diese Werte dort angepasst
werden. Beim ersten Mal kann iOS nach Vertrauen für das Entwicklerzertifikat
fragen: Einstellungen → Allgemein → VPN & Geräteverwaltung.

Alternativ liest der Skript-Build `ios/.env`. Eine vorhandene Datei erhalten;
nur falls sie fehlt, `ios/env.example` dorthin kopieren. `DEVELOPMENT_TEAM`
eintragen und dann bauen:

```bash
bash ios/scripts/apply-env.sh
bash ios/scripts/build-device.sh
```

Das fertige Bundle lässt sich über Xcode → Window → Devices and Simulators
einspielen. Die `.env`-Werte werden beim Skript-Build als Argumente übergeben;
sie überschreiben **nicht** die Target-Werte beim Start aus der Xcode-GUI.
Die Reihenfolge steht in [`Config/Signing.xcconfig`](Config/Signing.xcconfig).

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
- [ ] Anruf beenden. Gibt iOS das Fortsetzen frei (`.shouldResume`), setzt
      die Musik von selbst fort. Andernfalls muss bewusstes Play funktionieren;
      die App darf die Unterbrechungsentscheidung von iOS nicht übergehen.
- [ ] Anruf annehmen und wieder auflegen: gleiches Verhalten, kein doppeltes
      Starten, keine zwei gleichzeitig laufenden Wiedergaben.
- [ ] Dasselbe mit einer Sprachnachricht oder Siri.
- [ ] Während Siri unterbricht ausdrücklich „Pause“ anfordern. Danach bleibt
      die Musik pausiert, auch wenn iOS automatisches Fortsetzen erlauben würde.
- [ ] Während einer Unterbrechung einen anderen Titel in der Bibliothek nur
      vorbereiten. Nach deren Ende bleibt er gestoppt, bis bewusst Play folgt.

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

### 9. Neustart des System-Audiodienstes

Selten, aber real: iOS startet seinen Audiodienst neu (`mediaServicesWereReset`),
etwa nach einem Absturz im Audiosystem. Auslösen lässt sich das nicht auf Knopfdruck
— wenn es passiert, ist dies der Prüfpunkt:

- [ ] Nach dem Zurückkommen spielt derselbe Titel an derselben Stelle weiter
      (höchstens eine Lücke), statt dauerhaft stumm zu bleiben. Seit v1.9.16 legt
      die App dabei die `AVAudioEngine` neu an; vorher benutzte sie die tote weiter.

### 10. VoiceOver und externe Tastatur

- [ ] Mit VoiceOver zwischen Bibliothek, Wiedergabe und Einstellungen wechseln.
      Titel, Suchhilfe, Hörfolgen, Verlauf und Sammlungsprüfung sind verständlich
      benannt und erreichbar; ein geschlossener Dialog verliert den Fokus nicht.
- [ ] Subtunes, Position, Mute, Solo und Filter bedienen. Der angesagte Zustand
      entspricht der Auswahl; die Oszilloskopanzeige erzeugt keinen ständigen
      Strom von Ansagen.
- [ ] Sammlung importieren/exportieren und Audio-Export öffnen, konfigurieren und
      schließen. Fehlermeldungen werden vorgelesen und lassen sich verlassen.
- [ ] Mit einer externen Tastatur und aktivierter Tastatursteuerung dieselben
      Hauptabläufe ohne Berührung bedienen, einschließlich Texteingabe und Dialogen.
- [ ] Hoch-/Querformat und maximale Bedienungshilfen-Schrift auf dem Gerät prüfen.
      Vollständige Metadaten und alle Controls bleiben durch Scrollen erreichbar.

## Was tun, wenn etwas nicht stimmt

Fehlerbild notieren (welcher Punkt, was passiert stattdessen) und dazu, falls
greifbar, das Konsolenprotokoll:

```bash
xcrun devicectl device info details
```

bzw. in Xcode über Window → Devices and Simulators → View Device Logs.
