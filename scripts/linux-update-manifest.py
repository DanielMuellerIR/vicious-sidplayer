#!/usr/bin/env python3
"""Erzeugt beziehungsweise prüft das Linux-Manifest vor dessen Veröffentlichung."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument("archive", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("--notes", type=Path)
parser.add_argument("--verify", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
version = (root / "VERSION").read_text().strip()
assert re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)
assert args.archive.name == f"vicious-sid-player-{version}-linux-x86_64.tar.gz"
key = (root / "config/sparkle-public-key.txt").read_bytes()
with tarfile.open(args.archive, "r:gz") as archive:
    assert archive.extractfile("vicious-sid-player-linux/VERSION").read().decode().strip() == version
    assert archive.extractfile("vicious-sid-player-linux/update-public-key.txt").read() == key
    assert archive.extractfile("vicious-sid-player-linux/bin/vicious-sid-desktop-engine").read(4) == b"\x7fELF"
    assert archive.getmember("vicious-sid-player-linux/install.py").isfile()
digest = hashlib.sha256()
with args.archive.open("rb") as source:
    for block in iter(lambda: source.read(1048576), b""):
        digest.update(block)
if args.verify:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    data = args.output.read_bytes()
    signature = base64.b64decode(args.output.with_suffix(".json.sig").read_bytes().strip(), validate=True)
    Ed25519PublicKey.from_public_bytes(base64.b64decode(key.strip(), validate=True)).verify(signature, data)
    document = json.loads(data)
    assert document["version"] == version
    assert document["sha256"] == digest.hexdigest()
    assert document["size"] == args.archive.stat().st_size
else:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dict(
        schema=1, product="vicious-sid-player", arch="x86_64", version=version,
        url=f"https://github.com/DanielMuellerIR/vicious-sidplayer/releases/download/v{version}/{args.archive.name}",
        size=args.archive.stat().st_size, sha256=digest.hexdigest(),
        notes=args.notes.read_text()[:12000] if args.notes else "",
    ), ensure_ascii=False, sort_keys=True) + "\n")
