#!/usr/bin/env python3
"""Echter Qt-/Engine-Lauf auf einem isolierten X11-Display, mit eigenen Daten."""

import argparse
import json
from pathlib import Path
import tempfile
import time
from PySide6.QtCore import Qt
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication
from vicious_sid.bridge import Engine
from vicious_sid.window import PlayerWindow
from vicious_sid.dialogs import (
    SettingsDialog,
    PlaybackDialog,
    MixDialog,
    ExportDialog,
    CollectionDialog,
)
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


def wait(condition, label, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        app.processEvents()
        QTest.qWait(20)
        if condition():
            return
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix="vicious-gui-smoke-") as directory:
    temporary = Path(directory)
    root = temporary / "music"
    root.mkdir()
    sid = write_sid(root / "Composer" / "Reference.sid")
    multi = write_sid(root / "Other" / "Multi.sid", 3, "Three SID Reference")
    engine = Engine(
        base / "bin/vicious-sid-desktop-engine",
        ["--support-dir", str(temporary / "support"), "--root", str(root)],
    )
    window = PlayerWindow(
        engine, base / "resources", (base / "VERSION").read_text().strip()
    )
    window.resize(1200, 700)
    window.show()
    engine.failed.connect(failures.append)
    try:
        wait(
            lambda: window.total == 2 and window.state.get("state") == "Playing",
            "Bibliothek und Autoplay",
        )
        wait(lambda: window.state.get("elapsed", 0) > 0.5, "Wiedergabefortschritt")
        window.send("pause")
        wait(lambda: window.state.get("state") == "Paused", "Pause")
        position = window.state["elapsed"]
        QTest.qWait(300)
        app.processEvents()
        assert abs(window.state["elapsed"] - position) < 0.08
        assert window.state["chips"][0]["voices"][0]["hertz"] > 0
        window.grab().save(str(evidence / "linux-light.png"))
        window.centralWidget().grab().save(str(evidence / "linux-light-content.png"))

        def geometry():
            from PySide6.QtWidgets import QWidget

            result = dict(
                sidebar=window.sidebar.width(),
                mainMinimum=window.splitter.widget(1).minimumSizeHint().width(),
            )
            for name in ["toolbar", "scrubber", "loopbar"]:
                widget = window.findChild(QWidget, name)
                point = widget.mapTo(window.centralWidget(), widget.rect().topLeft())
                result[name] = [point.x(), point.y(), widget.width(), widget.height()]
            result["scopeY"] = window.analysis.scope.mapTo(
                window.centralWidget(), window.analysis.scope.rect().topLeft()
            ).y()
            return result

        layout_evidence = {"normal": geometry()}

        window.toggle_theme()
        QTest.qWait(100)
        window.grab().save(str(evidence / "linux-dark.png"))
        window.toggle_theme()
        window.volume.setValue(35)
        wait(lambda: window.state.get("volume") == 0.35, "Lautstärkeregler")
        window.model_box.setCurrentIndex(2)
        wait(lambda: window.state.get("model") == 8580, "SID-Modellregler")
        window.clock_box.setCurrentIndex(2)
        wait(
            lambda: (
                window.state.get("clock") == "ntsc" and not window.state.get("seeking")
            ),
            "Taktregler",
        )
        window.model_box.setCurrentIndex(0)
        window.clock_box.setCurrentIndex(0)
        window.volume.setValue(100)
        wait(
            lambda: (
                window.state.get("clock") == "auto"
                and window.state.get("volume") == 1
                and not window.state.get("seeking")
            ),
            "Klangvorgaben zurücksetzen",
        )
        window.send("stop")
        wait(lambda: window.state.get("state") == "Stopped", "Stopp")
        window.send("seek", seconds=2)
        wait(lambda: abs(window.state.get("elapsed", 0) - 2) < 0.05, "Seek bei Stopp")
        QTest.mouseClick(window.transport_buttons["play"], Qt.MouseButton.LeftButton)
        wait(
            lambda: (
                window.state.get("state") == "Playing"
                and window.state.get("elapsed", 0) > 2.2
            ),
            "Play übernimmt gepufferten Seek",
        )
        QTest.mouseClick(window.transport_buttons["play"], Qt.MouseButton.LeftButton)
        wait(lambda: window.state.get("state") == "Paused", "Play/Pause-Knopf")
        window.subtune(1)
        wait(lambda: window.state.get("subtune") == 1, "Subtune-Wechsel")
        window.send("favorite", id="Composer/Reference.sid")
        wait(lambda: any(row.get("favorite") for row in window.rows), "Favorit")
        window.search.setText("chips:3")
        wait(
            lambda: len(window.rows) == 1 and window.rows[0]["name"] == "Multi",
            "Core-Metadatensuche",
        )
        index = window.track_model.index(0)
        QTest.mouseClick(
            window.track_view.viewport(),
            Qt.MouseButton.LeftButton,
            pos=window.track_view.visualRect(index).center(),
        )
        wait(lambda: len(window.state.get("chips", [])) == 3, "Titelliste wählt 3SID")
        window.search.clear()
        wait(lambda: len(window.rows) == 2, "Suche löschen")
        window.send("mute", channel=3)
        wait(lambda: window.state["mixMuted"][3], "Stimme 4 stumm")
        window.send("solo", channel=7)
        wait(lambda: 7 in window.state["solos"], "3SID-Solo")
        for mode, name in [(1, "piano"), (2, "registers"), (0, "multi")]:
            window.analysis.mode.setCurrentIndex(mode)
            QTest.qWait(80)
            window.grab().save(str(evidence / f"linux-{name}.png"))
        window.send("createList", name="Reference list")
        wait(
            lambda: len(window.state.get("listening", {}).get("lists", [])) > 0,
            "Hörliste sichern",
        )
        window.change_page(1)
        window.tabs.select(1)
        QTest.mouseClick(window.list_play, Qt.MouseButton.LeftButton)
        wait(
            lambda: (
                (window.state.get("listening", {}).get("queue") or {}).get("kind")
                == "savedList"
            ),
            "Hörliste per Knopf starten",
        )
        window.send("queueSelection")
        wait(
            lambda: (
                (window.state.get("listening", {}).get("queue") or {}).get("kind")
                == "selection"
            ),
            "Auswahl als Hörfolge",
        )
        window.send("bookmark", name="Reference bookmark")
        wait(
            lambda: len(window.state.get("history", {}).get("bookmarks", [])) == 1,
            "Lesezeichen",
        )
        window.send("note", text="Reference note")
        wait(
            lambda: len(window.state.get("history", {}).get("notes", [])) == 1, "Notiz"
        )
        for page, name in [(1, "lists"), (2, "queue"), (3, "history")]:
            window.change_page(page)
            window.tabs.select(page)
            QTest.qWait(80)
            window.grab().save(str(evidence / f"linux-{name}.png"))
        window.change_page(0)
        window.tabs.select(0)
        for cls, name in [
            (SettingsDialog, "settings"),
            (PlaybackDialog, "playback"),
            (MixDialog, "mix"),
            (ExportDialog, "export"),
            (CollectionDialog, "collection"),
        ]:
            dialog = cls(window)
            window.dialogs.append(dialog)
            dialog.show()
            QTest.qWait(180)
            app.processEvents()
            dialog.grab().save(str(evidence / f"linux-{name}.png"))
            dialog.close()
        window.toggle_mini()
        QTest.qWait(80)
        assert window.width() <= 600 and window.height() < 120
        window.grab().save(str(evidence / "linux-mini.png"))
        window.toggle_mini()
        window.resize(800, 560)
        QTest.qWait(80)
        window.grab().save(str(evidence / "linux-narrow.png"))
        layout_evidence["narrow"] = geometry()
        (evidence / "layout.json").write_text(json.dumps(layout_evidence, indent=2))
        window.send("pause")
        wait(lambda: window.state.get("state") == "Paused", "Abschlusspause")
        result = dict(
            result="passed",
            checks=[
                "Autoplay",
                "Pause erhält Position",
                "Seek bei Stopp",
                "Play/Pause per Klick",
                "Lautstärke-, Modell- und Taktregler",
                "Subtune",
                "Favorit",
                "Metadatensuche",
                "3SID",
                "Mute/Solo",
                "Hörliste",
                "Hörfolge",
                "Lesezeichen",
                "Notiz",
                "Mini-Player",
            ],
            errors=failures,
        )
        assert not failures, failures
        (evidence / "result.json").write_text(
            json.dumps(result, indent=2, ensure_ascii=False)
        )
        print(json.dumps(result, ensure_ascii=False))
    except Exception:
        print(
            json.dumps(
                dict(
                    rows=window.rows,
                    state=window.state,
                    errors=failures,
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
