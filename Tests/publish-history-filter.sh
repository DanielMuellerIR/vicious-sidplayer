#!/bin/bash
# Tests/publish-history-filter.sh — der Historienfilter von publish_github.sh
# muss auch Pfade MIT LEERZEICHEN erkennen.
#
# Review-Fund 2026-08-17: `git rev-list --objects --all | awk '{print $2}'`
# behielt vom Pfad nur das erste Wort. Aus "Sammlung/My Tune.sid" wurde
# "Sammlung/My" — das passte auf kein Verbotsmuster, und eine spaeter geloeschte
# SID-Datei mit Leerzeichen im Namen waere trotz der Sperre oeffentlich
# gepusht worden.
#
# Der Test baut ein Wegwerf-Repo mit genau so einer Datei in der Historie und
# laesst NUR den Filterausdruck aus publish_github.sh darauf laufen — das Skript
# selbst wird nicht ausgefuehrt, es wuerde pushen wollen.
#
# Aufruf:  bash Tests/publish-history-filter.sh
# Exit 0 = Filter erkennt die Datei.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/vsp-publish-filter.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Das Verbotsmuster aus dem echten Skript lesen, damit der Test nicht seine
# eigene Kopie prueft.
pattern="$(sed -n "s/^FORBIDDEN_PATTERN='\(.*\)'$/\1/p" "$here/publish_github.sh")"
if [ -z "$pattern" ]; then
    echo "FEHLER: FORBIDDEN_PATTERN nicht aus publish_github.sh lesbar" >&2
    exit 1
fi

repo="$work/repo"
git init -q "$repo"
cd "$repo"
git config user.name t
git config user.email t@localhost
mkdir -p Sammlung
printf 'PSID\n' > 'Sammlung/My Tune.sid'
printf 'text\n' > README.md
git add -A
git commit -q -m "mit Musik"
git rm -q 'Sammlung/My Tune.sid'
git commit -q -m "Musik wieder raus"

# Aktueller Stand ist sauber …
now="$(git ls-files | grep -E -i "$pattern" || true)"
if [ -n "$now" ]; then
    echo "FEHLER: Testaufbau falsch — Datei ist noch getrackt: $now" >&2
    exit 1
fi

# … aber die HISTORIE nicht. Genau die Zeile aus publish_github.sh.
ever="$(git rev-list --objects --all \
    | grep ' ' \
    | cut -d' ' -f2- \
    | grep -E -i "$pattern" | sort -u || true)"

if [ -z "$ever" ]; then
    echo "FEHLER: Historienfilter uebersieht 'Sammlung/My Tune.sid'" >&2
    exit 1
fi
case $ever in
    *"Sammlung/My Tune.sid"*) ;;
    *) echo "FEHLER: Filter meldet einen zerlegten Pfad: $ever" >&2; exit 1 ;;
esac

# Gegenprobe: Der alte awk-Weg haette sie durchgelassen.
alt="$(git rev-list --objects --all | awk '{print $2}' \
    | grep -E -i "$pattern" | sort -u || true)"
if [ -n "$alt" ]; then
    echo "FEHLER: Die Gegenprobe soll den Fehler zeigen, meldet aber: $alt" >&2
    exit 1
fi

echo "publish-history-filter: OK"
