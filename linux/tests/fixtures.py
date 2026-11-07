"""Eigene kurze 6502-Routine; keine fremden SID-Musikdateien."""

from pathlib import Path
import struct


def write_sid(destination, chips=1, title="Synthetic SID Reference"):
    header = bytearray(0x7C)
    header[:4] = b"PSID"
    code = bytearray()
    for chip in range(chips):
        base = 0xD400 + chip * 0x20
        for register, value in [
            (0x18, 15),
            (5, 0x21),
            (6, 0xF0),
            (0, 0),
            (1, 0x20 + chip * 4),
            (4, 0x11),
        ]:
            code += bytes(
                [0xA9, value, 0x8D, (base + register) & 255, (base + register) >> 8]
            )
    code += b"\x60"
    play = 0x1000 + len(code)
    code += bytes([0xE6, 0xFB, 0xA5, 0xFB, 0x8D, 1, 0xD4, 0x60])
    for offset, value in [
        (4, 4 if chips > 1 else 2),
        (6, 0x7C),
        (8, 0x1000),
        (10, 0x1000),
        (12, play),
        (14, 3),
        (16, 1),
        (0x76, 0x14),
    ]:
        struct.pack_into(">H", header, offset, value)
    if chips > 1:
        header[0x7A] = 0x42
    if chips > 2:
        header[0x7B] = 0x44
    for offset, text in [
        (0x16, title),
        (0x36, "Vicious SID Player"),
        (0x56, "Test fixture"),
    ]:
        header[offset : offset + len(text)] = text.encode("cp1252")
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(header + code)
    return destination
