#!/usr/bin/env bash
#
# publish_github.sh — Vicious SID Player auf GitHub veröffentlichen.
#
# Dieses Skript pusht das lokale Repository zum GitHub-Remote und kann
# optional ein DMG als Release-Asset hochladen. SID-Dateien werden NIEMALS
# hochgeladen — sie sind über .gitignore ausgeschlossen und gehören als
# urheberrechtlich geschützte Musik nicht ins Repository.
#
# Aufruf:
#   bash publish_github.sh            # nur Code pushen (main -> origin)
#   bash publish_github.sh --release  # zusätzlich DMG-Release anlegen
#
# Voraussetzungen:
#   - git
#   - gh (GitHub CLI) — nur für --release nötig, vorher: gh auth login

set -euo pipefail

# --- Konfiguration ----------------------------------------------------------
REMOTE_URL="https://github.com/DanielMuellerIR/vicious-sidplayer.git"
BRANCH="main"
VERSION="$(cat VERSION 2>/dev/null || echo "0.0.0")"
TAG="v${VERSION}"
DMG_PATH="build/Vicious SID Player.dmg"

# --- Sicherheitscheck: keine SID-Dateien getrackt ---------------------------
# git ls-files listet nur versionierte Dateien. Findet sich hier eine .sid,
# bricht das Skript ab, damit keine geschützte Musik veröffentlicht wird.
if git ls-files | grep -iq '\.sid$'; then
    echo "ABBRUCH: Es sind SID-Dateien im Git-Index. Diese dürfen nicht hochgeladen werden." >&2
    git ls-files | grep -i '\.sid$' >&2
    exit 1
fi

# --- Remote einrichten (idempotent) -----------------------------------------
# Falls 'origin' schon existiert, nur die URL aktualisieren, sonst anlegen.
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE_URL"
else
    git remote add origin "$REMOTE_URL"
fi

# --- Code pushen ------------------------------------------------------------
echo "Pushe Branch '${BRANCH}' nach ${REMOTE_URL} ..."
git push -u origin "$BRANCH"

# --- Optionales DMG-Release -------------------------------------------------
if [[ "${1:-}" == "--release" ]]; then
    if [[ ! -f "$DMG_PATH" ]]; then
        echo "Kein DMG unter '${DMG_PATH}'. Erst 'bash build_dmg.sh' ausführen." >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "GitHub CLI 'gh' nicht gefunden. Installieren oder Release manuell anlegen." >&2
        exit 1
    fi

    # Annotiertes Tag setzen (falls noch nicht vorhanden) und pushen.
    if ! git rev-parse "$TAG" >/dev/null 2>&1; then
        git tag -a "$TAG" -m "Vicious SID Player ${VERSION}"
    fi
    git push origin "$TAG"

    # Release erstellen und DMG als Asset anhängen.
    echo "Lege GitHub-Release ${TAG} an und lade DMG hoch ..."
    gh release create "$TAG" "$DMG_PATH" \
        --title "Vicious SID Player ${VERSION}" \
        --notes "macOS-App als DMG. SID-Dateien sind nicht enthalten — per Drag & Drop laden."
fi

echo "Fertig."
