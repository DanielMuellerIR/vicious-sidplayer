#!/bin/bash
set -euo pipefail

echo "=== Building Vicious SID Player App in Release Mode ==="
swift build -c release
APP_VERSION="$(cat VERSION)"

echo "=== Creating macOS App Bundle structure ==="
APP_DIR="Vicious SID Player.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-9QSWKSR4NQ}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: Daniel Mueller ($APPLE_TEAM_ID)}"
SIGN_APP="${SIGN_APP:-auto}"

# Recreate the folders
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy release binary
cp ".build/release/ViciousSIDPlayerApp" "$MACOS_DIR/"

echo "=== Assembling Quick Look extension (.appex) ==="
# Die Quick-Look-Preview-Extension spielt .sid-Dateien direkt im Finder ab
# (Leertaste). Sie lebt als eigenes Mini-Bundle unter Contents/PlugIns/ und
# wird vom System ueber die NSExtension-Keys in ihrer Info.plist gefunden.
APPEX_DIR="$CONTENTS_DIR/PlugIns/ViciousSIDQuickLook.appex"
APPEX_CONTENTS="$APPEX_DIR/Contents"
mkdir -p "$APPEX_CONTENTS/MacOS"
cp ".build/release/ViciousSIDQuickLook" "$APPEX_CONTENTS/MacOS/"

cat <<EOF > "$APPEX_CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ViciousSIDQuickLook</string>
    <key>CFBundleIdentifier</key>
    <string>com.viben.ViciousSIDPlayer.QuickLook</string>
    <key>CFBundleName</key>
    <string>SID Quick Look</string>
    <key>CFBundleDisplayName</key>
    <string>Vicious SID Quick Look</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.quicklook.preview</string>
        <key>NSExtensionPrincipalClass</key>
        <string>PreviewViewController</string>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>QLSupportedContentTypes</key>
            <array>
                <string>com.viben.sid-tune</string>
            </array>
            <key>QLSupportsSearchableItems</key>
            <false/>
        </dict>
    </dict>
</dict>
</plist>
EOF

# App-Extensions MUESSEN sandboxed sein, sonst laedt das System sie nicht.
# Lesezugriff auf die previewte Datei gewaehrt Quick Look selbst.
QL_ENTITLEMENTS="$(mktemp -t ql-entitlements).plist"
cat <<EOF > "$QL_ENTITLEMENTS"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
</plist>
EOF

# Compile and copy AppIcon.icns if AppIcon.png exists
if [ -f "src/AppIcon.png" ]; then
    echo "=== Compiling AppIcon.icns ==="
    mkdir -p AppIcon.iconset
    sips -s format png -z 16 16     src/AppIcon.png --out AppIcon.iconset/icon_16x16.png
    sips -s format png -z 32 32     src/AppIcon.png --out AppIcon.iconset/icon_16x16@2x.png
    sips -s format png -z 32 32     src/AppIcon.png --out AppIcon.iconset/icon_32x32.png
    sips -s format png -z 64 64     src/AppIcon.png --out AppIcon.iconset/icon_32x32@2x.png
    sips -s format png -z 128 128   src/AppIcon.png --out AppIcon.iconset/icon_128x128.png
    sips -s format png -z 256 256   src/AppIcon.png --out AppIcon.iconset/icon_128x128@2x.png
    sips -s format png -z 256 256   src/AppIcon.png --out AppIcon.iconset/icon_256x256.png
    sips -s format png -z 512 512   src/AppIcon.png --out AppIcon.iconset/icon_256x256@2x.png
    sips -s format png -z 512 512   src/AppIcon.png --out AppIcon.iconset/icon_512x512.png
    sips -s format png -z 1024 1024 src/AppIcon.png --out AppIcon.iconset/icon_512x512@2x.png
    iconutil -c icns AppIcon.iconset
    cp AppIcon.icns "$RESOURCES_DIR/"
    rm -rf AppIcon.iconset AppIcon.icns
fi

# Create Info.plist
cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ViciousSIDPlayerApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.viben.ViciousSIDPlayer</string>
    <key>CFBundleName</key>
    <string>Vicious SID Player</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Daniel Müller. Lizenz: WTFPL.</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Commodore 64 SID Tune</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>sid</string>
            </array>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.viben.sid-tune</string>
            </array>
            <key>CFBundleTypeIconFile</key>
            <string>AppIcon</string>
        </dict>
    </array>
    <!-- Eigener UTI fuer .sid: darueber findet Quick Look unsere Preview-
         Extension (QLSupportedContentTypes in der appex-Info.plist). -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.viben.sid-tune</string>
            <key>UTTypeDescription</key>
            <string>Commodore 64 SID Tune</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
                <string>public.audio</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>sid</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>audio/prs.sid</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# Hardened Runtime ist Pflicht fuer spaetere Notarisierung.
# --timestamp kontaktiert Apples Zeitstempel-Server, der gelegentlich
# transient mit errSecInternalComponent abbricht -> bis zu 3 Versuche.
sign_with_retry() {
    local sign_attempt=0
    until codesign --force --options runtime --timestamp "$@"; do
        sign_attempt=$((sign_attempt + 1))
        if [[ "$sign_attempt" -ge 3 ]]; then
            echo "ABBRUCH: codesign nach 3 Versuchen fehlgeschlagen." >&2
            exit 1
        fi
        echo "codesign-Versuch $sign_attempt fehlgeschlagen (oft transienter Zeitstempel-Fehler) — neuer Versuch in 5s..." >&2
        sleep 5
    done
}

if [[ "$SIGN_APP" != "0" ]]; then
    echo "=== Checking code signing identity ==="
    if security find-identity -v -p codesigning | grep -Fq "$CODESIGN_IDENTITY"; then
        echo "=== Signing App Bundle ==="
        # Von innen nach aussen signieren: erst die .appex MIT ihren
        # Sandbox-Entitlements, dann die App. (Kein --deep mehr: das wuerde
        # die appex ohne Entitlements neu signieren -> Quick Look laedt sie nicht.)
        sign_with_retry --entitlements "$QL_ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APPEX_DIR"
        sign_with_retry --sign "$CODESIGN_IDENTITY" "$APP_DIR"
        codesign --verify --deep --strict --verbose=2 "$APP_DIR"
    elif [[ "$SIGN_APP" == "1" || "${REQUIRE_CODESIGN:-0}" == "1" ]]; then
        echo "ABBRUCH: Codesign-Identity nicht gefunden: $CODESIGN_IDENTITY" >&2
        echo "Tipp: SIGN_APP=0 bash build_app.sh baut lokal ohne Signatur." >&2
        exit 1
    else
        echo "WARNUNG: Codesign-Identity nicht sichtbar. Ad-hoc-Signatur (nur lokal)."
        # Ad-hoc reicht lokal, damit das System die sandboxed .appex laedt;
        # fuer Releases weiterhin REQUIRE_CODESIGN=1 verwenden.
        codesign --force --options runtime --entitlements "$QL_ENTITLEMENTS" --sign - "$APPEX_DIR"
        codesign --force --options runtime --sign - "$APP_DIR"
    fi
fi
rm -f "$QL_ENTITLEMENTS"

echo "=== App Bundle Created Successfully: $APP_DIR ==="
echo "You can now double-click '$APP_DIR' in Finder to launch the player!"
