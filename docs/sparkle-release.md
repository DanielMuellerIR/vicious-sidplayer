# Sparkle-Updates für macOS

Die macOS-App verwendet Sparkle 2.10.0, exakt per SwiftPM gepinnt. Der Menüpunkt
„Nach Updates suchen…“ startet eine sichtbare Suche. Hintergrundprüfungen sind
aktiv; jede Installation braucht die Zustimmung des Nutzers. Systemprofiling
und automatische Installationen sind deaktiviert. iOS, Linux-CLI, HTML5 und
Quick Look bekommen keinen eigenen Updater.

Feed: <https://danielmuellerir.github.io/vicious-sidplayer/appcast.xml>

## Einmalige Einrichtung vor der Veröffentlichung

1. Den projektspezifischen Ed25519-Schlüssel im Login-Schlüsselbund unter dem
   Account `com.viben.ViciousSIDPlayer` aufbewahren und verschlüsselt sichern.
   Der öffentliche Gegenpart steht in `config/sparkle-public-key.txt`; der private
   Schlüssel darf nie im Repository, in Argumenten oder Logs landen.
2. Den privaten Schlüssel als GitHub-Actions-Secret `SPARKLE_PRIVATE_KEY` setzen.
   Sparkles `generate_keys --account com.viben.ViciousSIDPlayer -x <datei>`
   exportiert ihn in eine geschützte temporäre Datei. Den Export mit
   `gh secret set SPARKLE_PRIVATE_KEY --repo DanielMuellerIR/vicious-sidplayer`
   über stdin einlesen und die Klartextdatei danach entfernen. Zugriff und
   Sicherung dieses Schlüssels gehören zum Release-Preflight.
3. GitHub Pages auf die Quelle **GitHub Actions** stellen. Die Umgebung
   `github-pages` muss Deployments von Release-Tags `v*` erlauben.

Diese Einrichtung und die erste Veröffentlichung sind separate Schritte. Das
Einchecken des Workflows veröffentlicht keinen Feed.

## Release-Ablauf

1. `VERSION` monoton erhöhen. App und Quick-Look-Extension verwenden diesen Wert
   für `CFBundleVersion` und `CFBundleShortVersionString`.
2. `./release.sh` baut und notarisiert App und DMG. Sparkles Helfer werden von
   innen nach außen mit derselben Developer-ID wie die App signiert. Das Framework
   und seine Lizenz gehören ins App-Bundle; seine Versions-Symlinks bleiben erhalten.
3. Nach den Veröffentlichungsprüfungen das Release mit `publish_github.sh --release`
   veröffentlichen. Es muss genau ein notarisiertes DMG als Asset enthalten.
4. `.github/workflows/publish-appcast.yml` erzeugt beim Ereignis `release: published`
   den signierten Appcast. Bei einem nachträglichen Asset-Upload oder einer
   Wiederholung einen neuen Workflow-Lauf mit dem entsprechenden Tag starten.

Der Workflow akzeptiert nur das neueste stabile Release und den Quelltext seines
Tags. Vor dem Signieren prüft er Gatekeeper, Notary-Tickets, Code-Identität,
Bundle-Version, Feed-URL und öffentlichen Schlüssel der App im DMG. Das Secret ist
nur im Signierschritt verfügbar und wird dem Sparkle-Werkzeug über stdin gegeben.
Anschließend prüft `scripts/verify-appcast.swift` Feed- und Archivsignatur unabhängig
gegen den Schlüssel aus dem DMG sowie Version, Archivlänge und Download-URL.
Erst danach wird der Feed auf Pages veröffentlicht. Es gibt ein Vollupdate,
keine Deltas.

## Prüfung und erste Installation

```bash
bash Tests/sparkle-appcast.sh
python3 Tests/sparkle-workflow.py
bash build_app.sh
bash Tests/fleet-rules.sh
```

Die Appcast-Tests prüfen gültige Signaturen, einen falschen Schlüssel, manipulierte
Feeds und Archive, falsche Längen, Versionen und Download-URLs sowie mehrere Updates.
Für einen lokalen DMG-Test `bash build_dmg.sh --no-finder-layout` verwenden.
Sparkles `generate_appcast --account com.viben.ViciousSIDPlayer` muss daraus einen
Feed samt Archivsignatur und abschließendem `sparkle-signatures`-Block erzeugen.
`SURequireSignedFeed` und `SUVerifyUpdateBeforeExtraction` bleiben beide aktiviert.

Die erste Sparkle-fähige Version muss einmal manuell installiert werden, weil ihre
Vorgänger keinen Updater enthalten. Ein vollständiger Update-Test braucht zwei
Sparkle-fähige, notarisiert signierte Fassungen mit derselben Bundle-ID und demselben
Schlüssel; die ältere `CFBundleVersion` muss kleiner sein. Feed-Erzeugung und ein
grüner Workflow allein belegen noch keinen erfolgreichen Austausch samt Neustart.
