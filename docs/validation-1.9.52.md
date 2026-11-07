# Prüfstand 1.9.52

Stand: 2026-11-07. Eigenständige Linux-Desktop-App mit Qt Widgets und dem
bestehenden Swift-Core; der bisherige Linux-CLI-Player bleibt separat.

## Umsetzung und Referenz

Die macOS-App ist die Vorlage für Gruppen, Abstände, Farben, Beschriftungen,
Seitenleiste und Oszilloskop. Heller und dunkler Modus, Mini-Player,
Register-/Klavieransicht, Bibliothek, Suche, Favoriten, Hörlisten, Hörfolge,
Verlauf, Marken, Notizen, Sammlungsübertragung und Wiedergabeeinstellungen
sind vorhanden. Die Audio-Engine verwendet die gemeinsamen Parser-, DSP-,
Songlängen- und Abschlussregeln; MPRIS bindet die Linux-Mediensteuerung an.

SwiftUI/AppKit stehen unter Linux nicht zur Verfügung. Qt ersetzt diese
Oberfläche; Fensterrahmen, Menüleiste, Dateidialoge, freie Ersatzschriften,
eigene Vektorzeichen und Schriftrasterung weichen plattformbedingt ab.
Layout und Darstellung wurden visuell gegen gerenderte Mac-Referenzen
verglichen; eine bitidentische Pixelwiedergabe wird nicht behauptet.
Linux exportiert WAV. Die Apple-Encoder für M4A/FLAC und Sparkle sind nicht
portiert. Updates erfolgen über den Linux-Installer.

Die Installation enthält eine statisch eingebundene Swift-Laufzeit und eine
isolierte Qt/PySide-Laufzeit. System-Python und Musikdateien bleiben getrennt.
Versionierte App-Verzeichnisse und ein atomarer Versionszeiger erlauben das
Zurückschalten; gescheiterte Aktivierung stellt die vorige Installation wieder
her. Die Anleitung steht in [linux/README.md](../linux/README.md).

## Ausgeführte Prüfungen

- macOS-Swift-Suite: 413 Tests, davon 4 übersprungen, keine Fehler.
- Linux-Swift-Suite auf Linux Mint 22.2, x86-64, Swift 6.0.3:
  370 Tests, davon 5 übersprungen, keine Fehler. Dateifavoriten einschließlich
  Fremdänderungs- und Beschädigungsschutz auf beiden Plattformen geprüft.
- iOS-Simulator: generischer Core-/App-Build erfolgreich; 80 Tests bestanden.
  Der bekannte AppIntents-Metadatenhinweis bleibt, keine Warnung im eigenen Code.
- Linux-GUI unter isoliertem X11/Xvfb und D-Bus: echte Klicks für Transport,
  Modell, Takt, Lautstärke, Subtunes, Favoriten, Suche, Drei-Chip-Dateien,
  Mute/Solo, Hörlisten, Hörfolge, Marken, Notizen und Mini-Player bestanden.
  Helle/dunkle, schmale, Register-, Klavier- und Dialogansichten visuell geprüft.
- Desktop-Regressionen: MPRIS einschließlich 64-Bit-Position, Auto-Next über
  drei Subtunes, A/B unter Modell-/Mute-/Filterwechseln, gestoppter Seek,
  WAV-Header und Samples, Sammlungsexport/Reimport, Ordner-Drop,
  Wiederherstellung bei fehlendem Index und Abbruch eines Bibliotheksscans
  bestanden. Tatsächliche ALSA/PipeWire-Ausgabe an einer isolierten Testsenke
  als nichtstummes Stereo-PCM aufgezeichnet; keine Lautsprecherabnahme.
- Bibliothek mit 50.001 synthetischen Dateien: vollständiger Aufbau samt
  Metadatenindex in 23,65 Sekunden; GUI 303.628 KiB und Engine 375.368 KiB RSS.
  Suche, letzte Titelauswahl, Ordnerbaum und begrenztes Titelmenü bestanden.
- Fünf Installer-Tests bestanden: erste Fehlaktivierung, Upgrade-Rollback,
  fremder Starter, idempotente Installation und Auflösung des installierten
  Symlink-Starters. Installierte App zusätzlich über ihren echten Starter,
  Datei-URI, Einzelinstanz, URL-Schema, Dateidialog und Beenden geprüft.
- Installation auf einem zweiten Linux-System (CachyOS/KDE, Python 3.14.9)
  erfolgreich: Desktop-Datei validiert, installierter Starter aufgerufen,
  Engine und Oberfläche ohne sichtbares Fenster gerendert, keine Laufzeitfehler.
- Fleet-Regelprüfung und Diff-Whitespace-Prüfung bestanden.

Alle Musikfixtures wurden synthetisch erzeugt. Keine SID-Musik wird mitgeliefert.

## Grenzen

Der zweite Linux-Desktop war bei der Endprüfung gesperrt; dort wurde ausschließlich
mit dem Qt-Offscreen-Plugin geprüft. Eine interaktive Wayland-Abnahme, reale
Medientasten und physische Audioausgabe sind dadurch nicht belegt. Die vollständigen
Interaktionstests liefen auf dem ersten Linux-System unter X11.
Die offenen iPhone-Gerätefälle bleiben unverändert in
[ios/GERAETETEST.md](../ios/GERAETETEST.md).
