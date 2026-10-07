#!/bin/bash
# Tests/parity-html5.sh — prueft die beabsichtigte Paritaet der beiden Engines.
#
# Das Projekt enthaelt die SID-/6502-Emulation ZWEIMAL: einmal in Swift
# (Sources/ViciousSIDPlayerCore/DSP/ViciousProcessor.swift) und einmal in
# JavaScript (sid-player-worklet.js). Beide sind aus jsSID 0.9.1 portiert und
# sollen dasselbe rechnen. Bisher gab es dafuer keinen Beleg — und genau deshalb
# war eine Abweichung im Puls-Pfad ueber Monate unbemerkt: Die Swift-Seite
# spiegelte die Pulsbreiten-Obergrenze aus dem ungeschobenen statt dem um 9 Bit
# geschobenen accuadd und ersetzte die ideale Rechteckflanke langsamer
# Oszillatoren durch die weichste moegliche (CodeQA 2026-08-15).
#
# So laeuft der Vergleich:
#   1. Eine synthetische PSID-Datei bauen. Selbst geschrieben, winzig, keinerlei
#      fremdes Material — echte SID-Dateien sind urheberrechtlich geschuetzt und
#      duerfen im Repo nicht liegen.
#   2. Sie mit beiden Engines rendern: die Swift-Seite ueber `sidcheck --wav`,
#      die JS-Seite ueber node.
#   3. Beide 16-Bit-PCM-Stroeme Sample fuer Sample vergleichen.
#
# Warum eine eigene Datei und kein `swift test`: Der Vergleich braucht node und
# damit eine Laufzeit, die die Swift-Testsuite bewusst nicht voraussetzt — wie
# schon bei Tests/fleet-rules.sh liegt die Pruefung deshalb als eigenes Skript
# daneben.
#
# Aufruf:  bash Tests/parity-html5.sh
# Exit 0 = beide Engines liefern bitgenau dasselbe.
# Exit 2 = node oder python3 fehlt (Pruefung nicht durchgefuehrt, NICHT gruen).
set -uo pipefail
cd "$(dirname "$0")/.."

command -v node    >/dev/null || { echo "node fehlt — Paritaetstest nicht durchfuehrbar" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 fehlt — Paritaetstest nicht durchfuehrbar" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

SECONDS_TO_RENDER=2
SID_MODEL="${PARITY_SID_MODEL:-8580}"
case "$SID_MODEL" in 6581|8580) ;; *) echo "PARITY_SID_MODEL muss 6581 oder 8580 sein" >&2; exit 2 ;; esac

# --- 1. Synthetische Testdatei ------------------------------------------------
# Die 6502-Routine schaltet Stimme 1 auf PULS mit maximaler Pulsbreite und laesst
# die Frequenz Frame fuer Frame steigen. Das ist Absicht: Der Puls-Pfad rechnet
# unterhalb und oberhalb von accuadd = 0x10000 unterschiedlich, eine steigende
# Frequenz laeuft also durch beide Faelle.
python3 - "$work/parity.sid" "$SID_MODEL" <<'PY'
import struct, sys

LOAD = 0x1000
code  = [0xA9, 0x0F, 0x8D, 0x18, 0xD4]   # LDA #$0F / STA $D418  Lautstaerke 15
code += [0xA9, 0x00, 0x8D, 0x05, 0xD4]   # LDA #$00 / STA $D405  Attack/Decay 0
code += [0xA9, 0xF0, 0x8D, 0x06, 0xD4]   # LDA #$F0 / STA $D406  Sustain 15, Release 0
code += [0xA9, 0xFF, 0x8D, 0x02, 0xD4]   # LDA #$FF / STA $D402  Pulsbreite, unteres Byte
code += [0xA9, 0x0F, 0x8D, 0x03, 0xD4]   # LDA #$0F / STA $D403  Pulsbreite, oberes Byte -> 4095 (max)
code += [0xA9, 0x00, 0x8D, 0x00, 0xD4]   # LDA #$00 / STA $D400  Frequenz, unteres Byte
code += [0xA9, 0x10, 0x8D, 0x01, 0xD4]   # LDA #$10 / STA $D401  Frequenz, oberes Byte
code += [0xA9, 0x41, 0x8D, 0x04, 0xD4]   # LDA #$41 / STA $D404  Waveform PULS + Gate
code += [0x60]                           # RTS
play_off = len(code)
code += [0xE6, 0xFB]                     # INC $FB               Zaehler in der Zero Page
code += [0xA5, 0xFB, 0x8D, 0x01, 0xD4]   # LDA $FB / STA $D401   Frequenz steigt je Frame
code += [0x60]                           # RTS

h = bytearray(0x7C)
h[0:4] = b"PSID"
struct.pack_into(">H", h, 4, 2)                 # Version 2
struct.pack_into(">H", h, 6, 0x7C)              # Datenblock beginnt bei 0x7C
struct.pack_into(">H", h, 8, LOAD)              # Ladeadresse steht im Header …
struct.pack_into(">H", h, 10, LOAD)             # init
struct.pack_into(">H", h, 12, LOAD + play_off)  # play
struct.pack_into(">H", h, 14, 1)                # ein Subtune
struct.pack_into(">H", h, 16, 1)                # Startsong (1-basiert)
h[0x16:0x16 + 12] = b"Pulse Parity"
h[0x77] = 0x10 if sys.argv[2] == '6581' else 0x20
# … deshalb folgt das Binary direkt, ohne die sonst ueblichen zwei Adressbytes.
open(sys.argv[1], "wb").write(bytes(h) + bytes(code))
PY

