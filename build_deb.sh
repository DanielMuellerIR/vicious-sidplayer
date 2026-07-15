#!/usr/bin/env bash
# ============================================================================
# build_deb.sh — baut ein .deb-Paket des Linux-CLI-Players.
#
# WARUM .deb und nicht AppImage
# -----------------------------
# AppImage buendelt GUI-Anwendungen samt Bibliotheken in eine Datei. Wir haben
# aber ein Kommandozeilenprogramm, und mit --static-swift-stdlib haengt es
# ohnehin nur noch an System-Bibliotheken. Fuer ein CLI ist ein AppImage sogar
# unpraktisch: es braucht FUSE, gehoert schlecht in $PATH und ist in einer Pipe
# sperrig. Ein .deb legt das Binary dorthin, wo es hingehoert, bringt die
# Dateizuordnung mit und laesst sich sauber wieder deinstallieren.
#
# WAS HINEINKOMMT
#   /usr/bin/vicious-sid                                    das Binary
#   /usr/share/applications/vicious-sid.desktop             Dateizuordnung
#   /usr/share/icons/hicolor/256x256/apps/vicious-sid.png   Icon
#   /usr/share/doc/vicious-sid/copyright                    Lizenz
#
# Der MIME-Typ audio/prs.sid wird bewusst NICHT mitgeliefert: shared-mime-info
# kennt ihn systemweit bereits (audio/prs.sid:*.sid). Eigene Regeln waeren
# Ballast, der irgendwann mit dem System auseinanderlaeuft.
#
# AUFRUF
#   ./build_deb.sh                  baut fuer die aktuelle Architektur
#   ./build_deb.sh --skip-build     nutzt ein schon vorhandenes Release-Binary
#
# Das Skript laeuft NUR auf Linux — es braucht den Swift-Compiler mit den
# ALSA-/D-Bus-Headern und dpkg-deb. Auf dem Mac bricht es mit Hinweis ab.
# ============================================================================
set -euo pipefail

cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
PKG_NAME="vicious-sid"
# Oeffentliche Autorenangabe: bewusst die GitHub-noreply-Adresse, die ohnehin in
# jedem Commit dieses Repos steht — in einem Paket, das weitergegeben wird, hat
# eine private Adresse nichts verloren.
MAINTAINER="DanielMuellerIR <62342041+DanielMuellerIR@users.noreply.github.com>"

SKIP_BUILD=0
[ "${1:-}" = "--skip-build" ] && SKIP_BUILD=1

# --- Vorbedingungen ---------------------------------------------------------

if [ "$(uname -s)" != "Linux" ]; then
    echo "Fehler: build_deb.sh baut ein Linux-Paket und laeuft nur auf Linux." >&2
    echo "Auf dem Mac: das Repo auf einen Linux-Rechner spiegeln und dort bauen." >&2
    exit 1
fi

for tool in dpkg-deb swift; do
    command -v "$tool" >/dev/null || { echo "Fehler: '$tool' fehlt." >&2; exit 1; }
done

# dpkg nennt x86_64 "amd64" und aarch64 "arm64" — die Debian-Namen, nicht die
# von uname. dpkg selbst weiss es am besten, also fragen wir es.
ARCH="$(dpkg --print-architecture)"

# --- Binary bauen -----------------------------------------------------------

BIN=".build/release/vicious-sid"
if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "==> Baue vicious-sid (release, statische Swift-Laufzeit) …"
    # --static-swift-stdlib bindet die Swift-Laufzeit ein. Das Paket haengt dann
    # nur noch an System-Bibliotheken, die auf jedem Debian/Ubuntu da sind —
    # sonst muesste der Nutzer erst eine Swift-Toolchain installieren.
    swift build -c release --product vicious-sid --static-swift-stdlib
fi
[ -f "$BIN" ] || { echo "Fehler: '$BIN' nicht gefunden." >&2; exit 1; }

# --- Paketbaum zusammenstellen ---------------------------------------------

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

install -Dm755 "$BIN"                                 "$STAGE/usr/bin/$PKG_NAME"
install -Dm644 packaging/linux/$PKG_NAME.desktop      "$STAGE/usr/share/applications/$PKG_NAME.desktop"
install -Dm644 LICENSE                                "$STAGE/usr/share/doc/$PKG_NAME/copyright"

# Icon: das App-Icon liegt als 1024er-PNG vor. hicolor erwartet die Datei im
# Ordner ihrer tatsaechlichen Kantenlaenge — deshalb skalieren, wenn ein
# Werkzeug da ist, sonst die 1024er-Variante als 256er einsortieren (falsch
# einsortierte Groessen sind haesslich, aber nicht kaputt).
ICON_DIR="$STAGE/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$ICON_DIR"
if command -v convert >/dev/null; then
    convert src/AppIcon.png -resize 256x256 "$ICON_DIR/$PKG_NAME.png"
else
    echo "    Hinweis: ImageMagick fehlt — Icon wird ungeskaliert uebernommen."
    cp src/AppIcon.png "$ICON_DIR/$PKG_NAME.png"
fi
chmod 644 "$ICON_DIR/$PKG_NAME.png"

# --- Steuerdatei ------------------------------------------------------------

# Abhaengigkeiten: libasound2 fuer die Audioausgabe (das Binary linkt immer
# dagegen, auch beim WAV-Export), libdbus-1-3 fuer MPRIS2. Beides gehoert auf
# jedem Desktop-System zur Grundausstattung. Die Swift-Laufzeit steht hier
# NICHT, weil sie statisch eingebunden ist.
INSTALLED_KB="$(du -sk "$STAGE" | cut -f1)"
mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $VERSION
Section: sound
Priority: optional
Architecture: $ARCH
Depends: libasound2, libdbus-1-3
Installed-Size: $INSTALLED_KB
Maintainer: $MAINTAINER
Homepage: https://github.com/DanielMuellerIR/vicious-sidplayer
Description: Commodore 64 SID music player for the command line
 Plays .sid tunes from the Commodore 64 through a cycle-accurate emulation of
 the MOS 6581/8580 sound chip and the 6502 CPU.
 .
 Real-time playback via ALSA (and therefore PipeWire and PulseAudio), faster
 than real-time WAV export, raw PCM to stdout for pipes, subtune navigation and
 keyboard control. Registers with MPRIS2, so media keys and the desktop sound
 applet can control it.
 .
 No SID tunes are included; point it at your own collection.
EOF

# --- Bauen ------------------------------------------------------------------

OUT="${PKG_NAME}_${VERSION}_${ARCH}.deb"
# --root-owner-group: alle Dateien gehoeren im Paket root, ohne dass wir das
# Skript selbst als root oder unter fakeroot laufen lassen muessten.
dpkg-deb --build --root-owner-group "$STAGE" "$OUT" >/dev/null

echo
echo "==> Fertig: $OUT"
dpkg-deb --info "$OUT" | sed -n '2,6p'
echo
echo "    Installieren:    sudo apt install ./$OUT"
echo "    Deinstallieren:  sudo apt remove $PKG_NAME"
