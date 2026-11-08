#!/usr/bin/env bash
# Baut nur. Bei fehlendem Host-Swift kann die vorhandene Docker-Engine bauen.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Linux ]] || { echo 'Dieser Build benötigt Linux.' >&2; exit 1; }
mkdir -p .build/linux build
STAGE="$(mktemp -d "$PWD/.build/linux/app.XXXXXX")"
cleanup() { [[ -z "${STAGE:-}" ]] || rm -rf -- "$STAGE"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if [[ -n "${VICIOUS_ENGINE_BINARY:-}" ]]; then
    ENGINE="$VICIOUS_ENGINE_BINARY"
elif command -v swift >/dev/null; then
    swift build --scratch-path .build/linux/swift -c release --static-swift-stdlib --product vicious-sid-desktop-engine
    ENGINE="$PWD/.build/linux/swift/release/vicious-sid-desktop-engine"
elif command -v docker >/dev/null; then
    docker build -t vicious-sid-gui-builder:6.0 -f linux/Dockerfile linux
    docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/source" vicious-sid-gui-builder:6.0 \
        swift build --scratch-path .build/linux/swift -c release --static-swift-stdlib --product vicious-sid-desktop-engine
    ENGINE="$PWD/.build/linux/swift/release/vicious-sid-desktop-engine"
else
    echo 'Swift 6 oder Docker wird zum Bauen benötigt.' >&2; exit 1
fi
[[ -x "$ENGINE" ]] || { echo 'Audio-Engine fehlt.' >&2; exit 1; }
mkdir -p "$STAGE/bin" "$STAGE/ui" "$STAGE/resources" "$STAGE/licenses"
cp "$ENGINE" "$STAGE/bin/vicious-sid-desktop-engine"
cp -R linux/vicious_sid "$STAGE/ui/"
find "$STAGE/ui" -name __pycache__ -type d -exec rm -rf {} +
cp src/AppIcon.png "$STAGE/resources/"
cp VERSION LICENSE linux/install.py "$STAGE/"
cp config/sparkle-public-key.txt "$STAGE/update-public-key.txt"
cp linux/vicious-sid-player "$STAGE/"
chmod 755 "$STAGE/vicious-sid-player"
python3 linux/bootstrap.py "$STAGE/python"
cp linux/requirements.txt "$STAGE/"
# Qt bleibt dynamisch austauschbar; Quellenhinweise und Lizenztexte liegen bei.
cp linux/licenses/*.txt "$STAGE/licenses/"
cp linux/THIRD_PARTY.md "$STAGE/licenses/"
PYTHONPATH="$STAGE/python:$STAGE/ui" python3 -c 'from vicious_sid.window import PlayerWindow'
DEST="$PWD/build/vicious-sid-player-linux"
BACKUP=""
if [[ -e "$DEST" ]]; then
    BACKUP="$(mktemp -d "$PWD/.build/linux/previous.XXXXXX")"
    mv "$DEST" "$BACKUP/app"
fi
if mv "$STAGE" "$DEST"; then
    STAGE=""
else
    [[ -z "$BACKUP" ]] || mv "$BACKUP/app" "$DEST"
    exit 1
fi
printf 'BUILD OK: %s\n' "$DEST"
