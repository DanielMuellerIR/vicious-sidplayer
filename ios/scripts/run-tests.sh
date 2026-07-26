#!/usr/bin/env bash
# Fuehrt die iOS-Testsuite im Simulator aus. Headless, ohne Xcode-GUI.
#
#     bash ios/scripts/run-tests.sh
#     SIM_NAME="iPhone 16 Pro" bash ios/scripts/run-tests.sh
#
# Achtung, zwei verschiedene Testsuiten im Repo:
#   - `swift test`             — der plattformneutrale Core (Parser, DSP, Bibliothek)
#   - dieses Skript            — die iOS-Glue-Schicht (App-Modell, Import-UX, Session)
# Beide muessen gruen sein; das eine ersetzt das andere nicht.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

load_env
resolve_simulator

echo "Teste $SCHEME auf Simulator: $SIM_NAME ($SIM_UDID)"
run_xcodebuild test \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
