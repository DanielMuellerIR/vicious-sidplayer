#!/usr/bin/env python3
"""Desktop-Verträge: MPRIS, PCM, Export, Import, Restore und Scan-Abbruch."""

import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import wave
from PySide6.QtCore import QMimeData, QPointF, Qt, QUrl
from PySide6.QtGui import QDragEnterEvent, QDropEvent
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication
from vicious_sid.bridge import Engine
from vicious_sid.window import PlayerWindow
from vicious_sid.mpris import MPRIS
from fixtures import write_sid

parser = argparse.ArgumentParser()
parser.add_argument("app")
parser.add_argument("evidence")
args = parser.parse_args()
base = Path(args.app).resolve()
evidence = Path(args.evidence).resolve()
evidence.mkdir(parents=True, exist_ok=True)
app = QApplication([])
app.setStyle("Fusion")
failures = []
checks = []


def wait(condition, title, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        app.processEvents()
        QTest.qWait(20)
        if condition():
            return
    raise AssertionError(title)


def dbus(method, *arguments):
    process = subprocess.Popen(
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
            *arguments,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        wait(lambda: process.poll() is not None, "D-Bus-Aufruf " + method, 5)
        output, error = process.communicate(timeout=1)
        assert process.returncode == 0, error.decode()
        return output.decode()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def launch(root, support):
    engine = Engine(
        base / "bin/vicious-sid-desktop-engine",
        ["--support-dir", str(support), "--root", str(root)],
    )
    window = PlayerWindow(
        engine, base / "resources", (base / "VERSION").read_text().strip()
    )
    window.show()
    engine.failed.connect(failures.append)
    return engine, window


with tempfile.TemporaryDirectory(prefix="vicious-desktop-regressions-") as directory:
    temporary = Path(directory)
    root = temporary / "Music"
    support = temporary / "Support"
    write_sid(root / "Reference.sid")
    engine, window = launch(root, support)
    mpris = MPRIS(window)
    try:
        wait(lambda: window.state.get("state") == "Playing", "Autoplay")
        assert mpris.active, "MPRIS-Dienst fehlt"
        output = dbus(
            "org.freedesktop.DBus.Properties.Get",
            "org.mpris.MediaPlayer2.Player",
            "PlaybackStatus",
        )
        assert "Playing" in output
        dbus("org.mpris.MediaPlayer2.Player.Pause")
        wait(lambda: window.state.get("state") == "Paused", "MPRIS-Pause")
        output = dbus(
            "org.freedesktop.DBus.Properties.Get",
            "org.mpris.MediaPlayer2.Player",
            "Position",
        )
        assert "int64" in output, output
        dbus("org.mpris.MediaPlayer2.Player.Play")
        wait(lambda: window.state.get("state") == "Playing", "MPRIS-Play")
        checks.append("MPRIS Play/Pause und 64-Bit-Position")
        window.send("pause")
        wait(lambda: window.state.get("state") == "Paused", "Pause für Songende")
        for sub in range(3):
            window.send("subtune", value=sub)
            wait(lambda: window.state.get("subtune") == sub, "Subtune für Endzeit")
            window.send("endTime", value="0.25")
            wait(
                lambda: (
                    len(window.state.get("playback", {}).get("endTimes", {})) == sub + 1
                ),
                "Endzeit gesichert",
            )
        window.send("subtune", value=0)
        window.send("play")
        wait(
            lambda: (
                window.state.get("state") == "Stopped"
                and window.state.get("subtune") == 2
            ),
            "Auto Next spielt alle Subtunes und beendet die Folge",
            8,
        )
        for sub in range(3):
            window.send("subtune", value=sub)
            wait(lambda: window.state.get("subtune") == sub, "Subtune für Vorgabe")
            window.send("endTime", value="")
            wait(
                lambda: (
                    len(window.state.get("playback", {}).get("endTimes", {})) == 2 - sub
                ),
                "Endzeit zurückgesetzt",
            )
        window.send("subtune", value=0)
        checks.append("Auto Next über alle drei Subtunes bis zum Folgenende")

        window.send("stop")
        wait(lambda: window.state.get("state") == "Stopped", "Stopp")
        window.send("seek", seconds=1)
        wait(lambda: abs(window.state.get("elapsed", 0) - 1) < 0.01, "A-Position")
        window.send("loopA")
        wait(lambda: window.state.get("loopA") == 1, "A-Marker")
        window.send("seek", seconds=1.5)
        wait(lambda: window.state.get("elapsed") == 1.5, "B-Position")
        window.send("loopB")
        wait(lambda: window.state.get("loopB") == 1.5, "B-Marker")
        window.send("model", value=8580)
        window.send("mute", channel=1)
        window.send("filter")
        wait(
            lambda: (
                window.state.get("model") == 8580
                and window.state.get("mixMuted", [False] * 9)[1]
                and not window.state.get("filter")
            ),
            "Loop-Klangkonfiguration",
        )
        window.send("loopToggle")
        wait(lambda: window.state.get("loopEnabled"), "A/B aktiv")
        window.send("play")
        deadline = time.monotonic() + 2.2
        while time.monotonic() < deadline:
            app.processEvents()
            QTest.qWait(20)
        assert 1 <= window.state["elapsed"] <= 1.65, window.state["elapsed"]
        window.send("model", value=6581)
        window.send("mute", channel=1)
        window.send("filter")
        wait(
            lambda: (
                window.state.get("model") == 6581
                and not window.state.get("mixMuted", [False] * 9)[1]
                and window.state.get("filter")
                and not window.state.get("loopPreparing")
            ),
            "Aktive Loop-Konfiguration ändern",
        )
        until = time.monotonic() + 0.8
        while time.monotonic() < until:
            app.processEvents()
            QTest.qWait(20)
        assert window.state.get("loopEnabled") and 1 <= window.state["elapsed"] <= 1.65
        window.send("seek", seconds=3)
        wait(
            lambda: (
                not window.state.get("loopEnabled")
                and window.state.get("elapsed", 0) >= 3
            ),
            "Seek außerhalb Loop",
        )
        checks.append("A/B und Ausstieg durch Seek")
        window.send("pause")
        wait(lambda: window.state.get("state") == "Paused", "Pause vor Export")
        window.send("exportPrepare", scope="subtune")
        wait(
            lambda: window.state.get("export", {}).get("state") == "ready",
            "Exportvorschau",
        )
        window.send("exportDuration", value="0.2")
        wait(
            lambda: window.state["export"]["items"][0]["duration"] == "0:00.2",
            "Exportdauer",
        )
        output = temporary / "Export"
        output.mkdir()
        window.send("export", directory=str(output))
        wait(lambda: window.state["export"]["state"] == "finished", "WAV-Export")
        files = list(output.glob("*.wav"))
        assert len(files) == 1
        with wave.open(str(files[0])) as audio:
            assert audio.getnchannels() == 1 and audio.getnframes() == 8820
        checks.append("WAV-Export: 8820 Frames, mono")
        window.send("favorite", id="Reference.sid")
        wait(lambda: any(r.get("favorite") for r in window.rows), "Favorit")
        window.send("note", text="Portable reference note")
        wait(lambda: window.state.get("history", {}).get("notes"), "Notiz")
        export = temporary / "collection.json"
        window.send("collectionExport", path=str(export))
        wait(export.exists, "Sammlungsexport")
        document = json.loads(export.read_text())
        assert document.get("favorites") and document.get("notes")
        window.send("favorite", id="Reference.sid")
        wait(
            lambda: not any(r.get("favorite") for r in window.rows), "Favorit entfernen"
        )
        window.send("collectionImport", path=str(export))
        wait(
            lambda: window.state.get("collection", {}).get("canApply"), "Importvorschau"
        )
        window.send("collectionApply")
        wait(
            lambda: any(r.get("favorite") for r in window.rows), "Import zusammenführen"
        )
        checks.append("Sammlungsexport und geprüfter Reimport")
        external = temporary / "Dropped"
        write_sid(external / "External.sid", 3, "Dropped three SID")
        mime = QMimeData()
        mime.setUrls([QUrl.fromLocalFile(str(external))])
        enter = QDragEnterEvent(
            QPointF(100, 100),
            Qt.DropAction.CopyAction,
            mime,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
        )
        QApplication.sendEvent(window, enter)
        assert enter.isAccepted()
        drop = QDropEvent(
            QPointF(100, 100),
            Qt.DropAction.CopyAction,
            mime,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
        )
        QApplication.sendEvent(window, drop)
        wait(lambda: len(window.state.get("chips", [])) == 3, "Ordnerdrop")
        checks.append("Ordner per Drag & Drop")
        # Eigene PipeWire-Senke: Samples dürfen ankommen; die Lautsprecher bleiben still.
        monitor = os.environ.get("VICIOUS_TEST_MONITOR")
        if monitor:
            capture = temporary / "capture.raw"
            with capture.open("wb") as file:
                recorder = subprocess.Popen(
                    [
                        "parec",
                        "--device",
                        monitor,
                        "--raw",
                        "--latency-msec=50",
                        "--format=s16le",
                        "--rate=44100",
                        "--channels=2",
                    ],
                    stdout=file,
                    stderr=subprocess.PIPE,
                )
                try:
                    window.send("play")
                    wait(lambda: window.state.get("state") == "Playing", "PCM-Start")
                    QTest.qWait(900)
                    app.processEvents()
                    window.send("pause")
                    wait(lambda: window.state.get("state") == "Paused", "PCM-Pause")
                    QTest.qWait(400)
                finally:
                    recorder.terminate()
                    recorder.communicate(timeout=3)
            samples = struct.unpack(
                "<" + "h" * (capture.stat().st_size // 2), capture.read_bytes()
            )
            assert max(map(abs, samples), default=0) > 100, "Audioausgabe ist stumm"
            checks.append("Nichtstummes Stereo-PCM über echten ALSA/PipeWire-Pfad")
        window.send("select", index=0)
        window.send("subtune", value=1)
        window.send("seek", seconds=4)
        wait(
            lambda: (
                window.state.get("subtune") == 1
                and abs(window.state.get("elapsed", 0) - 4) < 0.01
            ),
            "Restore-Ausgangslage",
        )
        window.close()
        engine.close()
        mpris.bus.unregisterService("org.mpris.MediaPlayer2.vicioussid")
        mpris.bus.unregisterObject("/org/mpris/MediaPlayer2")
        # Auch ohne gespeicherten Dateindex muss die Sitzung nach dem Scan
        # wieder bei Subtune und Position ankommen.
        for candidate in support.glob("*.json"):
            value = json.loads(candidate.read_text())
            if (
                isinstance(value, dict)
                and "formatVersion" in value
                and "entries" in value
            ):
                candidate.unlink()
        engine, window = launch(root, support)
        wait(
            lambda: (
                window.state.get("subtune") == 1 and window.state.get("elapsed", 0) >= 4
            ),
            "Session-Restore",
        )
        assert any(r.get("favorite") for r in window.rows)
        assert window.state["history"]["notes"]
        checks.append("Session, Favoriten und Notizen nach Neustart")
        window.send("rescan")
        window.send("clear")
        wait(
            lambda: window.total == 0 and not window.state.get("trackID"),
            "Leeren während Scan",
        )
        QTest.qWait(500)
        app.processEvents()
        assert window.total == 0
        checks.append("Scan-Abbruch beim Leeren")
        assert not failures, failures
        result = dict(result="passed", checks=checks, errors=failures)
        (evidence / "desktop-result.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False)
        )
        print(json.dumps(result, ensure_ascii=False))
    except Exception:
        print(
            json.dumps(dict(state=window.state, errors=failures), ensure_ascii=False),
            flush=True,
        )
        raise
    finally:
        window.close()
        engine.close()
