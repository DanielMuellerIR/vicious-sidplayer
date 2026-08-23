Vicious SID Player 1.9.21 macht die macOS-App tauglich für eine echte Sammlung.
An 50.001 Dateien geprüft — der Größe einer vollständigen High Voltage SID
Collection — stürzte die Vorversion beim Start ab. Jetzt startet sie im
Sekundenbruchteil und bleibt stehen. Dazu kommen die Ordneransicht, die die
iPhone-App schon hatte, die Titel-Anmerkungen der HVSC (STIL), ein Mini-Player,
eine Fernsteuerung über ein URL-Schema und etwa die Hälfte der bisherigen
Prozessorlast. Die iPhone-App bekommt dieselben Anmerkungen und eine Korrektur,
die sie sonst nach einem Neustart des System-Audiodienstes verstummen ließe.

## Große Sammlungen unter macOS

- **Kein Absturz mehr bei großer Bibliothek.** Zwei unabhängige Ursachen, beide
  durch Messung gefunden: Der Titelwähler „TUNE:" war ein Auswahlmenü über die
  ganze Playlist — macOS baut daraus ein Menü mit einem Eintrag je Titel, bei
  50.001 Titeln 5,2 GB Arbeitsspeicher — und die Titelliste legte jede Zeile
  sofort an, was den Ansichtsaufbau von SwiftUI sprengte. Der Wähler zeigt jetzt
  einen begrenzten Ausschnitt rund um den laufenden Titel, und die Liste baut nur
  die Zeilen, die sie zeigt. Ergebnis: 340 MB statt Absturz.
- **Der Bibliotheks-Scan läuft im Hintergrund.** Die Liste steht sofort aus dem
  gespeicherten Index, die Wiedergabe beginnt vor dem Ende des Scans; das
  Ergebnis wird danach nachgezogen, und der laufende Titel wird über seine
  Identität wiedergefunden statt über seine Position in der Liste.
- **Ordneransicht.** Die Seitenleiste zeigt die Sammlung wahlweise als flache
  Titelliste oder als aufklappbaren Ordnerbaum mit Titelzahl je Ordner,
  umschaltbar im Kopf der Playlist. Alles auf- und zuklappen inbegriffen; der
  aufgeklappte Zustand überlebt einen Neustart. Suche und Favoritenfilter zeigen
  weiterhin die flache Trefferliste.
- Zugeklappte Ordner kosten nichts: Bei 50.001 Titeln zeichnet der Baum 100
  Zeilen statt 50.100.

## Titel-Anmerkungen der HVSC (STIL)

- Die App liest die `STIL.txt` der High Voltage SID Collection und zeigt, was im
  SID-Dateikopf keinen Platz hat: welche Vorlage ein Stück covert, wer die
  Melodie geschrieben hat, Anmerkungen zu einzelnen Subtunes — geordnet vom
  Subtune über die Datei zum Ordner.
- Unter macOS wird die Datei automatisch unter `DOCUMENTS/` im oder über dem
  Autoplay-Ordner gefunden oder in den Einstellungen ausgewählt. Unter iOS wird
  sie einmal importiert, wie die Songlängen-Datenbank.
- Zugeordnet wird über den Pfad unterhalb der HVSC-Wurzel; bei Sammlungen, die
  aus der HVSC herauskopiert wurden, über ein eindeutiges Pfadende. Mehrdeutige
  Treffer werden verworfen — eine falsche Anmerkung ist schlechter als keine. Die
  Datenbank selbst liegt nicht bei, sie gehört dem HVSC-Projekt.

## Mini-Player und Fernsteuerung

- **Mini-Player** (⌘⌥M): Das Fenster schrumpft auf eine schmale Leiste mit
  App-Symbol, Titel, Komponist, Spielzeit und Transportsteuerung und nimmt mit
  demselben Kürzel wieder seine vorherige Größe an.
- **Fernsteuerung über ein URL-Schema**, für Skripte und Kurzbefehle:
  `open "vicioussid://next"`, `playpause`, `stop`, `previous`,
  `seek?seconds=90`, `subtune?index=1`, `track?path=Hubbard_Rob/Commando.sid`.
  Bewusst kein HTTP-Server: Ein URL-Schema wird lokal zugestellt und öffnet
  keinen Port. Weil es jede Webseite auslösen kann, gibt es ausschließlich
  Wiedergabesteuerung — Titelpfade müssen unterhalb des Autoplay-Ordners liegen
  und auf `.sid` enden, alles andere wird abgewiesen, bevor es die App erreicht.

## Geschwindigkeit

