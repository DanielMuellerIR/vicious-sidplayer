#!/usr/bin/env bash
# Baut die iPhone-App fuer den Simulator. Headless, ohne Signatur, ohne Xcode-GUI.
#
#     bash ios/scripts/build-simulator.sh
#
# Exit-Code 0 = Build gruen. Bei Fehlern werden die letzten Logzeilen und der
# Pfad zum vollstaendigen Log ausgegeben.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_env

# Versions-Gate VOR dem Bau: MARKETING_VERSION im Xcode-Projekt und die Datei
# VERSION duerfen nicht auseinanderlaufen. Der Check existierte, wurde aber von
# keinem regulaeren Bau aufgerufen — das Bundle meldete 1.9.7, waehrend der Code
# 1.9.9 war (Review-Fund 2026-08-17).
bash "$(dirname "${BASH_SOURCE[0]}")/sync-version.sh" --check || exit 1

echo "Baue $SCHEME fuer iOS Simulator ..."
run_xcodebuild build \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO

echo "Produkt: $DERIVED_DATA/Build/Products/Debug-iphonesimulator/ViciousSIDPlayer.app"
