#!/usr/bin/env bash
# Baut die App fuer ein echtes iPhone (Sideload mit eigenem Developer-Team).
#
#     cp ios/env.example ios/.env && $EDITOR ios/.env
#     bash ios/scripts/apply-env.sh
#     bash ios/scripts/build-device.sh
#
# Danach in Xcode das iPhone anstecken und die App darauf starten, oder das
# gebaute .app-Bundle ueber Xcode > Window > Devices and Simulators einspielen.
#
# WARUM ES DIESES SKRIPT UEBERHAUPT GIBT: Hintergrundwiedergabe und
# Sperrbildschirm-Steuerung sind im Simulator NICHT belegbar. Der Simulator hat
# keinen echten Sperrbildschirm, keine AirPods, keinen eingehenden Anruf. Diese
# Abnahme geht nur auf Hardware — die Prueflisten stehen in
# `ios/GERAETETEST.md`.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_env

if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
    cat >&2 <<'EOF'
FEHLER: DEVELOPMENT_TEAM ist nicht gesetzt.

Ein Build fuer echte Hardware muss signiert werden, dafuer braucht Xcode die
Apple-Developer-Team-ID. Sie ist bewusst nicht eingecheckt.

    cp ios/env.example ios/.env
    $EDITOR ios/.env          # DEVELOPMENT_TEAM eintragen
    bash ios/scripts/apply-env.sh

Simulator-Builds und Tests brauchen das nicht:
    bash ios/scripts/build-simulator.sh
    bash ios/scripts/run-tests.sh
EOF
    exit 2
fi

# Die Team-ID wird bewusst NICHT ausgegeben — sie soll nicht in Logs oder
# CI-Ausgaben landen.
echo "Baue $SCHEME fuer iOS-Geraet (Team-ID aus ios/.env, wird nicht geloggt) ..."

BUILD_ARGS=(
    build
    -project "$XCODEPROJ"
    -scheme "$SCHEME"
    -configuration Debug
    -destination 'generic/platform=iOS'
    -derivedDataPath "$DERIVED_DATA"
    -allowProvisioningUpdates
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
)
if [ -n "${PRODUCT_BUNDLE_IDENTIFIER:-}" ]; then
    BUILD_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$PRODUCT_BUNDLE_IDENTIFIER")
fi

run_xcodebuild "${BUILD_ARGS[@]}"

echo "Produkt: $DERIVED_DATA/Build/Products/Debug-iphoneos/ViciousSIDPlayer.app"
echo
echo "Naechster Schritt ist ein MENSCHLICHER Test auf dem Geraet — siehe ios/GERAETETEST.md."
