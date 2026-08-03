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

# Alle Vorkommen einsammeln (App- und Test-Target, jeweils Debug und Release).
# `|| true`: unter `set -e` darf ein leerer grep-Treffer das Skript nicht beenden.
ALL_VALUES="$(grep -o 'MARKETING_VERSION = [^;]*' "$PBXPROJ" | sed 's/MARKETING_VERSION = //' || true)"
CURRENT="$(printf '%s\n' "$ALL_VALUES" | head -n1)"

if [ "${1:-}" = "--check" ]; then
    # JEDES Vorkommen muss exakt VERSION sein. Nur das erste zu pruefen liesse
    # eine abweichende Release- oder Test-Konfiguration unbemerkt durchgehen —
    # ein Release truege dann trotz gruenem Check eine andere App-Version.
    if [ -z "$ALL_VALUES" ]; then
        echo "FEHLER: keine MARKETING_VERSION in $PBXPROJ gefunden." >&2
        exit 1
    fi
    MISMATCHES="$(printf '%s\n' "$ALL_VALUES" | grep -Fxv "$VERSION" | sort -u || true)"
    if [ -z "$MISMATCHES" ]; then
        COUNT="$(printf '%s\n' "$ALL_VALUES" | wc -l | tr -d ' ')"
        echo "OK: MARKETING_VERSION = $VERSION (alle $COUNT Vorkommen)"
        exit 0
    fi
    echo "FEHLER: VERSION ist $VERSION, im Projekt steht abweichend: $(printf '%s' "$MISMATCHES" | tr '\n' ' ')" >&2
    echo "        Beheben mit: bash ios/scripts/sync-version.sh" >&2
    exit 1
fi

# Alle Vorkommen ersetzen (App- und Test-Target, jeweils Debug und Release).
/usr/bin/sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
echo "MARKETING_VERSION im iOS-Projekt auf $VERSION gesetzt (vorher: $CURRENT)."
