#!/usr/bin/env python3
"""Installiert die festgelegte Qt-Laufzeit isoliert, ohne System-Python zu ändern."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request
import io
import zipfile


def portable_crypto(destination, cache):
    # Qt nutzt abi3, CFFI dagegen eine Erweiterung je Python-Minorversion.
    # Der auf Python 3.12 gebaute Download muss auch auf 3.10–3.15 laufen.
    def wheel(package, package_version, filename):
        metadata = json.load(urllib.request.urlopen(
            f"https://pypi.org/pypi/{package}/{package_version}/json", timeout=30))
        item = next(item for item in metadata["urls"] if item["filename"] == filename)
        cached = cache / filename
        if not cached.exists() or hashlib.sha256(cached.read_bytes()).hexdigest() != item["digests"]["sha256"]:
            content = urllib.request.urlopen(item["url"], timeout=60).read()
            if hashlib.sha256(content).hexdigest() != item["digests"]["sha256"]:
                raise RuntimeError("Prüfsumme der Update-Laufzeit stimmt nicht.")
            cached.write_bytes(content)
        return zipfile.ZipFile(io.BytesIO(cached.read_bytes()))

    with wheel("cryptography", "50.0.2", "cryptography-50.0.2-cp39-abi3-manylinux_2_34_x86_64.whl") as archive:
        for name in archive.namelist():
            if name.startswith(("cryptography/", "cryptography-50.0.2.dist-info/")) and not name.endswith("/"):
                parts = Path(name).parts
                if ".." in parts:
                    raise RuntimeError("Ungültiger Laufzeitpfad.")
                target = destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))
    for minor in range(10, 16):
        abi = f"cp3{minor}"
        name = f"cffi-2.1.1-{abi}-{abi}-manylinux2014_x86_64.manylinux_2_17_x86_64.whl"
        with wheel("cffi", "2.1.1", name) as archive:
            extension = next(name for name in archive.namelist()
                             if name.startswith(f"_cffi_backend.cpython-3{minor}-")
                             and "/" not in name and name.endswith(".so"))
            (destination / extension).write_bytes(archive.read(extension))


def install(destination):
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    cache = (
        Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
        / "vicious-sid-player"
    )
    cache.mkdir(parents=True, exist_ok=True)
    metadata = json.load(
        urllib.request.urlopen("https://pypi.org/pypi/pip/26.3/json", timeout=30)
    )
    wheel = next(item for item in metadata["urls"] if item["filename"].endswith(".whl"))
    target = cache / wheel["filename"]
    if (
        not target.exists()
        or hashlib.sha256(target.read_bytes()).hexdigest() != wheel["digests"]["sha256"]
    ):
        data = urllib.request.urlopen(wheel["url"], timeout=60).read()
        if hashlib.sha256(data).hexdigest() != wheel["digests"]["sha256"]:
            raise RuntimeError("Prüfsumme des Python-Installers stimmt nicht.")
        target.write_bytes(data)
    env = dict(os.environ, PYTHONPATH=str(target), PIP_DISABLE_PIP_VERSION_CHECK="1")
    subprocess.run(
        [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--only-binary=:all:",
            "--target",
            str(destination),
            "-r",
            str(Path(__file__).with_name("requirements.txt")),
        ],
        env=env,
        check=True,
    )
    portable_crypto(destination, cache)
    subprocess.run(
        [
            sys.executable,
            "-c",
            "from PySide6.QtWidgets import QApplication; from PySide6.QtDBus import QDBusConnection; from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey; import _cffi_backend",
        ],
        env=dict(os.environ, PYTHONPATH=str(destination)),
        check=True,
    )


if __name__ == "__main__":
    install(sys.argv[1])
