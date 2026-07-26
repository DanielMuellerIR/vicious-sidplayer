#!/usr/bin/env bash
# Erzeugt `ios/Config/Local.xcconfig` aus `ios/.env`.
#
#     bash ios/scripts/apply-env.sh
#
# Warum der Umweg ueber eine xcconfig: die Buildskripte koennten die Team-ID
# auch direkt an xcodebuild reichen (tun sie auch), aber die Xcode-GUI liest
# keine Umgebungsvariablen. Damit „Projekt oeffnen und auf Start druecken"
# ebenfalls funktioniert, landet der Wert zusaetzlich in einer xcconfig, die
# `ios/Config/Signing.xcconfig` optional einbindet.
#
# Beide Dateien — `ios/.env` und `ios/Config/Local.xcconfig` — sind gitignoriert.

set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$IOS_DIR/.env"
OUT_FILE="$IOS_DIR/Config/Local.xcconfig"

if [ ! -f "$ENV_FILE" ]; then
    cat >&2 <<EOF
FEHLER: $ENV_FILE fehlt.

    cp ios/env.example ios/.env
    \$EDITOR ios/.env
    bash ios/scripts/apply-env.sh
EOF
    exit 2
fi

TEAM=""
BUNDLE_ID=""
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    case "$key" in
        DEVELOPMENT_TEAM) TEAM="$value" ;;
        PRODUCT_BUNDLE_IDENTIFIER) BUNDLE_ID="$value" ;;
    esac
done < "$ENV_FILE"

if [ -z "$TEAM" ]; then
    echo "FEHLER: DEVELOPMENT_TEAM ist in $ENV_FILE leer." >&2
    exit 2
fi

{
    echo "// AUTOMATISCH ERZEUGT von ios/scripts/apply-env.sh — nicht von Hand bearbeiten."
    echo "// Quelle: ios/.env  ·  Diese Datei ist gitignoriert und enthaelt die Team-ID."
    echo "DEVELOPMENT_TEAM = $TEAM"
    echo "CODE_SIGN_STYLE = Automatic"
    if [ -n "$BUNDLE_ID" ]; then
        echo "PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID"
    fi
} > "$OUT_FILE"

# Bewusst ohne den Wert selbst — die Team-ID gehoert nicht in Terminal-Historie
# oder CI-Logs.
echo "Geschrieben: ios/Config/Local.xcconfig (DEVELOPMENT_TEAM gesetzt, Wert nicht ausgegeben)"
