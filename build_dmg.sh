#!/bin/bash
set -euo pipefail

DMG_NAME="Vicious SID Player"
APP_NAME="Vicious SID Player.app"
VOL_NAME="Vicious SID Player"
BUILD_DIR="build"
RW_DMG=""
WORK_DIR=""
OWN_DEVICE=""
FINAL_DMG="${BUILD_DIR}/${DMG_NAME}.dmg"
MOUNT_DIR=""
NOTARIZE=0
FINDER_LAYOUT=1
# Kein fester Default: der Profilname ist umgebungsspezifisch (Keychain des
# Build-Macs) und gehoert nicht ins public Repo. Umgebung schlaegt clone-lokale
# Git-Konfiguration; install.sh/release.sh setzen NOTARY_PROFILE ohnehin selbst.
NOTARY_PROFILE="${NOTARY_PROFILE:-$(git config --local --get viciousSidPlayer.notaryProfile 2>/dev/null || true)}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-9QSWKSR4NQ}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Daniel Mueller ($APPLE_TEAM_ID)}"
SIGN_DMG="${SIGN_DMG:-auto}"

usage() {
    cat <<EOF
Usage: bash build_dmg.sh [--notarize] [--no-finder-layout]

  --notarize          Submit DMG with xcrun notarytool and staple ticket.
  --no-finder-layout  Skip Finder/AppleScript icon layout, useful on headless runs.

Environment:
  NOTARY_PROFILE      Keychain profile for notarytool (required for --notarize).
                      Falls back to \`git config viciousSidPlayer.notaryProfile\`.
  SIGN_DMG            auto/1/0, controls Developer ID signing of the DMG.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize)
            NOTARIZE=1
            shift
            ;;
        --no-finder-layout)
            FINDER_LAYOUT=0
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

# Fail-fast VOR dem (minutenlangen) DMG-Build: --notarize ohne Profilname
# wuerde sonst erst ganz am Ende abbrechen und das fertige DMG unnotarisiert
# zuruecklassen.
if [[ "$NOTARIZE" == "1" && -z "$NOTARY_PROFILE" ]]; then
    echo "ABBRUCH: --notarize braucht NOTARY_PROFILE (Name des notarytool-Keychain-Profils)." >&2
    echo "Beispiel: NOTARY_PROFILE=MeinNotaryProfil bash build_dmg.sh --notarize" >&2
    echo "Oder einmalig fuer diesen Clone: git config --local viciousSidPlayer.notaryProfile <profil>" >&2
    exit 1
fi

cleanup() {
    if [[ -n "$OWN_DEVICE" ]]; then
        hdiutil detach "$OWN_DEVICE" >/dev/null 2>&1 || hdiutil detach -force "$OWN_DEVICE" >/dev/null 2>&1 || true
    fi
    if [[ -n "$WORK_DIR" ]]; then
        /usr/bin/python3 - "$WORK_DIR" <<'PYTHON'
import shutil, sys
shutil.rmtree(sys.argv[1])
PYTHON
    fi
}
trap cleanup EXIT

echo "=== Preparing DMG Build ==="
mkdir -p "$BUILD_DIR"
WORK_DIR="$(mktemp -d "${BUILD_DIR}/.dmg-build.XXXXXX")"
RW_DMG="$WORK_DIR/dmg_rw.dmg"
OUTPUT_DMG="$WORK_DIR/release.dmg"
mkdir "$WORK_DIR/dmg_temp"

if [[ ! -d "$APP_NAME" ]]; then
    echo "ABBRUCH: ${APP_NAME} fehlt. Erst bash build_app.sh ausfuehren." >&2
    exit 1
fi

if codesign --verify --deep --strict "$APP_NAME" >/dev/null 2>&1; then
    echo "=== App signature valid ==="
else
    echo "WARNUNG: App ist nicht gueltig signiert. Notarisierung wird fehlschlagen."
fi

cp -R "${APP_NAME}" "${WORK_DIR}/dmg_temp/"
ln -s /Applications "${WORK_DIR}/dmg_temp/Applications"

sips -s format png -s dpiWidth 72 -s dpiHeight 72 -z 600 600 src/DmgBackground.png --out "${WORK_DIR}/DmgBg_1x.png"
sips -s format png -s dpiWidth 144 -s dpiHeight 144 -z 1200 1200 src/DmgBackground.png --out "${WORK_DIR}/DmgBg_2x.png"
tiffutil -cathidpicheck "${WORK_DIR}/DmgBg_1x.png" "${WORK_DIR}/DmgBg_2x.png" -out "${WORK_DIR}/DmgBackground.tiff"

hdiutil create -size 80m -fs HFS+ -volname "${VOL_NAME}" -ov "$RW_DMG"

echo "=== Mounting DMG ==="
# BEWUSST ohne -mountpoint: Diese Option mountet implizit "nobrowse", und dann
# sieht der Finder das Volume nicht. Der AppleScript-Layoutschritt weiter unten
# scheiterte deshalb reproduzierbar mit "disk ... kann nicht gelesen werden"
# (Fehler -1728) — das DMG bekam nie sein Hintergrundbild und seine
# Icon-Positionen (belegt am 2026-08-23; ohne -mountpoint sieht der Finder
# dasselbe Volume sofort).
#
# Den echten Pfad liefert deshalb die Ausgabe von hdiutil und nicht eine
# Annahme: Ist zufaellig schon ein Volume desselben Namens gemountet, haengt
# macOS eine Nummer an ("Vicious SID Player 1").
hdiutil attach -readwrite -noverify -noautoopen -plist "$RW_DMG" > "$WORK_DIR/attach.plist"
# Nur das gerade angehaengte Geraet gehoert diesem Lauf. Ein gleichnamiges,
# schon vorher gemountetes Volume darf der EXIT-Trap niemals auswerfen.
/usr/bin/python3 - "$WORK_DIR/attach.plist" "$WORK_DIR/mount.txt" <<'PYTHON'
import plistlib, sys
from pathlib import Path
with open(sys.argv[1], 'rb') as stream:
    entities = plistlib.load(stream)['system-entities']
mounted = next(entity for entity in entities if 'mount-point' in entity)
Path(sys.argv[2]).write_text(mounted['dev-entry'] + '\n' + mounted['mount-point'] + '\n')
PYTHON
OWN_DEVICE="$(sed -n '1p' "$WORK_DIR/mount.txt")"
MOUNT_DIR="$(sed -n '2p' "$WORK_DIR/mount.txt")"
if [[ -z "$OWN_DEVICE" || ! -d "$MOUNT_DIR" ]]; then
    echo "ABBRUCH: Der Mountpunkt des Images liess sich nicht bestimmen." >&2
    exit 1
fi
# Der Finder spricht das Volume ueber seinen NAMEN an, und der kann vom
# gewuenschten abweichen (siehe oben).
MOUNTED_VOL_NAME="$(basename "$MOUNT_DIR")"

echo "=== Copying files to DMG ==="
cp -R "${WORK_DIR}/dmg_temp/${APP_NAME}" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

mkdir -p "$MOUNT_DIR/.background"
cp "${WORK_DIR}/DmgBackground.tiff" "$MOUNT_DIR/.background/DmgBackground.tiff"

# Der Finder kennt ein frisch gemountetes Volume nicht sofort. Ohne dieses
# Warten scheiterte der Layoutschritt direkt nach dem Kopieren mit Fehler -1728,
# obwohl das Volume laengst gemountet war (belegt am 2026-08-23).
wait_for_finder_volume() {
    local name="$1" attempt
    for attempt in $(seq 1 15); do
        if osascript -e "tell application \"Finder\" to exists disk \"${name}\"" 2>/dev/null | grep -q true; then
            return 0
        fi
        sleep 1
    done
    return 1
}

if [[ "$FINDER_LAYOUT" == "1" ]] && ! wait_for_finder_volume "$MOUNTED_VOL_NAME"; then
    echo "ABBRUCH: Der Finder sieht das gemountete Volume '$MOUNTED_VOL_NAME' nicht." >&2
    echo "Ohne ihn gibt es kein Icon-Layout und kein Hintergrundbild im DMG." >&2
    echo "Aus einer normalen Terminalsitzung erneut versuchen, oder bewusst ohne" >&2
    echo "Layout bauen: bash build_dmg.sh --no-finder-layout" >&2
    exit 1
fi

if [[ "$FINDER_LAYOUT" == "1" ]]; then
    echo "=== Configuring DMG layout with AppleScript ==="
    osascript <<EOF
tell application "Finder"
    tell disk "${MOUNTED_VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 700, 700}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set background picture of viewOptions to file ".background:DmgBackground.tiff"
        -- Position icons over the slots in the background image
        set position of item "${APP_NAME}" of container window to {180, 360}
        set position of item "Applications" of container window to {420, 360}
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF
else
    echo "=== Skipping Finder layout ==="
fi

echo "=== Unmounting DMG ==="
sleep 2
hdiutil detach "$OWN_DEVICE" || hdiutil detach -force "$OWN_DEVICE"
OWN_DEVICE=""

echo "=== Converting DMG to read-only ==="
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG"
hdiutil verify "$OUTPUT_DMG"

if [[ "$SIGN_DMG" != "0" ]]; then
    echo "=== Signing DMG ==="
    if security find-identity -v -p codesigning | grep -Fq "$CODESIGN_IDENTITY"; then
        codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$OUTPUT_DMG"
        codesign --verify --verbose=2 "$OUTPUT_DMG"
    elif [[ "$SIGN_DMG" == "1" ]]; then
        echo "ABBRUCH: Codesign-Identity nicht gefunden: $CODESIGN_IDENTITY" >&2
        exit 1
    else
        echo "WARNUNG: Codesign-Identity nicht sichtbar. DMG bleibt unsigniert."
    fi
fi

if [[ "$NOTARIZE" == "1" ]]; then
    echo "=== Notarizing DMG ==="
    # Fünf Versuche statt einem: `notarytool history` meldet gelegentlich
    # fälschlich „No Keychain password item found", obwohl das Profil da ist
    # (2026-07-26 auf einem Apple-Silicon-Mac belegt). Ein einzelner Fehlversuch würde sonst einen
    # ganzen Lauf grundlos abbrechen; ein wirklich fehlendes Profil scheitert
    # auch nach fünf Versuchen.
    notary_profile_works() {
        local attempt
        for attempt in 1 2 3 4 5; do
            xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 && return 0
            sleep 3
        done
        return 1
    }
    if ! notary_profile_works; then
        echo "ABBRUCH: Notary-Keychain-Profil nicht gefunden oder nicht nutzbar: $NOTARY_PROFILE" >&2
        echo "Einmal interaktiv anlegen:" >&2
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
        exit 1
    fi
    xcrun notarytool submit "$OUTPUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUTPUT_DMG"
    xcrun stapler validate "$OUTPUT_DMG"
fi

mv "$OUTPUT_DMG" "$FINAL_DMG"
echo "=== DMG build successful: $FINAL_DMG ==="
