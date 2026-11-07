#!/usr/bin/env bash
# Erstellt ein lokales Paket, veröffentlicht und installiert nichts.
set -euo pipefail
cd "$(dirname "$0")/.."
bash linux/build.sh
VERSION="$(cat VERSION)"
OUT="$PWD/build/vicious-sid-player-${VERSION}-linux-$(uname -m).tar.gz"
[[ ! -e "$OUT" ]] || { echo "Paket existiert bereits: $OUT" >&2; exit 1; }
TEMP="$(mktemp "$PWD/.build/linux/release.XXXXXX")"
trap 'rm -f -- "$TEMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
tar -C build --exclude='__pycache__' -czf "$TEMP" vicious-sid-player-linux
mv "$TEMP" "$OUT"
printf 'RELEASE OK: %s\n' "$OUT"
