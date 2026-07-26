#!/usr/bin/env bash
# Baut die iPhone-App fuer den Simulator. Headless, ohne Signatur, ohne Xcode-GUI.
#
#     bash ios/scripts/build-simulator.sh
#
# Exit-Code 0 = Build gruen. Bei Fehlern werden die letzten Logzeilen und der
# Pfad zum vollstaendigen Log ausgegeben.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_env

echo "Baue $SCHEME fuer iOS Simulator ..."
run_xcodebuild build \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO

echo "Produkt: $DERIVED_DATA/Build/Products/Debug-iphonesimulator/ViciousSIDPlayer.app"
