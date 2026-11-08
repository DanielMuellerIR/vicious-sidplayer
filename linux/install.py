#!/usr/bin/env python3
"""Benutzerinstallation mit unveränderlichen Versionen und atomarem Zeigerwechsel."""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile


def install(source, prefix):
    source = source.resolve()
    prefix = prefix.resolve()
    if prefix in (Path("/"), Path.home()):
        raise ValueError("Ein eigener Installationspräfix ist erforderlich.")
    for name in [
        "vicious-sid-player",
        "bin/vicious-sid-desktop-engine",
        "VERSION",
        "ui/vicious_sid/app.py",
    ]:
        if not (source / name).is_file():
            raise ValueError(f"Unvollständiger Build: {name}")
    if (source / "bin/vicious-sid-desktop-engine").read_bytes()[:4] != b"\x7fELF":
        raise ValueError("Die Audio-Engine ist kein Linux-Binary.")
    # Vor dem Aktivieren importieren; die neue Fassung darf eine funktionierende
    # Installation bei fehlenden Bibliotheken nicht verdrängen.
    env = dict(
        os.environ,
        PYTHONPATH=str(source / "python") + ":" + str(source / "ui"),
        PYTHONDONTWRITEBYTECODE="1",
    )
    subprocess.run(
        [
            "python3",
            "-c",
            "from vicious_sid.window import PlayerWindow; from PySide6.QtDBus import QDBusConnection; from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey",
        ],
        env=env,
        check=True,
    )
    digest = hashlib.sha256()
    for file in sorted(source.rglob("*")):
        if file.is_file() and "__pycache__" not in file.parts:
            digest.update(str(file.relative_to(source)).encode())
            digest.update(file.read_bytes())
    version = (source / "VERSION").read_text().strip()
    root = prefix / "share/vicious-sid-player"
    if root.is_relative_to(source):
        raise ValueError("Das Installationsziel darf nicht im Build liegen.")
    versions = root / "versions"
    versions.mkdir(parents=True, exist_ok=True)
    target = versions / f"{version}-{digest.hexdigest()[:12]}"
    if not target.exists():
        stage = Path(tempfile.mkdtemp(prefix=".install-", dir=versions))
        try:
            shutil.copytree(
                source,
                stage,
                dirs_exist_ok=True,
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
            )
            stage.rename(target)
        finally:
            if stage.exists():
                shutil.rmtree(stage)
    current = root / "current"
    if current.exists() and not current.is_symlink():
        raise ValueError("Der aktuelle Installationspfad ist kein Versionszeiger.")
    snapshots = []

    def remember(destination):
        if destination.is_symlink():
            snapshots.append((destination, "link", os.readlink(destination)))
        elif destination.is_file():
            snapshots.append((destination, "file", destination.read_bytes()))
        elif destination.exists():
            raise ValueError(f"Kein ersetzbarer App-Pfad: {destination}")
        else:
            snapshots.append((destination, "absent", None))

    def put_link(destination, value):
        remember(destination)
        pending = destination.with_name("." + destination.name + "-" + str(os.getpid()))
        try:
            pending.symlink_to(value)
            os.replace(pending, destination)
        finally:
            if pending.is_symlink():
                pending.unlink()

    def put_file(destination, data):
        remember(destination)
        descriptor, temporary = tempfile.mkstemp(
            prefix="." + destination.name + "-", dir=destination.parent
        )
        try:
            with os.fdopen(descriptor, "wb") as file:
                file.write(data)
            os.replace(temporary, destination)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    try:
        binary_dir = prefix / "bin"
        binary_dir.mkdir(parents=True, exist_ok=True)
        launcher = binary_dir / "vicious-sid-player"
        if launcher.exists() and not launcher.is_symlink():
            raise ValueError(
                "Ein vorhandener fremder Starter wird nicht überschrieben."
            )
        put_link(current, target.relative_to(root))
        put_link(launcher, current / "vicious-sid-player")
        applications = prefix / "share/applications"
        applications.mkdir(parents=True, exist_ok=True)
        icons = prefix / "share/icons/hicolor/1024x1024/apps"
        icons.mkdir(parents=True, exist_ok=True)
        put_file(
            icons / "vicious-sid-player.png",
            (target / "resources/AppIcon.png").read_bytes(),
        )
        executable = (
            str(launcher)
            .replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("`", "\\`")
            .replace("$", "\\$")
        )
        desktop = f'''[Desktop Entry]
Type=Application
Name=Vicious SID Player
Comment=Commodore 64 SID music player
Exec="{executable}" %U
Icon=vicious-sid-player
Terminal=false
Categories=AudioVideo;Audio;Player;
MimeType=audio/prs.sid;x-scheme-handler/vicioussid;
StartupNotify=true
'''
        put_file(applications / "vicious-sid-player.desktop", desktop.encode())
        if shutil.which("update-desktop-database"):
            subprocess.run(["update-desktop-database", str(applications)], check=True)
    except BaseException:
        for destination, kind, value in reversed(snapshots):
            if destination.is_symlink() or destination.is_file():
                destination.unlink()
            if kind == "link":
                destination.symlink_to(value)
            elif kind == "file":
                destination.write_bytes(value)
        raise
    print(f"INSTALL OK: {prefix / 'bin/vicious-sid-player'} ({version})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--prefix", type=Path, default=Path.home() / ".local")
    args = parser.parse_args()

    def interrupted(number, frame):
        raise SystemExit(128 + number)

    for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(number, interrupted)
    install(args.source, args.prefix)
