# Prüfstand v1.9.36

Stand: 2026-10-16. Der HTML5-Sammlungsaustausch ist implementiert. Die Abnahme verwendet die tatsächlich gebaute lokale Einzeldatei in Chromium 155, neu ausgewählte synthetische SID-Dateien, echte Datei-Input- und Downloadpfade sowie selbst angesehene Browserbilder. Der Browser lief ohne Fokusübernahme im Headless-Modus.

- 69 Node-Testfälle ohne Fehler: bestehende Wiedergabe-, Listen- und Verlaufsregeln sowie Format, native Referenzarchive, MD5-Padding und echte Puffer-Ausschnitte, Unicode, Kapazität, Auflösung, Merge, Migration und Speicherschutz.
- Python-Buildprüfung und Fleet-Quellprüfung bestanden. Minifizierte und unminifizierte Single-File-Ausgaben sind jeweils bytegleich reproduzierbar.
- Ein tatsächlicher nativer Export wurde importiert: zwei Favoriten, eine Liste mit zwei bewusst gleichen Subtunes und verschiedenen Eintrags-IDs, eine Marke bei 42,125 Sekunden und zwei Notizen einschließlich fehlender Datei. Wiedergabe lief während der Vorschau weiter; Übernahme erhielt Queue, Titel, Subtune und Position. Der Wiederholungsimport zeigte null Ergänzungen, null Aktualisierungen und sechs unveränderte Einträge.
- Verlauf blieb ohne Auswahl aus. Seine bewusste Übernahme erhielt vier ursprüngliche Episoden-IDs und die unabhängige Gehört-Kennzeichnung. Die tatsächlich heruntergeladene Browserdatei besteht den nativen Swift-Codec und dessen erneuten Kodierungs-/Dekodierungsrundlauf.
- Alte v1-Browserwerte blieben bytegleich. Neu ausgewählte Musik bestätigte MD5-Referenzen bei erhaltenen Track-IDs; eine vorbereitete Legacy-Queue blieb mit Subtune 3 und 42,125 Sekunden stehen, ohne Autostart. Auch der tatsächliche Legacy-Rückexport besteht den nativen Codec.
- Ein verspätetes Schließereignis des vorherigen Dialogs verwirft keine gerade neu geladene Vorschau.
- Konkrete vorhandene und importierte Langtexte wurden vollständig aufgeklappt in Hell, Dunkel und bei 390 Pixel Breite visuell geprüft. Pfadvertrauen ließ sich annehmen, widerrufen und erneut annehmen. Schließen der Vorschau änderte die persönlichen Speicherwerte nicht.
- Übernahme während eines noch laufenden Audioaufbaus entwertet den alten Play-Auftrag und setzt bewusst angeforderte Wiedergabe genau einmal fort.
- Ein tatsächlich injizierter Fehler beim zweiten Browser-Schreibzugriff setzte beide Originalwerte bytegleich zurück. Erneute Übernahme gelang; der Fehler wird als fehlender Browserspeicher verständlich angezeigt. Queue und vorbereitete Position blieben erhalten.
- Zwei echte Seiten derselben lokalen Produktdatei schützen den zuerst gespeicherten Fremdstand. Ein späterer v1-Writer wird ebenfalls erkannt. Ein beim frühen Start vorbereitetes Journal wird bytegleich zurückgesetzt; ein bestätigtes Journal vervollständigt beide Dokumente. Anschließender vollständiger Browserprozess-Neustart erhält die bestätigten Werte und startet keine Musik.
- Eine neuere Verlaufsablage bleibt geschützt. Bei 5.000 nicht zugeordneten Pfaden werden genau 20 Ergebniszeilen materialisiert; die nächste Seite zeigt 21–40.
- Native Endzeiten werden im Browser ausdrücklich ausgenommen. Ungültiges UTF-8, unvollständige Surrogate, Traversal, ungültige Kalenderdaten, doppelte IDs und nicht unterstützte Formate werden abgewiesen. Ein UTF-8-BOM bleibt im Original erhalten; das native Format dekodiert ihn ebenfalls.

Die produktbezogene Browser-Dialogabnahme umfasst Vorschau, Übernahme, Download und Schließen. Betriebssystemeigene Öffnen-/Sichern-Dialoge wurden für diese HTML5-Stufe nicht gesondert visuell abgenommen. Safari, Firefox, verschiedene file://-Dateipfade und nicht kooperierende alte Seiten sind nicht als allgemein atomar abgenommen; Änderungen an alten Speicherwerten führen zum Schutz statt zum Überschreiben.

Native Swift-/iOS-Produktquellen wurden in dieser Stufe nicht verändert. Die vorhandene native Abnahme gilt weiter; plattformabhängige iPhone-Audiofälle bleiben Teil von `ios/GERAETETEST.md`.
