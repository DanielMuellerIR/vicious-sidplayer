#!/bin/bash
# build.sh — einheitlicher Einstieg zum Bauen (Daniels Regel vom 2026-09-11:
# jedes Projekt hat build.sh, install.sh und release.sh an der Repo-Wurzel).
#
# Baut nur: keine Notarisierung, keine Installation. Ohne Developer-ID im
# Schlüsselbund signiert build_app.sh ad hoc — eine Signatur ist also keine
# Voraussetzung (REQUIRE_CODESIGN=1 erzwingt sie, SIGN_APP=0 lässt sie weg).
# Die eigentliche Arbeit macht build_app.sh, das seinen Namen wegen Tests, CI
# und Doku behält. build_app.sh arbeitet mit Pfaden relativ zum Repo, deshalb
# wechselt dieser Wrapper zuerst dorthin. Argumente und Umgebungsvariablen
# gehen unverändert durch, der Exit-Code ist der von build_app.sh (exec).
#
# Aufruf:  ./build.sh
# Letzte Zeile bei Erfolg: BUILD OK: <pfad>/Vicious SID Player.app
set -euo pipefail
cd "$(dirname "$0")"
exec bash build_app.sh "$@"
