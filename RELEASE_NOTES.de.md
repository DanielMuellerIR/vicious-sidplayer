Vicious SID Player 1.9.0 bringt eine native iPhone-App, die sich den vorhandenen
Emulationskern teilt, und verlagert die Musikbibliothek — Index, rekursiver
Import, Zurücksetzen — als plattformneutrale, getestete Logik in genau diesen
Kern. Erste Nutzerin ist die iPhone-App; die macOS-App läuft weiterhin mit ihrer
bisherigen Playlist-Logik und zieht erst später auf die gemeinsame Bibliothek um.
Die notarisierte macOS-App samt Quick-Look-Erweiterung bleibt im DMG enthalten;
am Verhalten unter macOS ändert sich nichts.

## iOS-App (iPhone)

- Eine native SwiftUI-App unter `ios/`, aus den Quellen gebaut und mit dem
  eigenen Apple-Developer-Team per Sideload installiert. Keine privaten APIs, ein
  Privacy-Manifest und saubere UTIs — der Weg in den App Store bleibt offen.
- Hintergrundwiedergabe mit Steuerung über Sperrbildschirm, Kontrollzentrum und
  AirPods via `MPRemoteCommandCenter` und `MPNowPlayingInfoCenter`.
- Behandlung der Audio-Sitzung für genau die Fälle, die eine Musik-App richtig
  machen muss: Ein eingehender Anruf pausiert und setzt nur dann fort, wenn das
  System es freigibt; abgezogene Kopfhörer pausieren, statt auf den Lautsprecher
  umzuschalten; ein Neustart der Media Services baut die Engine neu auf.
- Rekursiver Ordner-Import, der die Unterordnerstruktur erhält, inhaltsgleiche
  Dateien überspringt, Fortschritt meldet, sich abbrechen lässt und Fehler pro
  Datei sammelt, statt den ganzen Lauf abzubrechen. Platzhalter von
  File-Providern wie iCloud Drive oder Nextcloud werden vor dem Kopieren
  materialisiert.
- Finder-Dateifreigabe: iPhone ans Kabel und ganze Ordner in die App ziehen. Von
  außen hinzugefügte oder gelöschte Dateien werden selbstständig abgeglichen.
- Bibliothek zurücksetzen, zweistufig bestätigt, mit Schalter für das Behalten
  der Favoriten.
- Oszilloskop, Subtunes, Voice-Mute, Filter-Bypass, SID-Modellwahl, Songlängen,
  Suche, Favoriten, Shuffle, Session-Restore, Theme und WAV-Export.
- Oszilloskop und alle UI-Timer laufen nur im Vordergrund; im Hintergrund spielt
  das Audio weiter und die Visualisierung steht still.
- Deutsch und Englisch, der Systemsprache folgend.

## Gemeinsamer Kern

- Die Musikbibliothek ist nach `ViciousSIDPlayerCore` gewandert: Index,
  rekursiver Scan mit Abgleich, Importer und Zurücksetzen sind plattformneutral
  und durch Tests abgedeckt.
- Die Identität eines Titels ist ein Pfad relativ zur Bibliothekswurzel statt
  einer absoluten URL — dadurch überleben Favoriten und Session-Restore eine
  Neuinstallation.
- Das Zurücksetzen kann ausschließlich unterhalb der Bibliothekswurzel löschen;
  die Prüfung vergleicht Pfadbestandteile, keine Zeichenketten-Präfixe.
- `SidFileType` hält die Endung `.sid` und den UTI `com.viben.sid-tune` an einer
  Stelle. Der Öffnen-Dialog unter macOS filtert jetzt darüber, statt jede
  beliebige Datei anzubieten.
- Der Kern baut zusätzlich für iOS; zwei dort nicht vorhandene
  Foundation-Aufrufe wurden ersetzt, ohne das Verhalten unter macOS zu ändern.

## Prüfung

- Die Swift-Suite deckt die neue Bibliothekslogik ab, einschließlich
  strukturerhaltendem Import, Deduplikation, Abbruch, Abgleich gegen Änderungen
  von außen und der Pfadprüfung beim Zurücksetzen.
- Eine Simulator-Suite deckt das App-Modell, den Info.plist-Vertrag, das
  Privacy-Manifest und einen vollständigen Import-Durchlauf gegen einen
  synthetischen, verschachtelten Testbaum ab.
- Hintergrundwiedergabe, Sperrbildschirm-Steuerung, AirPods, eingehende Anrufe
  und das Abziehen der Kopfhörer sind **im Simulator nicht belegbar** und werden
  deshalb nicht als geprüft ausgegeben. Die Prüfliste für echte Hardware steht in
  `ios/GERAETETEST.md`.
- Es werden keine SID-Musikdateien mitgeliefert. Der HTML5-Player wird lokal mit
  `python3 build.py` aus den Repo-Quellen erzeugt.

Voraussetzungen: macOS 13 oder neuer für die native App, iOS 17 oder neuer und
Xcode 16 oder neuer für die iPhone-App. Das Linux-CLI benötigt die
Laufzeitbibliotheken von ALSA und D-Bus.
