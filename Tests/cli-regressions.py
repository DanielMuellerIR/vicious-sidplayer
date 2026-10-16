#!/usr/bin/env python3
"""Synthetische Eingaben, eigene PTYs und begrenzte Kindprozesse."""
import os
from pathlib import Path
import pty
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

cli = Path(sys.argv[1]).resolve()
checker = Path(sys.argv[2]).resolve()
with tempfile.TemporaryDirectory(prefix='vicious-cli-regressions-') as temporary:
    root = Path(temporary)
    data = bytearray(0x7C)
    data[:4] = b'PSID'
    for offset, value in [(4, 2), (6, 0x7C), (8, 0x1000), (10, 0x1000), (12, 0x1001), (14, 1), (16, 1)]:
        struct.pack_into('>H', data, offset, value)
    sid = root / 'fixture.sid'
    sid.write_bytes(data + b'\x60\x60')
    invalid_clock = subprocess.run([cli, sid, '--clock', 'invalid'], capture_output=True, timeout=5)
    assert invalid_clock.returncode == 1
    tone = bytes([0xA9,15,0x8D,0x18,0xD4,0xA9,0,0x8D,5,0xD4,
                  0xA9,0xF0,0x8D,6,0xD4,0xA9,0x20,0x8D,1,0xD4,
                  0xA9,0x11,0x8D,4,0xD4,0x60,0x60])
    tone_header = bytearray(data)
    struct.pack_into('>H', tone_header, 12, 0x1000 + len(tone) - 1)
    tone_file = root / 'tone.sid'
    tone_file.write_bytes(tone_header + tone)
    outputs = []
    for clock in ['pal', 'ntsc']:
        wav = root / f'{clock}.wav'
        result = subprocess.run([cli, tone_file, '--clock', clock, '--wav', wav, '--seconds', '1'], capture_output=True, timeout=5)
        assert result.returncode == 0, result.stderr.decode()
        outputs.append(wav.read_bytes()[44:])
    assert outputs[0] != outputs[1], 'CLI-Taktwahl erreicht den Renderer nicht'
    for value in ['nan', 'inf', '-1', 'invalid', '3601']:
        result = subprocess.run([checker, sid, '--dump', root / 'dump.json', value], capture_output=True, timeout=5)
        assert result.returncode == 2, (value, result.returncode)
    for number in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]:
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        child = subprocess.Popen([cli, sid, '--stdout'], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while termios.tcgetattr(slave)[3] & termios.ICANON:
                assert time.monotonic() < deadline, 'Rohmodus wurde nicht betreten'
                time.sleep(0.02)
            # Niemand liest stdout: Die Pipe wird voll, Stop muss trotzdem wirken.
            time.sleep(0.2)
            child.send_signal(number)
            assert child.wait(timeout=3) == 0
            assert termios.tcgetattr(slave) == original, f'Terminal nach Signal {number} nicht restauriert'
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            child.stdout.close()
            os.close(master)
            os.close(slave)
print('CLI-Regressionen: Dauerfehler und drei externe Signale samt voller Pipe bestanden.')
