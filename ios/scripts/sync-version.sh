#!/usr/bin/env bash
# Traegt die Version aus der Repo-Datei `VERSION` als MARKETING_VERSION ins
# iOS-Projekt ein.
#
#     bash ios/scripts/sync-version.sh          # eintragen
#     bash ios/scripts/sync-version.sh --check   # nur pruefen, nichts aendern
#
# Warum es das gibt: die Version steht im Repo genau einmal in `VERSION`. Das
# .xcodeproj braucht sie aber als eigenen Build-Setting-Wert. Ohne dieses Skript
# driften beide auseinander, und die iOS-App zeigt irgendwann eine Version an,
# die es nie gegeben hat.

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
PBXPROJ="$IOS_DIR/ViciousSIDPlayer.xcodeproj/project.pbxproj"

VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
if [ -z "$VERSION" ]; then
    echo "FEHLER: $REPO_ROOT/VERSION ist leer." >&2
    exit 2
fi

CURRENT="$(grep -m1 -o 'MARKETING_VERSION = [^;]*' "$PBXPROJ" | sed 's/MARKETING_VERSION = //')"

if [ "${1:-}" = "--check" ]; then
    if [ "$CURRENT" = "$VERSION" ]; then
        echo "OK: MARKETING_VERSION = $VERSION"
        exit 0
    fi
    echo "FEHLER: VERSION ist $VERSION, im Projekt steht $CURRENT." >&2
    echo "        Beheben mit: bash ios/scripts/sync-version.sh" >&2
    exit 1
fi

# Alle Vorkommen ersetzen (App- und Test-Target, jeweils Debug und Release).
/usr/bin/sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
echo "MARKETING_VERSION im iOS-Projekt auf $VERSION gesetzt (vorher: $CURRENT)."
