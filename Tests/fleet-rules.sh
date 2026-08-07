#!/bin/bash
# Tests/fleet-rules.sh — prueft die beiden fleetweiten Regeln vom 2026-08-03 an der QUELLE.
#
#   Regel 1  In /Applications gehoeren nur Bundles mit angeheftetem Notary-Ticket.
#            install.sh muss notarisieren, BEVOR es das erste Mal nach /Applications
#            schreibt. Ad hoc gebaut wird nur im Projektverzeichnis.
#   Regel 2  Kein absoluter Pfad des Build-Rechners im ausgelieferten Bundle.
#
# Der Test liest nur Dateien. Er baut nichts, signiert nichts, notarisiert nichts und
# fasst /Applications nicht an — genau das ist der Punkt: Ein Test, der zum Beleg den
# echten Installationsweg starten muesste, wuerde dabei die installierte App loeschen
# und ersetzen. Er waere selbst die Gefahr, vor der die Regel schuetzt.
#
# Aufruf:  bash Tests/fleet-rules.sh
#          REQUIRE_BUNDLE=1 bash Tests/fleet-rules.sh   (vor einem Release)
# Exit 0 = alle Pruefungen gruen.
#
# Die letzte Pruefung liest die gebauten Programme im App-Bundle. Ohne Bundle kann
# sie nichts belegen und wird uebersprungen — im normalen Quelltest richtig, vor
# einem Release nicht. Dafuer gibt es REQUIRE_BUNDLE=1: dann ist ein fehlendes
# Bundle ein Fehlschlag statt einer stillen Luecke (Review-Fund 2026-08-07).
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
ok()  { echo "  OK   $1"; }
bad() { echo "  FAIL $1" >&2; fail=1; }

# Zeilennummer des ersten Vorkommens eines festen Textes in einer Datei.
first_line() {   # $1 = Datei, $2 = fester Text
    grep -nF -- "$2" "$1" | head -1 | cut -d: -f1
}

echo "1. Regel 1: Ticket vor dem ersten Schreiben nach /Applications"

notarize_line="$(first_line install.sh 'notarize_app "$APP"')"
# Erster Schreibzugriff in /Applications ist das Anlegen des Staging-Pfads.
stage_line="$(first_line install.sh 'STAGED="/Applications/')"
if [ -z "$notarize_line" ] || [ -z "$stage_line" ]; then
    bad "install.sh hat sich strukturell geaendert — Test veraltet, bitte anpassen"
else
    [ "$notarize_line" -lt "$stage_line" ] \
        && ok "notarize_app laeuft vor dem ersten Schreiben nach /Applications" \
        || bad "install.sh schreibt nach /Applications, bevor notarisiert wurde"
fi

grep -qF 'require_notary_profile' install.sh \
    && ok "install.sh verlangt ein Notary-Profil" \
    || bad "install.sh verlangt kein Notary-Profil mehr"
# REQUIRE_CODESIGN=1 verbietet build_app.sh den Ad-hoc-Rueckfall; ohne das koennte
# ein Bundle ohne Developer-ID in den Installationsweg geraten.
grep -qF 'REQUIRE_CODESIGN=1 bash build_app.sh' install.sh \
    && ok "install.sh erzwingt die Developer-ID-Signatur beim Bauen" \
    || bad "install.sh baut ohne erzwungene Developer-ID-Signatur"
grep -qF 'Signature=adhoc' notarize-lib.sh \
    && ok "notarize-lib.sh lehnt ad-hoc signierte Bundles ab" \
    || bad "notarize-lib.sh prueft nicht mehr auf ad-hoc-Signatur"
grep -qF 'stapler validate "$app"' notarize-lib.sh \
    && ok "notarize-lib.sh belegt das angeheftete Ticket" \
    || bad "notarize-lib.sh prueft das angeheftete Ticket nicht mehr"

# Das Bauziel darf nicht aus der Umgebung kommen: build_app.sh loescht es per
# `rm -rf`. Ein umbiegbarer Wert koennte damit die installierte App treffen und
# durch einen ad-hoc signierten Build ersetzen.
grep -qE '^APP_DIR="Vicious SID Player\.app"$' build_app.sh \
    && ok "build_app.sh baut fest ins Projektverzeichnis" \
    || bad "build_app.sh baut nicht mehr fest ins Projektverzeichnis"

