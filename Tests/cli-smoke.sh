#!/bin/bash
# Tests/cli-smoke.sh — prueft den Vertrag des CLI am echten Binary.
#
# WARUM ALS SKRIPT UND NICHT ALS `swift test`
# -------------------------------------------
# Der Kern des CLI-Vertrags sind Exit-Codes und die Aufteilung der beiden
# Ausgabekanaele — beides Eigenschaften des laufenden PROZESSES, nicht einer
# Funktion. Dazu kommt: `vicious-sid` ist ein executableTarget mit Code auf
# oberster Ebene (main.swift). Ein XCTest-Ziel kann so etwas nicht sinnvoll
# importieren, ohne das Paketlayout umzubauen. Also wird hier das gebaute
# Programm gestartet und beobachtet — genau wie ein Nutzer oder ein Skript es
# sieht. Gleiche Bauart wie Tests/fleet-rules.sh und Tests/parity-html5.sh.
#
# Geprueft werden die drei Zusagen aus dem Kopf von main.swift:
#   * Exit 0 = alles gut, 1 = Argument-/Formatfehler, 2 = I/O-Fehler.
#   * stdout gehoert IMMER den Audiodaten; alles Menschenlesbare geht nach stderr.
#   * --wav und --stdout liefern die erwartete Datenmenge.
#
# Aufruf:  bash Tests/cli-smoke.sh
# Exit 0 = alle Pruefungen gruen.
set -uo pipefail
cd "$(dirname "$0")/.."

