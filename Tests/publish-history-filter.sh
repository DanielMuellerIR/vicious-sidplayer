#!/bin/bash
# Tests/publish-history-filter.sh — die Veroeffentlichungssperre muss auch die
# unbequemen Pfade erkennen.
#
# Geprueft wird der ECHTE Code: Der Test sourct `publish-lib.sh`, also genau die
# Datei, die auch `publish_github.sh` benutzt. Vorher stand die Pipeline hier ein
# zweites Mal woertlich drin und nur das Suchmuster kam aus dem Produktionsskript
# — ein Rueckschritt dort waere hier gruen geblieben (Review-Fund 2026-08-20).
# Das Skript selbst laesst sich nicht ausfuehren, es wuerde pushen wollen.
#
# Drei Faelle, alle drei sind einmal echt durchgerutscht:
#   1. Pfad MIT LEERZEICHEN  — `awk '{print $2}'` behielt nur das erste Wort.
#   2. Pfad MIT UMLAUT       — `git ls-files` quotet ihn in Anfuehrungszeichen.
#   3. GLEICHER INHALT unter zwei Namen — `git rev-list --objects` nennt zu
#      einem Objekt nur EINEN Fundort, der harmlose Name kann den verbotenen
#      verdecken.
#
# Aufruf:  bash Tests/publish-history-filter.sh
# Exit 0 = die Sperre erkennt alle drei.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=../publish-lib.sh
source "$here/publish-lib.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/vsp-publish-filter.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail=0
ok()  { echo "  OK   $1"; }
bad() { echo "  FAIL $1" >&2; fail=1; }

repo="$work/repo"
git init -q "$repo"
cd "$repo" || exit 1
git config user.name t
git config user.email t@localhost
# `core.quotePath` ausdruecklich auf den Git-Standard setzen: Genau in dieser
# Einstellung entsteht das C-Quoting, an dem die alte Pruefung scheiterte.
git config core.quotePath true

mkdir -p Sammlung
printf 'PSID\n' > 'Sammlung/My Tune.sid'
printf 'PSID\n' > 'Sammlung/Jörg.sid'
# Fall 3: derselbe INHALT unter zwei Namen ist in Git genau EIN Blob.
printf 'derselbe Inhalt\n' > README.md
printf 'derselbe Inhalt\n' > 'Sammlung/Kopie.sid'
git add -A
git commit -q -m "mit Musik"

git rm -q 'Sammlung/My Tune.sid' 'Sammlung/Jörg.sid' 'Sammlung/Kopie.sid'
git commit -q -m "Musik wieder raus"

# Der aktuelle Stand ist sauber — die Sperre darf hier nichts melden …
now="$(forbidden_paths_now)"
if [ -n "$now" ]; then
    bad "Testaufbau falsch, Datei ist noch getrackt: $now"
else
    ok "aktueller Stand wird als sauber erkannt"
fi

# … die HISTORIE dagegen nicht.
ever="$(forbidden_paths_ever)"
for erwartet in 'Sammlung/My Tune.sid' 'Sammlung/Jörg.sid' 'Sammlung/Kopie.sid'; do
    case $ever in
        *"$erwartet"*) ok "Historie: '$erwartet' erkannt" ;;
        *) bad "Historie: '$erwartet' uebersehen (gemeldet wurde: ${ever:-nichts})" ;;
    esac
done

# Gegenprobe: Der frueher benutzte Weg uebersieht den Leerzeichen-Pfad und den
# unter zwei Namen abgelegten Inhalt. Sie steht hier, damit sichtbar bleibt,
# WOGEGEN der Test schuetzt — faellt sie eines Tages um, ist der Fehler von
# damals nicht mehr reproduzierbar und die Gegenprobe gehoert angepasst, nicht
# der Test.
alt="$(git rev-list --objects --all | awk '{print $2}' \
    | grep -E -i "$FORBIDDEN_PATTERN" | sort -u || true)"
for uebersehen in 'My Tune.sid' 'Kopie.sid'; do
    case $alt in
        *"$uebersehen"*) bad "Gegenprobe: der alte Weg fand '$uebersehen' doch — Fehlerbild veraltet" ;;
        *) ok "Gegenprobe: der alte Weg haette '$uebersehen' durchgelassen" ;;
    esac
done

# Ein getracktes Verbot muss die Sperre im aktuellen Stand ebenfalls sehen —
# auch mit Umlaut im Namen. Genau hier greift das C-Quoting von `git ls-files`.
mkdir -p Sammlung
printf 'PSID\n' > 'Sammlung/Späth.sid'
git add 'Sammlung/Späth.sid'
jetzt="$(forbidden_paths_now)"
case $jetzt in
    *'Sammlung/Späth.sid'*) ok "aktueller Stand: Umlaut-Pfad erkannt" ;;
    *) bad "aktueller Stand: 'Sammlung/Späth.sid' uebersehen (gemeldet: ${jetzt:-nichts})" ;;
esac

# Und die Gegenprobe dazu: ohne `-z` quotet Git den Pfad, das Muster verfehlt ihn.
alt_now="$(git ls-files | grep -E -i "$FORBIDDEN_PATTERN" || true)"
case $alt_now in
    *'Späth'*) bad "Gegenprobe: ls-files ohne -z fand den Umlaut-Pfad doch — Fehlerbild veraltet" ;;
    *) ok "Gegenprobe: ohne -z waere der Umlaut-Pfad durchgerutscht" ;;
esac

echo
if [ "$fail" = "0" ]; then
    echo "publish-history-filter: OK"
else
    echo "publish-history-filter: FEHLGESCHLAGEN" >&2
    exit 1
fi
