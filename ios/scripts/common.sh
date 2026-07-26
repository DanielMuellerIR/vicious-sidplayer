#!/usr/bin/env bash
# Gemeinsame Grundlagen der iOS-Skripte. Wird von den anderen Skripten per
# `source` eingebunden, nicht direkt aufgerufen.
#
# Zweck: Pfade, Simulator-Auswahl und das Einlesen der gitignorierten `.env`
# stehen genau einmal hier — sonst driften build-simulator.sh, run-tests.sh und
# build-device.sh mit der Zeit auseinander.

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
XCODEPROJ="$IOS_DIR/ViciousSIDPlayer.xcodeproj"
SCHEME="ViciousSIDPlayer"
# Alle Buildartefakte landen ausserhalb des Repos bzw. in einem gitignorierten
# Unterordner — nichts davon gehoert in die Versionskontrolle.
DERIVED_DATA="${DERIVED_DATA:-$IOS_DIR/build/DerivedData}"

# Simulator-Ziel. Ueberschreibbar, z.B.:
#     SIM_NAME="iPhone 16 Pro" bash ios/scripts/build-simulator.sh
SIM_NAME="${SIM_NAME:-}"

# Liest ios/.env (falls vorhanden) und exportiert die Werte. Bewusst ohne
# `source`: eine .env ist Konfiguration, kein Skript — sie darf keine Befehle
# ausfuehren koennen.
load_env() {
    local env_file="$IOS_DIR/.env"
    [ -f "$env_file" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        # Kommentare und Leerzeilen ueberspringen.
        case "$line" in ''|'#'*) continue ;; esac
        key="${line%%=*}"
        value="${line#*=}"
        # Umgebende Anfuehrungszeichen entfernen, falls jemand welche setzt.
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        # Nur erwartete Schluessel uebernehmen, damit eine verrutschte Zeile
        # nicht versehentlich PATH o.ae. ueberschreibt.
        case "$key" in
            DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER) export "$key=$value" ;;
        esac
    done < "$env_file"
}

# Sucht ein brauchbares iPhone-Simulator-Geraet und setzt SIM_UDID/SIM_NAME.
# Bevorzugt ein bereits gebootetes Geraet (schneller), sonst das erste
# verfuegbare iPhone.
resolve_simulator() {
    local json
    json="$(xcrun simctl list devices available --json)"
    SIM_UDID="$(SIM_NAME="$SIM_NAME" /usr/bin/python3 - "$json" <<'PY'
import json, os, sys

data = json.loads(sys.argv[1])
wanted = os.environ.get("SIM_NAME", "").strip()
candidates = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable"):
            continue
        if not device.get("name", "").startswith("iPhone"):
            continue
        candidates.append((runtime, device))

if wanted:
    candidates = [c for c in candidates if c[1]["name"] == wanted]

# Ein schon laufender Simulator spart den Bootvorgang.
booted = [c for c in candidates if c[1].get("state") == "Booted"]
pick = (booted or candidates)
if not pick:
    sys.exit(1)
# Neueste Laufzeitumgebung zuerst.
pick.sort(key=lambda c: c[0], reverse=True)
print(pick[0][1]["udid"] + "\t" + pick[0][1]["name"])
PY
)" || { echo "FEHLER: kein verfuegbarer iPhone-Simulator gefunden." >&2
        echo "        Verfuegbare Geraete: xcrun simctl list devices available" >&2
        return 1; }
    SIM_NAME="${SIM_UDID#*$'\t'}"
    SIM_UDID="${SIM_UDID%%$'\t'*}"
    export SIM_UDID SIM_NAME
}

# xcodebuild-Aufruf mit gefilterter Ausgabe: interessant sind Warnungen, Fehler
# und das Endergebnis — nicht die tausend Compilerzeilen dazwischen.
run_xcodebuild() {
    local logfile
    logfile="$(mktemp -t vicious-ios-build)"
    local status=0
    xcodebuild "$@" > "$logfile" 2>&1 || status=$?
    # Warnungen und Fehler AUS UNSEREM CODE zeigen (Pfade unterhalb des Repos);
    # Warnungen aus dem SDK oder aus Abhaengigkeiten interessieren hier nicht.
    grep -E "(error|warning): " "$logfile" | sort -u | head -50 || true
    grep -E "^\*\* (BUILD|TEST|ARCHIVE) (SUCCEEDED|FAILED) \*\*" "$logfile" || true
    if [ "$status" -ne 0 ]; then
        echo "--- letzte 40 Zeilen des Buildlogs ---" >&2
        tail -40 "$logfile" >&2
        echo "--- vollstaendiges Log: $logfile ---" >&2
        return "$status"
    fi
    rm -f "$logfile"
    return 0
}
