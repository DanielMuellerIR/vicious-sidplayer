#!/usr/bin/env python3
"""Dateidialog, installierbarer Starter, Datei-URIs und einzelne App-Instanz."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time
from PySide6.QtCore import Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QDialogButtonBox, QFileDialog, QLineEdit
from vicious_sid.bridge import Engine
from vicious_sid.window import PlayerWindow
from fixtures import write_sid

parser = argparse.ArgumentParser()
parser.add_argument("app")
parser.add_argument("evidence")
parser.add_argument("--launcher", type=Path)
args = parser.parse_args()
base = Path(args.app).resolve()
evidence = Path(args.evidence).resolve()
evidence.mkdir(parents=True, exist_ok=True)
app = QApplication([])
app.setStyle("Fusion")
app.setQuitOnLastWindowClosed(False)


def wait(condition, message, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        app.processEvents()
        QTest.qWait(20)
        if condition():
            return
    raise AssertionError(message)


def call(method, *values):
    result = subprocess.run(
        [
            "gdbus",
            "call",
            "--session",
            "--dest",
            "org.mpris.MediaPlayer2.vicioussid",
            "--object-path",
            "/org/mpris/MediaPlayer2",
            "--method",
            method,
            *values,
        ],
        capture_output=True,
        text=True,
        timeout=2,
    )
    return result.stdout if result.returncode == 0 else ""


with tempfile.TemporaryDirectory(prefix="vicious-desktop-shell-") as directory:
    temporary = Path(directory)
    root = temporary / "Music"
    write_sid(root / "First.sid", title="Shell first")
    opened = write_sid(temporary / "Opened.sid", title="Opened from file dialog")
    engine = Engine(
        base / "bin/vicious-sid-desktop-engine",
        ["--support-dir", str(temporary / "InlineSupport"), "--root", str(root)],
    )
    window = PlayerWindow(
        engine, base / "resources", (base / "VERSION").read_text().strip()
    )
    window.show()
    errors = []
    engine.failed.connect(errors.append)
    seen = []
    try:
        wait(lambda: window.state.get("state") == "Playing", "Initialer Titel")

        def accept_file():
            dialog = next(
                (
                    widget
                    for widget in app.topLevelWidgets()
                    if isinstance(widget, QFileDialog) and widget.isVisible()
                ),
                None,
            )
            if dialog is None:
                QTimer.singleShot(50, accept_file)
                return
            field = dialog.findChild(QLineEdit, "fileNameEdit")
            box = dialog.findChild(QDialogButtonBox)
            if field is None or box is None:
                dialog.reject()
                return
            dialog.setDirectory(str(opened.parent))
            QTest.qWait(80)
            field.setFocus()
            field.selectAll()
            QTest.keyClicks(field, opened.name)
            assert dialog.selectedFiles() == [str(opened)], dialog.selectedFiles()
            dialog.grab().save(str(evidence / "linux-file-dialog.png"))
            button = next(
                (
                    button
                    for button in box.buttons()
                    if box.buttonRole(button) == QDialogButtonBox.ButtonRole.AcceptRole
                ),
                None,
            )
            if button and button.isEnabled():
                seen.append(True)
                QTest.mouseClick(button, Qt.MouseButton.LeftButton)
            else:
                dialog.reject()

        deadline = QTimer()
        deadline.setSingleShot(True)
        deadline.timeout.connect(
            lambda: [
                widget.reject()
                for widget in app.topLevelWidgets()
                if isinstance(widget, QFileDialog)
            ]
        )
        deadline.start(5000)
        QTimer.singleShot(100, accept_file)
        window.open_files()
        deadline.stop()
        assert seen, "Dateidialog war nicht bedienbar"
        wait(
            lambda: window.state.get("title") == "Opened from file dialog",
            "Dateidialog erreicht Engine",
        )
        assert not errors, errors
    except Exception:
        print(
            json.dumps(
                dict(
                    state=window.state,
                    errors=errors,
                    stderr=engine.stderr.decode(errors="replace"),
                ),
                ensure_ascii=False,
            ),
            flush=True,
        )
        raise
    finally:
        window.close()
        engine.close()
    support = temporary / "StandaloneSupport"
    launcher = args.launcher or base / "vicious-sid-player"
    process = subprocess.Popen(
        [str(launcher), "--support-dir", str(support), "--root", str(root)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        wait(
            lambda: (
                "Shell first"
                in call(
                    "org.freedesktop.DBus.Properties.Get",
                    "org.mpris.MediaPlayer2.Player",
                    "Metadata",
                )
            ),
            "Standalone-App und MPRIS",
        )

        def child_engine():
            children = (
                Path(f"/proc/{process.pid}/task/{process.pid}/children")
                .read_text()
                .split()
            )
            return [
                pid
                for pid in children
                if b"vicious-sid-desktop-engine"
                in Path(f"/proc/{pid}/cmdline").read_bytes()
            ]

        before = child_engine()
        assert len(before) == 1
        result = subprocess.run(
            [str(launcher), "--support-dir", str(support), opened.as_uri()],
            capture_output=True,
            timeout=8,
        )
        assert result.returncode == 0, result.stderr.decode()
        wait(
            lambda: (
                "Opened from file dialog"
                in call(
                    "org.freedesktop.DBus.Properties.Get",
                    "org.mpris.MediaPlayer2.Player",
                    "Metadata",
                )
            ),
            "Datei-URI an laufende Instanz",
        )
        assert child_engine() == before, "Zweite Audio-Engine gestartet"
        result = subprocess.run(
            [str(launcher), "--support-dir", str(support), "vicioussid://stop"],
            capture_output=True,
            timeout=8,
        )
        assert result.returncode == 0
        wait(
            lambda: (
                "Stopped"
                in call(
                    "org.freedesktop.DBus.Properties.Get",
                    "org.mpris.MediaPlayer2.Player",
                    "PlaybackStatus",
                )
            ),
            "URL-Schema",
        )
        call("org.mpris.MediaPlayer2.Quit")
        wait(lambda: process.poll() is not None, "Sauberes Beenden")
        stdout, stderr = process.communicate(timeout=2)
        assert process.returncode == 0, stderr.decode()
        result = dict(
            result="passed",
            checks=[
                "Echter Qt-Dateidialog per Tastatur und Klick",
                "Installierbarer Starter",
                "Datei-URI aus Öffnen mit",
                "Nur eine Audio-Engine",
                "URL-Schema",
                "Geordnetes Beenden",
            ],
        )
        (evidence / "shell-result.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False)
        )
        print(json.dumps(result, ensure_ascii=False))
    finally:
        if process.poll() is None:
            process.terminate()
            process.communicate(timeout=5)
