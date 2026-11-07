#!/usr/bin/env python3
"""Installiert die festgelegte Qt-Laufzeit isoliert, ohne System-Python zu ändern."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request


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
    subprocess.run(
        [
            sys.executable,
            "-c",
            "from PySide6.QtWidgets import QApplication; from PySide6.QtDBus import QDBusConnection",
        ],
        env=dict(os.environ, PYTHONPATH=str(destination)),
        check=True,
    )


if __name__ == "__main__":
    install(sys.argv[1])
