Vicious SID Player 1.8.1 bringt den Emulationskern als nativen
Kommandozeilen-Player nach Linux und härtet Songlängenanalyse, Rendering und
skriptgesteuerte Ausgabe. Die notarisierte macOS-App samt Quick-Look-Erweiterung
bleibt im DMG enthalten.

## Linux-Kommandozeilen-Player

- `vicious-sid` spielt SID-Dateien in Echtzeit über ALSA und funktioniert damit
  auch mit PipeWire und PulseAudio.
- Rohes 16-Bit-PCM lässt sich über stdout in Pipelines streamen, während
  Diagnosen ausschließlich nach stderr gehen.
- Die Terminalsteuerung bietet Pause/Fortsetzen, Subtune-Wechsel und sauberes
  Beenden; nicht-interaktives stdin wird automatisch erkannt.
- Die MPRIS2-Integration stellt Wiedergabe, Metadaten und Subtune-Wechsel für
  Medientasten und Sound-Steuerungen des Desktops bereit. Ohne
  D-Bus-Session läuft die Wiedergabe normal weiter.
- `build_deb.sh` erzeugt ein Debian-Paket mit statisch gelinktem CLI,
  Desktop-Eintrag, Dateizuordnung und Icon.
- Linux-Build und -Tests laufen jetzt bei jedem Push im festgelegten
  Swift-6-Container.

## Zuverlässigkeit und Sicherheit

- Songlängen-Datenbank und Hintergrundschätzung sind abbrechbar und
  generationssicher; ein älteres asynchrones Ergebnis kann den aktuell
  gewählten Titel nicht mehr überschreiben.
- Zwischenzeitliche Stille führt nicht mehr dazu, dass ein später fortgesetzter
  Titel mit einem zu frühen Ende gespeichert wird.
- Berechnete Songlängen werden atomar gespeichert; veraltete oder ungültige
  Cache-Daten ersetzen keinen gültigen Zustand.
- WAV- und CLI-Dauern werden vor Frame-Berechnung oder Ausgabe geprüft;
  übergroße und nicht-endliche Werte scheitern kontrolliert.
- Der WAV-Export streamt in eine temporäre Datei und ersetzt das Ziel erst nach
  erfolgreichem Rendering. Dadurch entfallen eine vollständige Speicherkopie
  und unvollständige Zieldateien.
- Das Kürzen eines zu großen SID-Payloads wird als Diagnose gemeldet, statt
  still zu bleiben.

## Verifikation und Kompatibilität

- Die vollständige Swift-Suite, deterministisches Rendering einer synthetischen
  SID, der signierte App-/Quick-Look-Build und die Linux-CI decken die
  Releasepfade ab.
- Das macOS-DMG ist mit Developer ID signiert, von Apple notarisiert und für die
  Offline-Gatekeeper-Prüfung gestapelt.
- Es werden keine SID-Musikdateien mitgeliefert. Der HTML5-Player wird mit
  `python3 build.py` lokal aus den Repository-Quellen erzeugt.

Die native App benötigt macOS 13 oder neuer. Das Linux-CLI benötigt die
Laufzeitbibliotheken für ALSA und D-Bus.
