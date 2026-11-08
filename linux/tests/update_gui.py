#!/usr/bin/env python3
"""Update-Dialog im echten Qt-Lauf; GitHub-Antworten bleiben eigene Fixtures."""

import argparse
from pathlib import Path
import tempfile
import time
from unittest.mock import patch
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication
from vicious_sid.bridge import Engine
from vicious_sid.window import PlayerWindow
from vicious_sid.dialogs import SettingsDialog
from fixtures import write_sid

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("evidence", type=Path)
args = parser.parse_args()
args.evidence.mkdir(parents=True, exist_ok=True)
app = QApplication([])
app.setStyle("Fusion")
calls = []


class FixtureUpdater:
    def __init__(self, bundle, cancel=None, progress=None):
        self.cancel = cancel
        self.progress = progress

    def check(self):
        time.sleep(0.05)
        return dict(version="9.0.0", sha256="0" * 64,
                    notes="Reference update\n<b>This remains plain text</b>")

    def install(self, ticket):
        assert ticket["version"] == "9.0.0"
        calls.append("install")
        self.progress(10, 100)
        time.sleep(0.1)
        return ticket["version"]


def wait(condition, title):
    end = time.monotonic() + 10
    while time.monotonic() < end:
        QTest.qWait(10)
        if condition():
            return
    raise AssertionError(title)


with tempfile.TemporaryDirectory(prefix="vicious-update-gui-") as temporary:
    root = Path(temporary)
    music = root / "Music"
    write_sid(music / "Reference.sid")
    engine = Engine(args.app / "bin/vicious-sid-desktop-engine",
                    ["--support-dir", str(root / "Support"), "--root", str(music)])
    window = PlayerWindow(engine, args.app / "resources", "1.9.55")
    window.show()
    try:
        wait(lambda: window.state.get("state") == "Playing", "Autoplay")
        window.change_setting("automaticUpdates", False)
        with patch("vicious_sid.update_dialog.Updater", FixtureUpdater):
            action = next(action for action in window.menuBar().actions()[-1].menu().actions()
                          if action.text() == "Nach Updates suchen …")
            action.trigger()
            dialog = window.update_dialog
            wait(lambda: not dialog.busy, "Updateprüfung")
            assert dialog.isVisible() and dialog.ticket["version"] == "9.0.0"
            assert not calls, "Prüfung hat ungefragt installiert"
            assert dialog.notes.textFormat() == Qt.TextFormat.PlainText
            for theme in ("light", "dark"):
                window.change_setting("theme", theme)
                window.apply_appearance()
                QTest.qWait(50)
                dialog.grab().save(str(args.evidence / f"update-{theme}.png"))
            QTest.mouseClick(dialog.install_button, Qt.MouseButton.LeftButton)
            wait(lambda: not dialog.busy, "Installation")
            assert calls == ["install"] and "nächsten Start" in dialog.status.text()
            assert window.isVisible() and window.state["state"] == "Playing"
            dialog.close()
            settings = SettingsDialog(window)
            settings.resize(480, 560)
            settings.show()
            QTest.qWait(50)
            settings.grab().save(str(args.evidence / "update-settings.png"))
            settings.close()
            action.trigger()
            window.close()
            wait(lambda: not window.isVisible(), "Beenden während Updateprüfung")
        print("Updateprüfung, Klartext, explizite Installation, Wiedergabe und Beenden während Prüfung bestanden.")
    finally:
        if window.update_dialog and window.update_dialog.busy:
            window.update_dialog.cancel()
            wait(lambda: not window.update_dialog.busy, "Update-Thread beenden")
        window.close()
        engine.close()
