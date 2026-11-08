#!/usr/bin/env python3
"""Zeichentakt und Ressourcenmodi am echten Qt-Fenster mit Swift-Engine."""

import argparse
import hashlib
import json
import os
import sys
import subprocess
from pathlib import Path
import tempfile
import time
from PySide6.QtCore import QEvent, QEventLoop, QObject, Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QComboBox
from vicious_sid.bridge import Engine
from vicious_sid.dialogs import SettingsDialog
from vicious_sid.window import PlayerWindow
from fixtures import write_sid


class Paints(QObject):
    def __init__(self, widget):
        super().__init__(widget)
        self.times = []
        widget.installEventFilter(self)

    def eventFilter(self, watched, event):
        if event.type() == QEvent.Type.Paint:
            self.times.append(time.monotonic())
        return False


parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
parser.add_argument("evidence", type=Path)
parser.add_argument("--baseline", action="store_true")
args = parser.parse_args()
args.evidence.mkdir(parents=True, exist_ok=True)
app = QApplication([])
app.setStyle("Fusion")
app.setQuitOnLastWindowClosed(False)
errors = []


def wait(condition, title, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        QTest.qWait(10)
        if condition():
            return
    raise AssertionError(title)


def child_cpu(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split(") ", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")


with tempfile.TemporaryDirectory(prefix="vicious-scope-") as directory:
    temporary = Path(directory)
    root = temporary / "Music"
    sid = write_sid(root / "Reference.sid")
    # Fester Ton und bekannte Länge halten Tonwechsel und Längenschätzung
    # aus dem Vergleich der Zeichenlast heraus.
    data = bytearray(sid.read_bytes())
    data[0x7C + 3 * 5 + 1] = 0x45
    data[0x7C + 4 * 5 + 1] = 0x1D
    data[-8] = 0x60
    sid.write_bytes(data)
    database = root / "DOCUMENTS" / "Songlengths.md5"
    database.parent.mkdir()
    database.write_text("[Database]\n" + hashlib.md5(sid.read_bytes()).hexdigest() + "=10:00 10:00 10:00\n")
    support = temporary / "Support"

    def launch():
        engine = Engine(args.app / "bin/vicious-sid-desktop-engine",
                        ["--support-dir", str(support), "--root", str(root)])
        engine.failed.connect(errors.append)
        window = PlayerWindow(engine, args.app / "resources", "scope-test")
        window.show()
        wait(lambda: window.state.get("state") == "Playing", "Autoplay")
        return engine, window

    engine, window = launch()
    try:
        scope = window.analysis.scope
        paints = Paints(scope)
        snapshots = []
        engine.stateChanged.connect(lambda state: snapshots.append(time.monotonic()))

        def measure(seconds=2):
            QTest.qWait(150)
            paints.times.clear()
            snapshots.clear()
            start = time.monotonic()
            cpu = time.process_time()
            core_cpu = child_cpu(engine.process.processId())
            loop = QEventLoop()
            QTimer.singleShot(round(seconds * 1000), loop.quit)
            loop.exec()
            elapsed = time.monotonic() - start
            gaps = [b - a for a, b in zip(paints.times, paints.times[1:])]
            return dict(fps=round(len(paints.times) / elapsed, 1),
                        snapshots_per_second=round(len(snapshots) / elapsed, 1),
                        ui_cpu_percent=round(100 * (time.process_time() - cpu) / elapsed, 1),
                        engine_cpu_percent=round(100 * (child_cpu(engine.process.processId()) - core_cpu) / elapsed, 1),
                        longest_frame_ms=round(max(gaps, default=0) * 1000, 1))

        result = {}
        result["smooth"] = measure()
        if args.baseline:
            print(json.dumps(result))
            sys.exit(0)
        assert scope.quality == "smooth"
        assert result["smooth"]["fps"] >= 50, result
        assert result["smooth"]["fps"] > result["smooth"]["snapshots_per_second"] * 1.5
        for dark in (False, True):
            window.change_setting("theme", "dark" if dark else "light")
            window.apply_appearance()
            QTest.qWait(100)
            window.grab().save(str(args.evidence / f"scope-{'dark' if dark else 'light'}.png"))

        settings = SettingsDialog(window)
        settings.show()
        quality = settings.findChild(QComboBox, "scope-quality")
        quality.setFocus()
        QTest.keyClick(quality, Qt.Key.Key_Down)
        wait(lambda: scope.quality == "eco", "Sparmodus per Tastatur")
        result["eco"] = measure()
        assert 10 <= result["eco"]["fps"] <= 20, result
        assert result["eco"]["snapshots_per_second"] < 20, result
        quality.setFocus()
        QTest.keyClick(quality, Qt.Key.Key_Down)
        wait(lambda: scope.quality == "off", "Abschalten per Tastatur")
        result["off"] = measure()
        assert result["off"]["fps"] <= 1 and not engine.include_visuals, result
        settings.grab().save(str(args.evidence / "scope-settings.png"))
        settings.close()
        window.resize(800, 560)
        QTest.qWait(100)
        window.grab().save(str(args.evidence / "scope-off-small.png"))
        window.analysis.mode.setCurrentIndex(1)
        result["piano"] = measure(1)
        assert result["piano"]["snapshots_per_second"] >= 20 and engine.include_visuals, result
        paints.times.clear()
        window.send("stop")
        wait(lambda: window.state.get("state") == "Stopped"
             and window.state["chips"][0]["voices"][0]["hertz"] == 0, "Piano bei Stopp")
        QTest.qWait(50)
        assert paints.times, "Piano reagiert nicht auf neue Daten"
        window.send("play")
        wait(lambda: window.state.get("state") == "Playing", "Play nach Piano")
        window.analysis.mode.setCurrentIndex(2)
        QTest.qWait(150)
        assert engine.include_visuals and not scope.frame_timer.isActive()
        window.analysis.mode.setCurrentIndex(0)
        window.change_setting("scopeQuality", "smooth")
        window.send("pause")
        wait(lambda: window.state.get("state") == "Paused", "Pause")
        phase = scope.phase_time
        result["paused"] = measure(0.5)
        assert result["paused"]["fps"] <= 2 and scope.phase_time == phase, result
        window.send("play")
        wait(lambda: window.state.get("state") == "Playing", "Fortsetzen")
        window.toggle_mini()
        result["mini"] = measure(0.5)
        assert result["mini"]["fps"] == 0 and not engine.include_visuals, result
        window.toggle_mini()
        wait(scope.frame_timer.isActive, "Zeichnen nach Mini-Player")
        window.showMinimized()
        QTest.qWait(150)
        result["minimized"] = measure(0.5)
        assert result["minimized"]["fps"] <= 2 and not engine.include_visuals, result
        window.showNormal()
        wait(scope.frame_timer.isActive, "Zeichnen nach Wiederherstellen")
        window.hide()
        QTest.qWait(100)
        assert not scope.frame_timer.isActive() and not engine.include_visuals
        window.show()
        wait(scope.frame_timer.isActive, "Zeichnen nach Einblenden")
        window.change_setting("scopeQuality", "eco")
        window.send("snapshot", visuals=False)
        wait(lambda: (support / "desktop-settings.json").exists(), "Einstellungen gespeichert")
        window.close()
        engine, window = launch()
        assert window.analysis.scope.quality == "eco", "Sparmodus nach Neustart verloren"
        assert not errors, errors
        empty = temporary / "Empty"
        empty.mkdir()
        protocol = subprocess.run(
            [str(args.app / "bin/vicious-sid-desktop-engine"),
             "--support-dir", str(temporary / "Protocol"), "--root", str(empty)],
            input='{"op":"snapshot","visuals":false}\n{"op":"snapshot"}\n{"op":"quit"}\n',
            text=True, capture_output=True, timeout=10, check=True,
        )
        states = [json.loads(line) for line in protocol.stdout.splitlines()
                  if json.loads(line).get("event") == "state"]
        assert len(states) == 2 and "chips" not in states[0] and "chips" in states[1]
        result["result"] = "passed"
        result["limits"] = "Xvfb: Zeichentakt und CPU, keine Monitor-/Compositor-Abnahme. CPU in Prozent eines Kerns."
        (args.evidence / "scope-result.json").write_text(json.dumps(result, indent=2))
        print(json.dumps(result))
    finally:
        window.close()
        engine.close()
