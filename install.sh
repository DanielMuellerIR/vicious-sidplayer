#!/bin/bash
# install.sh — Vicious SID Player notarisiert nach /Applications installieren.
#
# Die drei Einstiegspunkte des Projekts trennen bewusst:
#   ./build.sh          baut die App im Projektverzeichnis, mehr nicht (Unterbau: build_app.sh)
#   ./install.sh        baut, notarisiert und installiert nach /Applications
#   ./release.sh        baut, notarisiert und packt das DMG — installiert nie
#
# Warum notarisiert: In /Applications gehören nur Bundles mit angeheftetem
# Notary-Ticket, die Gatekeeper akzeptiert. Ein ad-hoc signierter Testbuild
# bleibt im Projektverzeichnis.
#
# Voraussetzungen:
#   - "Developer ID Application"-Zertifikat im Schlüsselbund
#   - NOTARY_PROFILE oder `git config viciousSidPlayer.notaryProfile`
#
# Aufruf:  ./install.sh
# Letzte Zeile bei Erfolg: INSTALL OK: /Applications/Vicious SID Player.app (<version>)
set -euo pipefail
cd "$(dirname "$0")"
source ./notarize-lib.sh

require_notary_profile

APP="Vicious SID Player.app"
DESTINATION="/Applications/$APP"
VERSION="$(cat VERSION)"

echo "=== 1/3 App bauen (mit erzwungener Developer-ID-Signatur) ==="
REQUIRE_CODESIGN=1 bash build.sh

echo "=== 2/3 Notarisieren ==="
notarize_app "$APP"

echo "=== 3/3 Installieren ==="
# Erst neben das Ziel legen, dann atomar austauschen: ein Abbruch mittendrin
# darf keine halb ersetzte App in /Applications hinterlassen.
TEAM="${APPLE_TEAM_ID:-9QSWKSR4NQ}"
REQUIREMENT="identifier \"com.viben.ViciousSIDPlayer\" and anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\""
codesign --verify --strict -R="$REQUIREMENT" "$APP"
if [[ -L "$DESTINATION" ]]; then
    echo "ABBRUCH: Das Installationsziel ist ein symbolischer Link." >&2
    exit 1
fi
if [[ -e "$DESTINATION" ]]; then
    # Eine fremde oder ungueltige App gleichen Namens bleibt unangetastet.
    codesign --verify --strict -R="$REQUIREMENT" "$DESTINATION"
    xcrun stapler validate "$DESTINATION"
    spctl -a -t exec "$DESTINATION"
fi
STAGE_DIR="$(mktemp -d "/Applications/.vicious-sid-install.XXXXXX")"
STAGED="$STAGE_DIR/$APP"
cleanup_stage() {
    /usr/bin/python3 - "$STAGE_DIR" <<'PYTHON'
import shutil, sys
shutil.rmtree(sys.argv[1])
PYTHON
}
trap cleanup_stage EXIT
ditto "$APP" "$STAGED"
codesign --verify --strict -R="$REQUIREMENT" "$STAGED"
xcrun stapler validate "$STAGED"
spctl -a -t exec "$STAGED"
# Nur Prozesse der installierten Binaerdatei beenden, keine anderen Testbuilds.
/usr/bin/python3 - "$DESTINATION/Contents/MacOS/ViciousSIDPlayerApp" <<'PYTHON'
import os, signal, subprocess, sys
from pathlib import Path
binary = Path(sys.argv[1])
if binary.exists():
    identity = binary.stat()
    for line in subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True).splitlines():
        fields = line.strip().split(maxsplit=1)
        if len(fields) != 2:
            continue
        try:
            running = Path(fields[1]).stat()
            if (running.st_dev, running.st_ino) == (identity.st_dev, identity.st_ino):
                os.kill(int(fields[0]), signal.SIGTERM)
        except (OSError, ValueError):
            pass
PYTHON
/usr/bin/swift - "$STAGED" "$DESTINATION" <<'SWIFT'
import Foundation

let fileManager = FileManager.default
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
if fileManager.fileExists(atPath: destination.path) {
    _ = try fileManager.replaceItemAt(
        destination,
        withItemAt: source,
        backupItemName: nil,
        options: [.usingNewMetadataOnly]
    )
} else {
    try fileManager.moveItem(at: source, to: destination)
}
SWIFT
cleanup_stage
trap - EXIT

# Nach dem Kopieren erneut prüfen: erst dann ist die Installation belegt.
xcrun stapler validate "$DESTINATION"
spctl -a -t exec -vv "$DESTINATION" 2>&1 | tail -2

echo "INSTALL OK: $DESTINATION ($VERSION)"