# --- 2a. Swift-Seite ----------------------------------------------------------
echo "1. Swift-Engine rendern"
swift build -c release --product sidcheck >/dev/null 2>&1 || {
    echo "  FAIL sidcheck liess sich nicht bauen" >&2; exit 1; }
.build/release/sidcheck "$work/parity.sid" --wav "$work/swift.wav" "$SECONDS_TO_RENDER" 0 >/dev/null || {
    echo "  FAIL sidcheck konnte nicht rendern" >&2; exit 1; }
echo "  OK   $work/swift.wav"

# --- 2b. JS-Seite -------------------------------------------------------------
echo "2. HTML5-Engine rendern"
node - "$PWD/sid-player-worklet.js" "$work/parity.sid" "$work/js.pcm" "$SECONDS_TO_RENDER" <<'JS' || exit 1
// Die Engine-Klasse SidPlayerProcessor ist bewusst KEIN AudioWorkletProcessor
// (siehe Kommentar in sid-player-worklet.js) und laesst sich deshalb hier normal
// erzeugen. Alles ab "class SidPlayerWorklet" braucht echte Browser-Klassen und
// bleibt draussen. Die Engine liest die Worklet-Globale `sampleRate`, die wir ihr
// als Funktionsparameter unterschieben.
const fs = require('fs');
const [ , , workletPath, sidPath, outPath, secondsArg ] = process.argv;
const src = fs.readFileSync(workletPath, 'utf8');
const engineSrc = src.slice(0, src.indexOf('class SidPlayerWorklet'));
const SidPlayerProcessor = new Function('sampleRate', engineSrc + '; return SidPlayerProcessor;')(44100);

const engine = new SidPlayerProcessor();
engine.loadSID(new Uint8Array(fs.readFileSync(sidPath)));
engine.initSubtune(0);
engine.setVolume(1.0);

// Gleiche Quantisierung wie WavRenderer.pcm16 auf der Swift-Seite: hart auf
// -1..1 geklemmt, mal 32767, zur Null hin abgeschnitten, 16 Bit little-endian.
const count = Math.round(parseFloat(secondsArg) * 44100);
const pcm = Buffer.alloc(count * 2);
for (let i = 0; i < count; i++) {
  const s = Math.max(-1, Math.min(1, engine.playSample()));
  pcm.writeInt16LE(Math.trunc(s * 32767), i * 2);
}
fs.writeFileSync(outPath, pcm);
JS
echo "  OK   $work/js.pcm"

# --- 3. Vergleich -------------------------------------------------------------
echo "3. Sample-fuer-Sample vergleichen"
python3 - "$work/js.pcm" "$work/swift.wav" "$SECONDS_TO_RENDER" <<'PY'
import struct, sys
js  = open(sys.argv[1], "rb").read()
wav = open(sys.argv[2], "rb").read()[44:]   # 44-Byte-RIFF-Header ueberspringen
# Beide Seiten muessen GENAU die erwartete Menge liefern. Vorher verglich der
# Test nur das gemeinsame Praefix (`min(len(js), len(wav))`): Eine Engine
# konnte ihre Ausgabe verkuerzen, und der Test meldete sie bei identischem
# Rest trotzdem als „bitgenau identisch" (Review-Fund 2026-08-17).
erwartet = int(round(float(sys.argv[3]) * 44100)) * 2   # Samples * 2 Byte, mono
if len(js) != erwartet or len(wav) != erwartet:
    print(f"  FAIL Laengen weichen ab: html5={len(js)} B, swift={len(wav)} B, "
          f"erwartet je {erwartet} B", file=sys.stderr)
    sys.exit(1)
n = erwartet // 2
if n == 0:
    print("  FAIL keine Samples gerendert", file=sys.stderr); sys.exit(1)
a = struct.unpack(f"<{n}h", js[:n * 2])
b = struct.unpack(f"<{n}h", wav[:n * 2])
diff = [(i, x, y) for i, (x, y) in enumerate(zip(a, b)) if x != y]
if diff:
    worst = max(abs(x - y) for _, x, y in diff)
    print(f"  FAIL {len(diff)} von {n} Samples weichen ab "
          f"(groesste Abweichung {worst} bei Vollausschlag 32767)", file=sys.stderr)
    for i, x, y in diff[:5]:
        print(f"       Sample {i} ({i/44100.0:.4f} s): html5={x} swift={y}", file=sys.stderr)
    sys.exit(1)
print(f"  OK   {n} Samples bitgenau identisch")
PY
rc=$?

echo
if [ "$rc" -eq 0 ]; then
    echo "Paritaet belegt: Swift- und HTML5-Engine rechnen bitgenau dasselbe."
else
    echo "Paritaet VERLETZT — eine der beiden Engines wurde einseitig geaendert." >&2
fi
exit "$rc"
