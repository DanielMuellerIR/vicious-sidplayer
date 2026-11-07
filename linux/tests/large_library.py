#!/usr/bin/env python3
"""50.001 eigene SID-Einträge: virtuelle Liste und begrenztes Titelmenü."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication
from vicious_sid.bridge import Engine
from vicious_sid.window import PlayerWindow
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


def wait(condition, title, seconds=120):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        app.processEvents()
        QTest.qWait(30)
        if condition():
            return
    raise AssertionError(title)


def rss(pid):
    return int(
        next(
            line.split()[1]
            for line in Path(f"/proc/{pid}/status").read_text().splitlines()
            if line.startswith("VmRSS:")
        )
    )


with tempfile.TemporaryDirectory(prefix="vicious-large-library-") as directory:
    temporary = Path(directory)
    root = temporary / "Music"
    root.mkdir()
    original = write_sid(temporary / "Reference.sid", title="Large library reference")
    for index in range(50001):
        destination = root / f"Folder{index // 500:03}" / f"Track{index:05}.sid"
        destination.parent.mkdir(exist_ok=True)
        os.link(original, destination)
    documents = root / "DOCUMENTS"
    documents.mkdir()
    (documents / "Songlengths.md5").write_text(
        "[Database]\n"
        + hashlib.md5(original.read_bytes()).hexdigest()
        + "=3:00 3:00 3:00\n"
    )
    engine = Engine(
        base / "bin/vicious-sid-desktop-engine",
        ["--support-dir", str(temporary / "Support"), "--root", str(root)],
    )
    window = PlayerWindow(
        engine, base / "resources", (base / "VERSION").read_text().strip()
    )
    window.show()
    errors = []
    engine.failed.connect(errors.append)
    started = time.monotonic()
    try:
        wait(
            lambda: window.total == 50001 and not window.state.get("indexing", True),
            "Große Bibliothek und Headerindex",
        )
        initial = time.monotonic() - started
        window.populate_tune_menu()
        assert len(window.tune_menu.actions()) <= 301
        assert window.track_model.rowCount() == 50001
        window.search.setText("Track49999")
        wait(
            lambda: len(window.rows) == 1 and window.rows[0]["name"] == "Track49999",
            "Suche im großen Index",
            10,
        )
        window.send("select", index=window.rows[0]["index"])
        wait(
            lambda: window.state.get("filename") == "Track49999",
            "Titel am Listenende auswählen",
            10,
        )
        window.populate_tune_menu()
        assert len(window.tune_menu.actions()) >= 300, (
            "Titelmenü darf nicht vom Suchfilter abhängen"
        )
        memory = dict(
            guiKiB=rss(os.getpid()), engineKiB=rss(engine.process.processId())
        )
        assert sum(memory.values()) < 700 * 1024, memory
        window.search.clear()
        wait(
            lambda: window.track_model.rowCount() == 50001,
            "Gesamtliste wieder anzeigen",
            10,
        )
        window.send("folders")
        wait(lambda: any(row.get("folderRow") for row in window.rows), "Ordnerbaum", 10)
        assert len(window.rows) < 110
        window.grab().save(str(evidence / "linux-large-library.png"))
        assert not errors, errors
        result = dict(
            result="passed",
            entries=50001,
            startupSeconds=round(initial, 2),
            memory=memory,
            titleMenuActions=len(window.tune_menu.actions()),
            errors=errors,
        )
        (evidence / "large-library-result.json").write_text(
            json.dumps(result, indent=2)
        )
        print(json.dumps(result))
    finally:
        window.close()
        engine.close()