- Die Prozessorlast im laufenden Betrieb ist von 48 % auf 31 % eines Kerns
  gefallen. Die Ursache war weder die Emulation noch das Zeichnen: Die
  Anzeigewerte je Stimme (Hüllkurve, Frequenz, Gate, Wellenform, Pulsbreite)
  wurden 50-mal je Sekunde veröffentlicht und warfen dabei jedes Mal die
  komplette Oberfläche neu auf. Die Oszilloskope holen sie sich jetzt beim
  Zeichnen, und die Spielzeit wird nur weitergegeben, wenn sie sich um mindestens
  ein Zehntel geändert hat.

## Korrekturen seit 1.9.0

- **Songlängen mit Windows-Zeilenenden wurden vollständig ignoriert.** Die HVSC
  liefert `Songlengths.md5` mit CRLF aus, und in Swift ist `"\r\n"` ein einzelnes
  Zeichen — beim Trennen an `"\n"` entstand eine einzige Riesenzeile und damit
  kein einziger Eintrag.
- Eine präparierte Datenbank mit unendlicher oder absurder Dauer erreicht weder
  Positionsregler noch automatisches Weiterschalten.
- Eine fehlerhafte SID-Datei mit absurder Subtune-Zahl bringt den Parser nicht
  mehr zum Absturz.
- Die Puls-Wellenform der nativen Engine stimmte nur zufällig mit der
  HTML5-Engine überein; beide folgen jetzt derselben Definition.
- Quick Look konnte bei einer Datei abstürzen, deren Spielzeit sich nicht
  berechnen ließ.
- Playlist, Duplikatprüfung, Suche, Favoriten und die Rechnung für den nächsten
  Titel sind aus der macOS-Ansicht in den gemeinsamen Kern gewandert, ebenso die
  Songlängen-Auflösung — beide Apps folgen jetzt derselben geprüften Regel statt
  zwei ähnlichen.
- Die Titel-Identität ist unter macOS der Pfad relativ zum Autoplay-Ordner. Zwei
  gleichnamige Dateien in verschiedenen Ordnern sind zwei Titel; vorher blieben in
  einer nach Komponisten sortierten Sammlung ganze Ordner unerreichbar.
- **iOS:** Nach einem Neustart des System-Audiodienstes baute die App den Titel
  zwar neu auf, benutzte aber weiter die ungültig gewordene `AVAudioEngine` — sie
  wäre dauerhaft stumm geblieben, während Titel und Status richtig aussahen. Die
  Engine wird jetzt neu angelegt.
- **Linux-CLI:** Die Pfeiltasten schalten den Subtune. Escape-Sequenzen werden
  zusammengesetzt, statt als einzelne Buchstaben durchzufallen.
- Der Trenner der Seitenleiste zappelt nicht mehr, und die Kopfzeile behält ihre
  Beschriftungen auch bei minimaler Fensterbreite.

## Prüfung

- 192 Tests in der Swift-Suite, darunter der neue Ordnerbaum, der STIL-Parser,
  die Prüfung der Fernsteuerbefehle, der Tastendecoder des Terminals und der
  erste Test des Audio-Koordinators überhaupt.
- Die macOS-App wurde an einer synthetischen Sammlung aus 50.001 Dateien
  gemessen: Speicher, Prozessorlast und Scandauer, dazu Fensteraufnahmen von
  Ordnerbaum, Anmerkungen und Mini-Player. Die Sammlung entstand lokal und wurde
  danach gelöscht.
- Die iPhone-App baut ohne Warnungen aus eigenem Code, ihre Simulator-Suite ist
  grün.
- Hintergrundwiedergabe, Sperrbildschirm, AirPods, Anrufe, Kopfhörerabziehen und
  ein Media-Services-Reset sind **im Simulator nicht belegbar** und werden
  deshalb nicht als geprüft ausgegeben. Die Prüfliste für echte Hardware steht in
  `ios/GERAETETEST.md`.
- Die Titel-Anmerkungen wurden gegen eine nachgebaute `STIL.txt` im
  dokumentierten Format geprüft, nicht gegen eine echte Datei der HVSC — hier lag
  keine vor.
- Es liegen keine SID-Musikdateien bei. Der HTML5-Player entsteht lokal aus den
  Quellen des Repositorys mit `python3 build.py`.

Voraussetzung: macOS 13 oder neuer für die native App, iOS 17 oder neuer und
Xcode 16 oder neuer für die iPhone-App. Die Linux-CLI braucht die
Laufzeitbibliotheken von ALSA und D-Bus.
