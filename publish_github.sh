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
#
# Die Pruefung selbst steht in `publish-lib.sh`, damit der Test in
# `Tests/publish-history-filter.sh` denselben Code laufen laesst und nicht eine
# eigene Kopie davon.
source "$(dirname "$0")/publish-lib.sh"

FORBIDDEN_NOW="$(forbidden_paths_now)"
if [[ -n "$FORBIDDEN_NOW" ]]; then
    echo "ABBRUCH: Nicht veroeffentlichbare Artefakte sind getrackt:" >&2
    echo "$FORBIDDEN_NOW" >&2
    exit 1
fi

FORBIDDEN_EVER="$(forbidden_paths_ever)"
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

# Prueft, ob das DMG wirklich ein Release-Artefakt dieser Version ist.
#
# Dass die Datei DA ist, sagt genau nichts: `build_dmg.sh` legt auch ohne
# `--notarize` ein Image an genau diesem Pfad ab, und ein liegengebliebenes
# Image der Vorversion sieht von aussen identisch aus. Beides waere frueher
# unter dem aktuellen Tag hochgeladen worden, obwohl das Projekt ausschliesslich
# doppelt notarisierte, versionsgleiche Artefakte zusagt (Review-Fund
# 2026-08-20).
#
# Geprueft wird deshalb dreierlei: Notary-Ticket am Image, Gatekeeper-Akzeptanz
# und — im geoeffneten Image — Version und eigenes Ticket der enthaltenen App.
verify_release_dmg() {
    local dmg="$1" expected="$2" tool
    for tool in xcrun hdiutil spctl plutil; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "ABBRUCH: '$tool' fehlt — die Release-Pruefung laeuft nur auf macOS." >&2
            return 1
        fi
    done

    echo "Pruefe Release-Artefakt: $dmg"
    if ! xcrun stapler validate "$dmg" >/dev/null 2>&1; then
        echo "ABBRUCH: Am DMG haengt kein Notary-Ticket: $dmg" >&2
        echo "Release-Artefakte entstehen ausschliesslich ueber ./release.sh." >&2
        return 1
    fi
    if ! spctl -a -t open --context context:primary-signature "$dmg" >/dev/null 2>&1; then
        echo "ABBRUCH: Gatekeeper akzeptiert das DMG nicht: $dmg" >&2
        return 1
    fi

    local mount status=0 app version
    mount="$(mktemp -d)"
    if ! hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount" >/dev/null; then
        echo "ABBRUCH: DMG laesst sich nicht oeffnen: $dmg" >&2
        rmdir "$mount" 2>/dev/null || true
        return 1
    fi

    app="$(find "$mount" -maxdepth 1 -name '*.app' -print -quit)"
    if [[ -z "$app" ]]; then
        echo "ABBRUCH: Im DMG steckt keine App." >&2
        status=1
    else
        version="$(plutil -extract CFBundleShortVersionString raw -o - \
            "$app/Contents/Info.plist" 2>/dev/null || true)"
        if [[ "$version" != "$expected" ]]; then
            echo "ABBRUCH: Die App im DMG hat Version '$version', VERSION sagt '$expected'." >&2
            echo "Das DMG stammt aus einem aelteren Lauf — neu bauen mit ./release.sh." >&2
            status=1
        fi
        # Die App braucht ihr EIGENES Ticket, nicht nur das Image: Sonst meckert
        # Gatekeeper, sobald jemand sie aus dem DMG herauszieht.
        if ! xcrun stapler validate "$app" >/dev/null 2>&1; then
            echo "ABBRUCH: Der App im DMG fehlt ihr eigenes Notary-Ticket." >&2
            status=1
        fi
    fi

    hdiutil detach "$mount" -quiet 2>/dev/null \
        || hdiutil detach "$mount" -force -quiet 2>/dev/null \
        || true
    rmdir "$mount" 2>/dev/null || true
    return $status
}

if [[ "$DO_RELEASE" == "1" ]]; then
    if [[ ! -f "$DMG_PATH" ]]; then
        echo "ABBRUCH: DMG fehlt: $DMG_PATH" >&2
        echo "Vorher ausfuehren: ./release.sh" >&2
        exit 1
    fi
    verify_release_dmg "$DMG_PATH" "$VERSION"
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
#
# Geprueft werden BEIDE Adressen eines Remotes. `git remote get-url` liefert nur
# die Fetch-Adresse; ein Remote kann zusaetzlich eine eigene `pushurl` haben, und
# genau die benutzt `git push`. Mit nur der Fetch-Pruefung waere die Zusage
# „gepusht wird nur nach $REMOTE_URL" schlicht falsch gewesen
# (Review-Fund 2026-08-20).
REMOTE_NAME="$(git remote | while read -r name; do
    if [[ "$(git remote get-url "$name" 2>/dev/null)" == "$REMOTE_URL" ]] \
       && [[ "$(git remote get-url --push "$name" 2>/dev/null)" == "$REMOTE_URL" ]]; then
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
    # Eine bereits gesetzte abweichende Push-Adresse ueberschreibt `set-url`
    # nicht — sie muss ausdruecklich mit umgebogen werden.
    run git remote set-url --push "$REMOTE_NAME" "$REMOTE_URL"
fi

