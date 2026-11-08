# Prüfstand 1.9.55

Stand: 2026-11-08. Signierter GitHub-Updateweg für die native Linux-App.
Die Änderungen aus 1.9.53 und [1.9.54](validation-1.9.54.md) sind enthalten.

## Verhalten und Vertrauensgrenze

- Die aktive Benutzerinstallation prüft beim Start und bei dauerhaft geöffneter
  App höchstens einmal pro Tag.
  Automatische Prüfungen sind in den Einstellungen abschaltbar. Der Menüpunkt
  **Hilfe → Nach Updates suchen …** prüft unabhängig davon sofort.
- Erst **Herunterladen und installieren** bestätigt den Download. Wiedergabe und
  Sitzung laufen weiter; die neue Fassung startet erst beim nächsten App-Start.
- Eine kleine Ed25519-signierte Beschreibung bindet Produkt, Architektur, Version,
  feste GitHub-Paketadresse, Größe und SHA256 des Archivs. Der öffentliche Schlüssel
  ist derselbe projektspezifische Vertrauensanker wie beim Mac-Updater.
- GitHub Actions signiert das Linux-Manifest über `sign_update` mit dem vorhandenen
  Release-Secret. Der private Schlüssel wird nur über stdin übergeben. Eine
  unabhängige Python-Prüfung gegen den eingecheckten öffentlichen Schlüssel liegt
  vor dem gemeinsamen Pages-Deployment mit dem Mac-Appcast.
- Der Linux-Client verwendet die gebündelte `cryptography`-Bibliothek für Ed25519.
  Archivpfade, Dateitypen und Größen sind begrenzt. Paketversion und öffentlicher
  Schlüssel müssen passen. Vor dem Austausch startet die neue Audio-Engine mit
  leerer Testbibliothek. Nur der bereits installierte lokale Installer aktiviert
  das verifizierte Paket. Die alte Fassung bleibt erhalten.
- Quellbuilds und inaktive alte Installationen dürfen keinen anderen aktuellen
  Stand ersetzen. Eine Dateisperre verhindert parallele Updateinstallationen;
  vor der Installation werden Version und Prüfsumme des Angebots erneut geprüft.

## Ausgeführt

- Sechs Update-Testfälle auf macOS und Linux bestanden: gültige/veränderte/fremde
  Signatur, Versionsvergleich, falsches Produkt/Architektur/Quelle/Metadaten,
  Traversal/Symlink/Hardlink/FIFO und doppelte Archivpfade, Installationsbindung,
  parallele Sperre, geändertes Angebot, Downloadfehler, Abbruch und vollständiger
  authentifizierter Wechsel mit eigenem Testinstaller.
- Fünf bestehende Installer-Tests bestanden, einschließlich fehlgeschlagener
  Erstinstallation, Upgrade-Rollback und Schutz eines fremden Starters.
- Vollständiges Linux-Update mit realem Paket, eigenem Testschlüssel und dem
  regulären Installer in einem temporären Präfix bestanden. Eine dort simulierte
  1.9.54 wurde auf 1.9.55 aktualisiert: Engine-Vorprüfung, atomarer Versionszeiger,
  stabiler Starter, erhaltene Vorgängerversion und separate Nutzerdaten belegt.
- `sign_update`-Signatur eines eigenen kleinen Fixtures erfolgreich mit Python
  Ed25519 gegengeprüft; kein Produktivschlüssel für diesen Test verwendet.
- Echter Qt-Lauf unter isoliertem X11/Xvfb: Menüprüfung, Anzeige als Klartext,
  Installation ausschließlich per Klick, weiterlaufende Wiedergabe und Beenden
  während einer laufenden Prüfung bestanden. Netzwerkantworten waren eigene
  Fixtures. Update-Dialog hell/dunkel und scrollbare Einstellungen bei 480 × 560
  visuell geprüft; Schließen bleibt außerhalb des Scrollbereichs erreichbar.
- Linux-GUI-Smoke einschließlich Autoplay, Pause/Seek, Modell/Takt, Subtune,
  Favorit/Suche, 3SID, Mute/Solo, Hörlisten, Verlauf und Mini-Player bestanden.
- Unveränderter Swift-Stand: Core-/App-Suite mit 413 Tests, vier übersprungen,
  und sechs Desktop-Regressionstests ohne Fehler. Release-Guard und Workflow-Syntax
  bestanden. Der macOS-Releaseweg baut weiterhin App und DMG mit eigenen Tickets.

## Grenzen und Erstinstallation

1.9.52 enthält keinen Linux-Updater. Einmalig das neue Archiv installieren und die
alte App regulär beenden; danach aus dem Anwendungsmenü neu starten. Ein Release
mit identischer Versionsnummer wird nicht als Update angeboten.

Die isolierten Prüfungen belegen den Installationsweg, aber weder eine physische
Wayland-Bedienung noch einen Versionswechsel in einer produktiven Sitzung. Die
laufende App wird nie ungefragt beendet oder neu gestartet. macOS verwendet
weiterhin Sparkle. Keine SID-Musik wird ausgeliefert.