echo
echo "2. Regel 2: keine absoluten Build-Mac-Pfade im ausgelieferten Bundle"

# Reine Kommentarzeilen ausnehmen, sonst schlaegt der Test an der Begruendung an.
# Das Ergebnis wird eingesammelt statt in `grep -q` gepipet: ein `grep -q` am Ende
# einer Pipeline schliesst die Leitung nach dem ersten Treffer, der Erzeuger stirbt
# an SIGPIPE, und `pipefail` machte daraus faelschlich einen Fehlschlag.
code_matches() {   # $1 = erweiterter regulaerer Ausdruck
    grep -rnE --include='*.swift' "$1" Sources 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+: *//'
}

# `#filePath`/`#file` setzen den absoluten Quellpfad des Build-Rechners als
# Zeichenkette ins Binary.
hits="$(code_matches '#filePath|#file[^P]')"
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    bad "#filePath/#file in Sources — der Quellpfad des Build-Macs landet im Binary"
else
    ok "kein #filePath/#file in Sources"
fi

# `Bundle.module`: SwiftPM baut in den dafuer erzeugten Zugriff den absoluten
# .build-Pfad des Build-Macs als Ausweichort ein. Der laege dann in jedem
# ausgelieferten Binary und wuerde auf dem Build-Mac sogar benutzt.
hits="$(code_matches 'Bundle\.module')"
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    bad "Bundle.module in Sources — bringt den absoluten .build-Pfad ins Binary"
else
    ok "kein Bundle.module in Sources"
fi

# Der Strip-Schritt entfernt die Debug-Map, in der `swift build -c release` fuer
# jede Quelldatei den vollen .o-Pfad DIESES Macs ablegt. Er muss vorhanden sein
# UND vor dem Signaturblock stehen — `strip` macht eine vorhandene Signatur
# ungueltig. Statisch geprueft, weil die Binaerprobe weiter unten ohne gebautes
# Bundle uebersprungen wird: ein geloeschter oder verschobener Strip-Schritt
# bliebe sonst im normalen Quelltest gruen.
strip_line="$(first_line build_app.sh 'strip -S "$macho"')"
signblock_line="$(first_line build_app.sh '=== Checking code signing identity ===')"
if [ -z "$strip_line" ] || [ -z "$signblock_line" ]; then
    bad "build_app.sh hat sich strukturell geaendert — Strip-Pruefung veraltet, bitte anpassen"
else
    [ "$strip_line" -lt "$signblock_line" ] \
        && ok "build_app.sh entfernt die Debug-Symbole vor dem Signieren" \
        || bad "build_app.sh signiert, bevor die Debug-Symbole entfernt sind"
fi

# Direkte Probe an den gebauten Programmen im Bundle, falls schon gebaut.
APP="Vicious SID Player.app"
if [ -d "$APP" ]; then
    leaks=""
    while IFS= read -r binary; do
        found="$(strings -a "$binary" | grep -F "$HOME/")"
        [ -n "$found" ] && leaks="$leaks
$binary:
$found"
    done < <(find "$APP" -type f -perm +111)
    if [ -n "$leaks" ]; then
        printf '%s\n' "$leaks" | sed 's/^/    /' >&2
        bad "gebautes Bundle enthaelt Pfade aus dem Heimatverzeichnis"
    else
        ok "gebautes Bundle enthaelt keine Pfade aus dem Heimatverzeichnis"
    fi
elif [ "${REQUIRE_BUNDLE:-0}" = "1" ]; then
    bad "$APP nicht vorhanden — mit REQUIRE_BUNDLE=1 ist die Binaerprobe Pflicht"
else
    echo "  --   $APP nicht vorhanden; Probe uebersprungen (erst 'bash build_app.sh')"
fi

echo
if [ "$fail" = "0" ]; then
    echo "fleet-rules: OK"
else
    echo "fleet-rules: FEHLGESCHLAGEN" >&2
    exit 1
fi