# Letzte Zusicherung unmittelbar vor dem Push. Im Trockenlauf kann das Remote
# noch gar nicht existieren, weil `run` das Anlegen nur angezeigt hat.
if git remote get-url --push "$REMOTE_NAME" >/dev/null 2>&1; then
    ACTUAL_PUSH_URL="$(git remote get-url --push "$REMOTE_NAME")"
    if [[ "$ACTUAL_PUSH_URL" != "$REMOTE_URL" ]]; then
        echo "ABBRUCH: Push-Adresse von '$REMOTE_NAME' ist $ACTUAL_PUSH_URL," >&2
        echo "erwartet war $REMOTE_URL." >&2
        exit 1
    fi
elif [[ "$DRY_RUN" != "1" ]]; then
    echo "ABBRUCH: Remote '$REMOTE_NAME' existiert nicht." >&2
    exit 1
fi

# Zielrepo als <owner/repo> aus der bereits geprueften Adresse ableiten und `gh`
# ausdruecklich darauf festnageln — sonst raet es aus dem Arbeitsverzeichnis.
REPO_SLUG="$(printf '%s\n' "$REMOTE_URL" | sed -E 's#^https://github\.com/##; s#^git@github\.com:##; s#\.git$##')"
if [[ ! "$REPO_SLUG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "ABBRUCH: Aus $REMOTE_URL laesst sich kein <owner/repo> ableiten." >&2
    exit 1
fi

echo "Remote: $REMOTE_NAME -> $REMOTE_URL"
echo "Branch: $BRANCH"
# --no-follow-tags ausdruecklich, nicht bloss weggelassen: Steht irgendwo
# `push.followTags=true`, haengt Git an JEDEN Push die erreichbaren annotierten
# Tags an. In diesem Repo liegen interne Sicherungs-Tags (etwa
# `pre-github-flatten`), die auf GitHub nichts zu suchen haben.
run git push --no-follow-tags -u "$REMOTE_NAME" "$BRANCH"

if [[ "$DO_RELEASE" == "1" ]]; then
    # Ein schon vorhandener Tag wurde bisher blind weitergereicht. Zeigt er auf
    # einen aelteren Commit, haengt am Ende das frische DMG (per `--clobber`) am
    # Release eines alten Quellstands — Quelle und Auslieferung liefen dauerhaft
    # auseinander (Review-Fund 2026-08-20).
    BRANCH_COMMIT="$(git rev-parse "${BRANCH}^{commit}")"
    # Vollstaendig qualifiziert pruefen: Ein Branch desselben Namens loeste den
    # nackten Namen genauso auf, und das Skript hielte einen fehlenden Tag
    # faelschlich fuer vorhanden.
    if git rev-parse -q --verify "refs/tags/${TAG}^{commit}" >/dev/null; then
        TAG_COMMIT="$(git rev-parse "refs/tags/${TAG}^{commit}")"
        if [[ "$TAG_COMMIT" != "$BRANCH_COMMIT" ]]; then
            echo "ABBRUCH: Tag $TAG zeigt auf $TAG_COMMIT," >&2
            echo "Branch $BRANCH steht aber auf $BRANCH_COMMIT." >&2
            echo "Entweder VERSION erhoehen oder den Tag bewusst umsetzen." >&2
            exit 1
        fi
    else
        run git tag -a "$TAG" -m "Vicious SID Player ${VERSION}"
    fi
    # Refspec vollstaendig ausgeschrieben: So kann kein gleichnamiger Branch
    # dazwischenrutschen und kein weiterer Tag mitwandern.
    run git push --no-follow-tags "$REMOTE_NAME" "refs/tags/${TAG}:refs/tags/${TAG}"

    # Ankunft nachweisen, bevor das Release entsteht. Verglichen werden die
    # Hashes desselben Ref-Typs (annotiertes Tag hier wie dort), nicht der
    # lokale Commit gegen den ungepeelten Remote-Ref.
    if [[ "$DRY_RUN" != "1" ]]; then
        LOCAL_TAG_HASH="$(git rev-parse --verify "refs/tags/${TAG}")"
        REMOTE_TAG_HASH="$(git ls-remote --exit-code --tags "$REMOTE_NAME" "refs/tags/${TAG}" | awk 'NR==1 {print $1}')"
        if [[ "$LOCAL_TAG_HASH" != "$REMOTE_TAG_HASH" ]]; then
            echo "ABBRUCH: Tag $TAG ist nicht wie erwartet angekommen." >&2
            echo "lokal: $LOCAL_TAG_HASH  remote: ${REMOTE_TAG_HASH:-<fehlt>}" >&2
            exit 1
        fi
        echo "Tag $TAG auf dem Remote bestaetigt."
    fi

    if gh release view "$TAG" -R "$REPO_SLUG" >/dev/null 2>&1; then
        echo "Release ${TAG} existiert. Lade DMG neu hoch."
        run gh release upload "$TAG" "$DMG_PATH" --clobber -R "$REPO_SLUG"
    else
        echo "Lege Release ${TAG} an."
        # --verify-tag bricht ab, falls der Remote-Tag doch fehlt; ohne die
        # Option legte `gh` stattdessen einen neuen Tag am Default-Branch an.
        # Die Release-Notizen kommen aus der Datei statt aus einem Einzeiler.
        run gh release create "$TAG" "$DMG_PATH" --verify-tag -R "$REPO_SLUG"             --title "Vicious SID Player ${VERSION}"             --notes-file "RELEASE_NOTES.md"
    fi
fi

echo "Fertig."
