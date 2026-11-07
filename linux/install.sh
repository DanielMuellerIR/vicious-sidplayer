#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --from-build ]]; then
    [[ $# -ge 2 ]] || { echo '--from-build benötigt einen Pfad.' >&2; exit 1; }
    SOURCE="$2"; shift 2
else
    bash linux/build.sh
    SOURCE="$PWD/build/vicious-sid-player-linux"
fi
exec python3 linux/install.py "$SOURCE" "$@"
