#!/usr/bin/env bash
#
# publish_github.sh — Erstveroeffentlichung und Releases fuer GitHub.
#
# Das Skript pusht nur Code, wenn der Arbeitsbaum sauber ist und keine
# Audio-/Release-Artefakte im Git-Index liegen. Releases erzeugt es optional
# ueber GitHub CLI.
#
# Aufruf:
#   bash publish_github.sh                       # Code pushen
#   bash publish_github.sh --release             # Code pushen + Release/DMG
#   bash publish_github.sh --dry-run --release   # Checks anzeigen, nichts pushen
#
# Umgebung:
#   REMOTE_URL      GitHub-URL, Default siehe unten.
#   BRANCH          Zielbranch, Default: main.
#   REQUIRE_CLEAN   1 = sauberer Arbeitsbaum Pflicht, Default: 1.

set -euo pipefail

REMOTE_URL="${REMOTE_URL:-https://github.com/DanielMuellerIR/vicious-sidplayer.git}"
BRANCH="${BRANCH:-main}"
REQUIRE_CLEAN="${REQUIRE_CLEAN:-1}"
VERSION="$(cat VERSION 2>/dev/null || echo "0.0.0")"
TAG="v${VERSION}"
DMG_PATH="build/Vicious SID Player.dmg"
DO_RELEASE=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: bash publish_github.sh [--release] [--dry-run]

  --release  Create or update GitHub release ${TAG} and upload the DMG.
  --dry-run  Run checks and print planned actions without pushing.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            DO_RELEASE=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf 'DRY-RUN:'
        printf ' %q' "$@"
        printf '
'
    else
        "$@"
    fi
}

if [[ "$REQUIRE_CLEAN" == "1" ]] && [[ -n "$(git status --short --untracked-files=all)" ]]; then
    echo "ABBRUCH: Arbeitsbaum nicht sauber. Erst committen oder REQUIRE_CLEAN=0 setzen." >&2
    git status --short --untracked-files=all >&2
    exit 1
fi

# Schutz gegen Testmusik und lokale Release-Artefakte.
#
# Geprueft werden ZWEI Dinge, und das ist der Punkt: `git push` uebertraegt die
# gesamte Historie, nicht nur den aktuellen Stand. Eine einmal committete und
# spaeter wieder geloeschte Musikdatei steckt weiterhin in einem alten Commit
# und waere nach dem Push oeffentlich abrufbar — der aktuelle Baum sieht dabei
# vollkommen sauber aus. Frueher schaute hier nur `git ls-files` nach, also
# ausgerechnet an der Stelle, an der nichts mehr zu finden ist.
FORBIDDEN_PATTERN='(^audio/|\.sid$|\.mod$|\.wav$|\.aiff?$|\.mp3$|\.flac$|\.dmg$|\.app/|\.zip$|\.tar(\.gz)?$)'

FORBIDDEN_NOW="$(git ls-files | grep -E -i "$FORBIDDEN_PATTERN" || true)"
if [[ -n "$FORBIDDEN_NOW" ]]; then
    echo "ABBRUCH: Nicht veroeffentlichbare Artefakte sind getrackt:" >&2
    echo "$FORBIDDEN_NOW" >&2
    exit 1
fi

# `git rev-list --objects` schreibt "<objekt-id> <pfad>" — und der Pfad darf
# Leerzeichen enthalten. `awk '{print $2}'` nahm davon nur das erste Wort: Aus
# "Sammlung/My Tune.sid" wurde "Sammlung/My", was weder auf .sid endet noch
# unter audio/ liegt und deshalb durch den Filter rutschte. Eine spaeter
# geloeschte SID-Datei mit Leerzeichen im Pfad waere so trotz Sperre
# oeffentlich geworden (Review-Fund 2026-08-17). `cut -d' ' -f2-` entfernt
# genau die Objekt-ID und laesst den Rest des Pfads unangetastet; Zeilen ohne
# Pfad (nackte Commit-/Tree-Objekte) fallen durch das grep sowieso heraus.
FORBIDDEN_EVER="$(git rev-list --objects --all \
    | grep ' ' \
    | cut -d' ' -f2- \
    | grep -E -i "$FORBIDDEN_PATTERN" | sort -u || true)"
if [[ -n "$FORBIDDEN_EVER" ]]; then
    echo "ABBRUCH: Nicht veroeffentlichbare Artefakte stecken in der Git-HISTORIE:" >&2
    echo "$FORBIDDEN_EVER" >&2
    echo >&2
    echo "Sie sind im aktuellen Stand zwar nicht mehr da, wuerden mit dem Push aber" >&2
    echo "trotzdem oeffentlich. Das laesst sich nur durch Umschreiben der Historie" >&2
    echo "beheben (git filter-repo) — das ist eine bewusste Entscheidung und" >&2
    echo "passiert nicht nebenbei in diesem Skript." >&2
    exit 1
fi

if [[ "$DO_RELEASE" == "1" ]]; then
    if [[ ! -f "$DMG_PATH" ]]; then
        echo "ABBRUCH: DMG fehlt: $DMG_PATH" >&2
        echo "Vorher ausfuehren: bash build_app.sh && bash build_dmg.sh --notarize" >&2
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "ABBRUCH: GitHub CLI 'gh' fehlt. Fuer Releases installieren oder manuell hochladen." >&2
        exit 1
    fi
fi

# Den Remote-Namen NICHT erzwingen, sondern einen suchen, der bereits auf genau
# diese URL zeigt. Dieses Repo nennt sein GitHub-Remote "github"; wuerde hier
# stur "origin" gesetzt, entstuende ein zweites Remote auf dieselbe Adresse.
# Gepusht wird so oder so nur nach $REMOTE_URL — der Name ist beliebig, die
# Adresse ist die Zusicherung.
REMOTE_NAME="$(git remote | while read -r name; do
    if [[ "$(git remote get-url "$name" 2>/dev/null)" == "$REMOTE_URL" ]]; then
        echo "$name"
        break
    fi
done)"

if [[ -z "$REMOTE_NAME" ]]; then
    # Keins passt: frischer Klon oder erste Veroeffentlichung.
    REMOTE_NAME="origin"
    if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
        run git remote set-url "$REMOTE_NAME" "$REMOTE_URL"
    else
        run git remote add "$REMOTE_NAME" "$REMOTE_URL"
    fi
fi

echo "Remote: $REMOTE_NAME -> $REMOTE_URL"
echo "Branch: $BRANCH"
run git push -u "$REMOTE_NAME" "$BRANCH"

if [[ "$DO_RELEASE" == "1" ]]; then
    if ! git rev-parse "$TAG" >/dev/null 2>&1; then
        run git tag -a "$TAG" -m "Vicious SID Player ${VERSION}"
    fi
    run git push "$REMOTE_NAME" "$TAG"

    if gh release view "$TAG" >/dev/null 2>&1; then
        echo "Release ${TAG} existiert. Lade DMG neu hoch."
        run gh release upload "$TAG" "$DMG_PATH" --clobber
    else
        echo "Lege Release ${TAG} an."
        run gh release create "$TAG" "$DMG_PATH"             --title "Vicious SID Player ${VERSION}"             --notes "macOS-App als DMG. SID-Dateien sind nicht enthalten; Musik wird lokal per Drag & Drop oder aus einem lokalen audio-Ordner geladen."
    fi
fi

echo "Fertig."
