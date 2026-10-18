# Prüfstand 1.9.43

Stand: 2026-10-18. Korrektur des Filterzustands beim Muten.

## Reproduktion und Änderung

Bei gefilterten Stimmen wurde der Mixbeitrag bisher vor dem gemeinsamen
Filter entfernt. Oszillator und Hüllkurve liefen weiter, der Filter erhielt
aber einen anderen Eingang. Nach dem Entmuten wich die Ausgabe deshalb
von einer durchgehend ungemuteten Referenz ab. Der neue native Vergleich
scheitert vor der Korrektur für 1SID, 2SID und 3SID mit 6581 und 8580; der
entsprechende Webvergleich reproduziert den Fehler ebenfalls.

Der volle Chipfilter erhält jetzt unabhängig vom Mute alle gerouteten Stimmen.
Zusätzliche Filterbeiträge je Stimme laufen mit denselben Parametern weiter.
Das verwendete Filtermodell ist linear; dadurch lassen sich stumme Beiträge
erst am Ausgang abziehen. Routingwechsel erhalten die zugehörigen Ausläufe.
Natives Bypass mischt nur hörbare Rohbeiträge und hält alle Filterzustände warm.
Ein komplett stummer Chip liefert auch ohne Rundungsreste exakt null.

A/B-Zustände sichern und restaurieren beide zusätzlichen Stimmenpuffer.
Web-Schleifen weisen unvollständige Puffer zurück. Cutoff, Resonanz, CPU,
Oszillator, Hüllkurve und Register-Readbacks sind unverändert.

## Prüfung

- 25 gezielte native Tests ohne Fehler: 1SID/2SID/3SID, beide Modelle,
  exakte Rückkehr nach Unmute, unabhängige Beiträge bei wechselndem Routing,
  vollständiges Mute, Bypass, Seek und wiederholte A/B-Rücksprünge.
- 13 gezielte Webtests ohne Fehler, einschließlich des tatsächlichen
  Dedicated Workers und übertragener A/B-Zustände.

- Vollständige Swift-Suite: 394 Tests, vier lokale Referenzfälle übersprungen,
  keine Fehler. Linux: 353 Tests, 14 begründete Plattform-/Referenzausnahmen,
  keine Fehler. Vollständige Web-Suite: 96 Tests ohne Fehler.
- Die erzeugte minimierte Einzeldatei läuft tatsächlich über `file://` mit
  AudioWorklet, gefiltertem 3SID, Mute/Unmute und vorbereiteter A/B-Schleife.
  Wiedergabe und Loop bleiben aktiv; keine JavaScript-Ausnahmen. Der eigene
  Browserprozess wird danach erfolgreich beendet.
- Zwei Buildtests prüfen die Syntax beider vollständigen HTML-Ausgaben.
  Fleet-Regeltest bestanden.
- 65 tatsächliche iOS-Tests ohne Fehler. Builds gegen Simulator-SDK 27 und
  26.5 sowie das Developer-ID-signierte Mac-Bundle erfolgreich. Keine Warnungen
  im eigenen iOS-Code. Eigenes Testgerät anschließend heruntergefahren.
- Optimierter Core für macOS 13 mit Swift 6 und Warnungen als Fehler übersetzt.

## Unveränderte ungemutete Ausgabe

529.200 native Stereoframes und 529.200 Web-Monosamples sind gegenüber v1.9.42
bitgenau unverändert. Die zwölf Konfigurationen kombinieren 1SID/2SID/3SID,
6581/8580 und PAL/NTSC mit wechselndem Routing und allen Filterausgängen.
Dies prüft die tatsächlichen Double-Werte; Audio-Normalisierung oder eine
Toleranz verstecken keine Abweichungen.

Die neuen Mute-/Unmute-Vergleiche kehren exakt zur durchlaufenden Referenz
zurück. Getrennte gefilterte Beiträge stimmen auch bei Routingwechseln
innerhalb einer Toleranz von 1e-12 mit dem vollen Mix überein. Clipping und
Rundung bleiben Gründe, exportierte Einzelstimmen nicht als bitgenau
addierbare Audiodateien zu versprechen.

Lokale Laufzeitproben bleiben deutlich unter Echtzeit. Während Teilen der
Messung liefen andere Prüfprozesse; daraus wird keine prozentuale
Leistungsänderung abgeleitet. Die gesonderte Energieabnahme bleibt im
[Erweiterungsplan](feature-roadmap.md).