command -v python3 >/dev/null || { echo "python3 fehlt — Testdatei nicht erzeugbar" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
ok()  { echo "  OK   $1"; }
bad() { echo "  FAIL $1" >&2; fail=1; }

# Startet das CLI und legt stdout/stderr getrennt ab. Setzt $rc.
run() {   # $@ = Argumente
    .build/release/vicious-sid "$@" >"$work/out.bin" 2>"$work/err.txt"
    rc=$?
}

echo "0. Binary bauen"
swift build -c release --product vicious-sid >/dev/null 2>&1 \
    || { echo "  FAIL vicious-sid liess sich nicht bauen" >&2; exit 1; }
ok "vicious-sid gebaut"

# Eine minimale, selbst geschriebene PSID-Datei. Echte SID-Dateien sind
# urheberrechtlich geschuetzt und duerfen im Repo nicht liegen.
python3 - "$work/tune.sid" <<'PY'
import struct, sys
code  = [0xA9, 0x0F, 0x8D, 0x18, 0xD4]   # LDA #$0F / STA $D418  Lautstaerke
code += [0xA9, 0x21, 0x8D, 0x05, 0xD4]   # LDA #$21 / STA $D405  Attack/Decay
code += [0xA9, 0xF0, 0x8D, 0x06, 0xD4]   # LDA #$F0 / STA $D406  Sustain
code += [0xA9, 0x20, 0x8D, 0x01, 0xD4]   # LDA #$20 / STA $D401  Frequenz
code += [0xA9, 0x11, 0x8D, 0x04, 0xD4]   # LDA #$11 / STA $D404  Dreieck + Gate
code += [0x60]                           # RTS
play_off = len(code)
code += [0x60]                           # play: RTS
h = bytearray(0x7C)
h[0:4] = b"PSID"
struct.pack_into(">H", h, 4, 2)
struct.pack_into(">H", h, 6, 0x7C)
struct.pack_into(">H", h, 8, 0x1000)
struct.pack_into(">H", h, 10, 0x1000)
struct.pack_into(">H", h, 12, 0x1000 + play_off)
struct.pack_into(">H", h, 14, 1)
struct.pack_into(">H", h, 16, 1)
h[0x16:0x16 + 9] = b"CLI Smoke"
h[0x77] = 0x20
open(sys.argv[1], "wb").write(bytes(h) + bytes(code))
PY

echo
echo "1. Exit-Codes"

run --help
[ "$rc" -eq 0 ] && ok "--help endet mit 0" || bad "--help endete mit $rc statt 0"
[ ! -s "$work/out.bin" ] && ok "--help schreibt nichts nach stdout" \
    || bad "--help hat stdout beschrieben — dort gehoeren nur Audiodaten hin"
grep -q 'usage' "$work/err.txt" && ok "--help erklaert sich auf stderr" \
    || bad "--help hat keine Hilfe auf stderr geschrieben"

run
[ "$rc" -eq 1 ] && ok "ohne Datei: Exit 1" || bad "ohne Datei kam $rc statt 1"

run --gibtsnicht
[ "$rc" -eq 1 ] && ok "unbekannte Option: Exit 1" || bad "unbekannte Option ergab $rc statt 1"

run "$work/existiert-nicht.sid"
[ "$rc" -eq 2 ] && ok "fehlende Datei: Exit 2 (I/O)" || bad "fehlende Datei ergab $rc statt 2"

head -c 200 /dev/zero > "$work/kaputt.sid"
run "$work/kaputt.sid"
[ "$rc" -eq 1 ] && ok "kaputte Datei: Exit 1 (Formatfehler)" || bad "kaputte Datei ergab $rc statt 1"

run "$work/tune.sid" --subtune 99
[ "$rc" -eq 1 ] && ok "Subtune ausserhalb der Datei: Exit 1" || bad "zu hoher Subtune ergab $rc statt 1"

run "$work/tune.sid" --seconds 0
[ "$rc" -eq 1 ] && ok "--seconds 0: Exit 1" || bad "--seconds 0 ergab $rc statt 1"

run "$work/tune.sid" --wav "$work/x.wav" --stdout
[ "$rc" -eq 1 ] && ok "--wav und --stdout zusammen: Exit 1" || bad "--wav + --stdout ergab $rc statt 1"

echo
echo "2. WAV-Export"

run "$work/tune.sid" --wav "$work/out.wav" --seconds 1
if [ "$rc" -ne 0 ]; then
    bad "WAV-Export endete mit $rc"
else
    # 44 Byte RIFF-Kopf + 1 s * 44100 Frames * 1 Kanal (1 SID) * 2 Byte.
    size=$(wc -c < "$work/out.wav" | tr -d ' ')
    [ "$size" -eq 88244 ] && ok "WAV hat die erwarteten $size Byte" \
        || bad "WAV hat $size Byte, erwartet 88244"
    [ "$(head -c 4 "$work/out.wav")" = "RIFF" ] && ok "WAV beginnt mit RIFF" \
        || bad "WAV hat keinen RIFF-Kopf"
fi

echo
echo "3. Rohes PCM auf stdout"

run "$work/tune.sid" --stdout --seconds 1
if [ "$rc" -ne 0 ]; then
    bad "--stdout endete mit $rc"
else
    # 1 s * 44100 Frames * 2 Kanaele * 2 Byte — die Pipe ist immer stereo.
    size=$(wc -c < "$work/out.bin" | tr -d ' ')
    [ "$size" -eq 176400 ] && ok "stdout traegt die erwarteten $size Byte PCM" \
        || bad "stdout traegt $size Byte, erwartet 176400"
    # Die eigentliche Disziplin-Frage: steht Menschenlesbares im Audiostrom?
    if LC_ALL=C grep -q 'Titel\|Autor\|Ausgabe\|Fertig' "$work/out.bin"; then
        bad "Menschenlesbarer Text ist im PCM-Strom gelandet"
    else
        ok "keine Meldungen im PCM-Strom"
    fi
    grep -q 'Titel:' "$work/err.txt" && ok "Metadaten stehen auf stderr" \
        || bad "Metadaten fehlen auf stderr"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "CLI-Vertrag eingehalten: Exit-Codes, Kanaltrennung und Datenmengen stimmen."
else
    echo "CLI-Vertrag VERLETZT." >&2
fi
exit "$fail"
