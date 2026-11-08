from pathlib import Path
from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QDialog,
    QFileDialog,
    QFormLayout,
    QGroupBox,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QProgressBar,
    QScrollArea,
    QPushButton,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)
from .widgets import Segments, icon, label, tool
from .window import clock, line, row_widget


class PlayerDialog(QDialog):
    def __init__(self, window, title, width=420):
        super().__init__(window)
        self.window = window
        self.setWindowTitle(title)
        self.setMinimumWidth(width)
        self.layout = QVBoxLayout(self)
        self.layout.setContentsMargins(20, 20, 20, 20)
        self.layout.setSpacing(12)
        self.layout.addWidget(label(title, 15, True))

    def send(self, op, **values):
        self.window.send(op, **values)

    def text(self, text):
        widget = label(text, 11, secondary=True)
        widget.setWordWrap(True)
        self.layout.addWidget(widget)
        return widget

    def done_button(self):
        button = QPushButton("Schließen")
        button.clicked.connect(self.close)
        self.layout.addWidget(button, alignment=Qt.AlignmentFlag.AlignRight)


class SettingsDialog(PlayerDialog):
    def __init__(self, window):
        super().__init__(window, "Einstellungen", 460)
        outer = self.layout
        content = QWidget()
        self.layout = QVBoxLayout(content)
        self.layout.setContentsMargins(0, 0, 0, 0)
        self.layout.setSpacing(12)
        scroll = QScrollArea()
        scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll.setWidget(content)
        outer.addWidget(scroll)
        self.setMinimumHeight(400)
        self.resize(480, min(740, QApplication.primaryScreen().availableGeometry().height() - 80))
        self.layout.addWidget(label("Erscheinungsbild", 13, True))
        modes = ["auto", "light", "dark"]
        theme = Segments(
            ["Automatisch", "Hell", "Dunkel"], lambda i: self.change_theme(modes[i])
        )
        theme.select(modes.index(window.settings.get("theme", "auto")))
        self.layout.addWidget(theme)
        self.text(
            "Automatisch folgt dem Hell/Dunkel-Modus des Desktops. Strg+T schaltet fest auf Hell bzw. Dunkel um."
        )
        self.layout.addWidget(line())
        self.layout.addWidget(label("Oszilloskop", 13, True))
        quality = QComboBox()
        quality.setObjectName("scope-quality")
        quality.setAccessibleName("Oszilloskop-Bildrate")
        for title, value in [
            ("Flüssig · ca. 60 FPS", "smooth"),
            ("Sparsam · 15 FPS", "eco"),
            ("Aus", "off"),
        ]:
            quality.addItem(title, value)
        quality.setCurrentIndex(max(0, quality.findData(window.analysis.scope.quality)))
        quality.currentIndexChanged.connect(
            lambda: window.change_setting("scopeQuality", quality.currentData())
        )
        self.layout.addWidget(quality)
        self.text(
            "Sparsam reduziert Bildrate und Datenabfragen. Aus stoppt die Kurvenzeichnung. "
            "Piano und Register bleiben unabhängig davon verfügbar."
        )
        self.layout.addWidget(line())
        self.layout.addWidget(label("Softwareupdates", 13, True))
        automatic = QCheckBox("Automatisch nach Updates suchen")
        automatic.setChecked(window.settings.get("automaticUpdates", True))
        automatic.toggled.connect(lambda value: window.change_setting("automaticUpdates", value))
        self.layout.addWidget(automatic)
        self.text("Prüft höchstens einmal täglich über GitHub Pages. Installiert wird erst nach deiner Bestätigung.")
        for key, title, description, directory in [
            (
                "root",
                "Autoplay-Ordner",
                "Die Playlist enthält alle SID-Dateien dieses Ordners und seiner Unterordner.",
                True,
            ),
            (
                "songlengths",
                "HVSC-Songlängen",
                "Ohne eigene Auswahl wird DOCUMENTS/Songlengths.md5 automatisch gesucht.",
                False,
            ),
            (
                "stil",
                "STIL-Anmerkungen",
                "Ohne eigene Auswahl wird DOCUMENTS/STIL.txt automatisch gesucht.",
                False,
            ),
        ]:
            self.layout.addWidget(line())
            self.layout.addWidget(label(title, 13, True))
            self.text(description)
            path = QLineEdit(window.settings.get(key, ""))
            path.setReadOnly(True)
            path.setPlaceholderText("Automatisch")
            path.setAccessibleName(title)
            self.layout.addWidget(path)
            row, r = row_widget()
            choose = QPushButton("Auswählen …")
            choose.clicked.connect(
                lambda checked=False, k=key, p=path, d=directory: self.choose(k, p, d)
            )
            r.addWidget(choose)
            if not directory:
                reset = QPushButton("Automatisch")
                reset.clicked.connect(
                    lambda checked=False, k=key, p=path: self.reset(k, p)
                )
                r.addWidget(reset)
            else:
                rescan = QPushButton("Abgleichen")
                rescan.clicked.connect(lambda: self.send("rescan"))
                r.addWidget(rescan)
            r.addStretch()
            self.layout.addWidget(row)
        self.layout.addStretch()
        self.layout = outer
        self.done_button()

    def change_theme(self, value):
        self.window.change_setting("theme", value)
        self.window.apply_appearance()

    def choose(self, key, field, directory):
        value = (
            QFileDialog.getExistingDirectory(
                self, "Autoplay-Ordner wählen", field.text()
            )
            if directory
            else QFileDialog.getOpenFileName(
                self,
                "HVSC-Datei wählen",
                field.text(),
                "HVSC-Daten (*.md5 *.txt);;Alle Dateien (*)",
            )[0]
        )
        if value:
            field.setText(value)
            self.window.change_setting(key, value)

    def reset(self, key, field):
        field.clear()
        self.window.change_setting(key, "")


class PlaybackDialog(PlayerDialog):
    def __init__(self, window):
        super().__init__(window, "Wiedergabeoptionen", 420)
        doc = window.state.get("playback", {})
        form = QFormLayout()
        self.repeat = QComboBox()
        self.repeat.addItems(["Aus", "Subtune", "Datei", "Hörfolge"])
        modes = ["off", "subtune", "file", "sequence"]
        self.repeat.setCurrentIndex(modes.index(doc.get("repeatMode", "off")))
        self.repeat.currentIndexChanged.connect(
            lambda i: self.send("repeat", value=modes[i])
        )
        form.addRow("Wiederholen", self.repeat)
        self.fade = QSpinBox()
        self.fade.setRange(0, 30)
        self.fade.setSuffix(" s")
        self.fade.setValue(int(doc.get("fadeOutSeconds", 0)))
        self.fade.valueChanged.connect(lambda v: self.send("fade", value=v))
        form.addRow("Fadeout", self.fade)
        self.layout.addLayout(form)
        self.layout.addWidget(line())
        self.layout.addWidget(label("Eigene Endzeit", 13, True))
        self.text(
            f"{window.state.get('title', '—')} · Subtune {window.state.get('subtune', 0) + 1}"
        )
        row, r = row_widget()
        self.end_time = QLineEdit()
        self.end_time.setPlaceholderText("Sekunden oder m:ss")
        self.end_time.setAccessibleName("Eigene Endzeit")
        r.addWidget(self.end_time)
        target = dict(window.state.get("personalReference") or {})
        title = window.state.get("title", "")
        apply = QPushButton("Übernehmen")
        apply.clicked.connect(lambda: self.send("endTime", value=self.end_time.text(), reference=target, title=title))
        r.addWidget(apply)
        self.layout.addWidget(row)
        default = QPushButton("Vorgabe verwenden")
        default.clicked.connect(
            lambda: (self.end_time.clear(), self.send("endTime", value="", reference=target, title=title))
        )
        self.layout.addWidget(default, alignment=Qt.AlignmentFlag.AlignLeft)
        self.text(
            "Eigene Endzeit vor HVSC und Berechnung. Maximal 60 Minuten; leer löscht die Vorgabe."
        )
        self.layout.addWidget(line())
        self.layout.addWidget(label("Einschlaftimer", 13, True))
        self.minutes = QSpinBox()
        self.minutes.setRange(1, 180)
        self.minutes.setSuffix(" Minuten")
        self.minutes.setValue(doc.get("sleepMinutes", 30))
        self.layout.addWidget(self.minutes)
        row, r = row_widget()
        start = QPushButton("Timer starten")
        start.clicked.connect(lambda: self.send("sleep", minutes=self.minutes.value()))
        r.addWidget(start)
        end = QPushButton("Nach diesem Subtune")
        end.clicked.connect(lambda: self.send("stopAfter"))
        r.addWidget(end)
        self.layout.addWidget(row)
        self.status = self.text("")
        cancel = QPushButton("Timer abbrechen")
        cancel.clicked.connect(lambda: self.send("sleepCancel"))
        self.layout.addWidget(cancel, alignment=Qt.AlignmentFlag.AlignLeft)
        self.text(
            "Repeat und gewählte Endaktionen gelten auch bei ausgeschaltetem Auto Next."
        )
        self.done_button()
        self.refresh(window.state)

    def refresh(self, state):
        self.status.setText(
            "Noch " + clock(state["remainingSleep"])
            if state.get("sleepActive")
            else "Stoppt am Ende des aktuellen Subtunes."
            if state.get("stopAfter")
            else "Wiedergabe durch Timer beendet."
            if state.get("expired")
            else ""
        )


class MixDialog(PlayerDialog):
    def __init__(self, window):
        super().__init__(window, "SID-Mischung", 440)
        self.buttons = []
        self.chip_boxes = []
        for chip in window.state.get("chips", []):
            number = chip["chip"]
            group = QGroupBox(f"SID {number + 1} · {chip['model']}")
            v = QVBoxLayout(group)
            mute = QCheckBox("Chip stumm")
            mute.toggled.connect(
                lambda checked, c=number: self.send("chipMute", chip=c)
            )
            self.chip_boxes.append((number, mute))
            v.addWidget(mute)
            row, r = row_widget(12)
            for voice in range(3):
                column = QVBoxLayout()
                column.addWidget(label(f"V{voice + 1}", 11))
                buttons, b = row_widget(4)
                channel = number * 3 + voice
                muted = tool(
                    "sound",
                    f"SID {number + 1}, Stimme {voice + 1} stummschalten",
                    lambda checked=False, c=channel: self.send("mute", channel=c),
                )
                solo = QPushButton("Solo")
                solo.setCheckable(True)
                solo.clicked.connect(
                    lambda checked=False, c=channel: self.send("solo", channel=c)
                )
                b.addWidget(muted)
                b.addWidget(solo)
                column.addWidget(buttons)
                r.addLayout(column)
                self.buttons.append((channel, muted, solo))
            v.addWidget(row)
            self.layout.addWidget(group)
        clear = QPushButton("Solos aufheben")
        clear.clicked.connect(lambda: self.send("clearSolos"))
        self.layout.addWidget(clear)
        self.text(
            "Mehrere Solos wirken gemeinsam. Stimmen- und Chip-Mute haben Vorrang."
        )
        self.done_button()
        self.refresh(window.state)

    def refresh(self, state):
        for number, box in self.chip_boxes:
            box.blockSignals(True)
            box.setChecked(state.get("chipMuted", [False] * 3)[number])
            box.blockSignals(False)
        for channel, muted, solo in self.buttons:
            is_muted = state.get("mixMuted", [False] * 9)[channel]
            muted.setIcon(
                icon(
                    "mute" if is_muted else "sound",
                    "#ff453a"
                    if is_muted
                    else self.window.colors["traces"][channel % 3],
                )
            )
            solo.setChecked(channel in state.get("solos", []))


class ExportDialog(PlayerDialog):
    def __init__(self, window):
        super().__init__(window, "Audio exportieren", 640)
        self.text(
            "WAV · 44,1 kHz · 16 Bit. Mehrere SID-Chips werden stereo exportiert. Die aktuelle Mischung und der Filterzustand gelten auch für den Export."
        )
        row, r = row_widget()
        self.scope = QComboBox()
        self.scope.addItems(
            [
                "Aktueller Subtune",
                "Alle Subtunes der Datei",
                "Sichtbare Bibliotheksauswahl",
            ]
        )
        self.scope.currentIndexChanged.connect(self.prepare)
        r.addWidget(self.scope)
        self.duration = QLineEdit()
        self.duration.setPlaceholderText("Dauer: Vorgabe oder m:ss")
        self.duration.editingFinished.connect(
            lambda: self.send("exportDuration", value=self.duration.text())
        )
        r.addWidget(self.duration)
        self.layout.addWidget(row)
        self.items = QListWidget()
        self.items.setMinimumHeight(180)
        self.items.itemChanged.connect(
            lambda item: self.send(
                "exportSelect", id=item.data(Qt.ItemDataRole.UserRole)
            )
        )
        self.layout.addWidget(self.items)
        self.slice = QCheckBox("A/B-Ausschnitt verwenden")
        self.slice.setEnabled(
            window.state.get("loopA") is not None
            and window.state.get("loopB") is not None
        )
        self.slice.toggled.connect(
            lambda enabled: (
                self.send("exportSlice")
                if enabled
                else self.send("exportDuration", value=self.duration.text())
            )
        )
        self.layout.addWidget(self.slice)
        self.progress = QProgressBar()
        self.progress.setRange(0, 1000)
        self.layout.addWidget(self.progress)
        self.status = self.text("Vorschau wird vorbereitet …")
        row, r = row_widget()
        self.export = QPushButton("Exportieren …")
        self.export.setProperty("accent", True)
        self.export.clicked.connect(self.choose_destination)
        r.addWidget(self.export)
        cancel = QPushButton("Abbrechen")
        cancel.clicked.connect(lambda: self.send("exportCancel"))
        r.addWidget(cancel)
        close = QPushButton("Schließen")
        close.clicked.connect(self.close)
        r.addWidget(close)
        self.layout.addWidget(row)
        self.signature = None
        self.selected_signature = None
        self.prepare()

    def prepare(self):
        self.send(
            "exportPrepare",
            scope=["subtune", "file", "selection"][self.scope.currentIndex()],
        )

    def choose_destination(self):
        directory = QFileDialog.getExistingDirectory(
            self, "Audio-Zielordner wählen", str(Path.home() / "Music")
        )
        if directory:
            self.send("export", directory=directory)

    def refresh(self, state):
        export = state.get("export", {})
        self.export.setEnabled(export.get("canExport", False))
        items = export.get("items", [])
        if items != self.signature:
            self.signature = items
            self.selected_signature = None
            self.items.blockSignals(True)
            self.items.clear()
            for value in items:
                item = QListWidgetItem(
                    f"{value['title']}   {value['duration']}   {'Stereo' if value['channels'] == 2 else 'Mono'}\n{value['filename']}"
                )
                item.setData(Qt.ItemDataRole.UserRole, value["id"])
                item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
                item.setCheckState(
                    Qt.CheckState.Checked
                    if value["id"] in export.get("selected", [])
                    else Qt.CheckState.Unchecked
                )
                self.items.addItem(item)
            self.items.blockSignals(False)
        if export.get("selected", []) != self.selected_signature:
            self.selected_signature = export.get("selected", [])
            self.items.blockSignals(True)
            for index in range(self.items.count()):
                item = self.items.item(index)
                item.setCheckState(
                    Qt.CheckState.Checked
                    if item.data(Qt.ItemDataRole.UserRole) in export.get("selected", [])
                    else Qt.CheckState.Unchecked
                )
            self.items.blockSignals(False)
        progress = export.get("progress") or {}
        self.progress.setValue(round(progress.get("fraction", 0) * 1000))
        self.status.setText(
            export.get("error")
            or {
                "preparing": "Vorschau wird vorbereitet …",
                "exporting": "Export läuft …",
                "cancelling": "Export wird abgebrochen …",
                "finished": "Export abgeschlossen.",
                "ready": f"{len(items)} Subtunes bereit.",
            }.get(export.get("state"), "")
        )

    def closeEvent(self, event):
        self.send("exportCancel")
        super().closeEvent(event)


class CollectionDialog(PlayerDialog):
    def __init__(self, window):
        super().__init__(window, "Persönliche Sammlungsdaten", 640)
        self.text(
            "Favoriten, Hörlisten, Lesezeichen, Notizen und eigene Endzeiten zwischen den Playern übertragen. Die Datei enthält keine Musik."
        )
        self.areas = {}
        self.available = [
            ("favorites", "Dateifavoriten"),
            ("lists", "Hörlisten und Lieblings-Subtunes"),
            ("bookmarks", "Lesezeichen"),
            ("notes", "Datei- und Subtunenotizen"),
            ("endTimes", "Persönliche Endzeiten"),
            ("history", "Hörverlauf und Gehört-Kennzeichnung"),
        ]
        for key, title in self.available:
            check = QCheckBox(title)
            check.setChecked(key != "history")
            check.toggled.connect(
                lambda checked, area=key: self.send(
                    "collectionArea", area=area, enabled=checked
                )
            )
            self.areas[key] = check
            self.layout.addWidget(check)
        row, r = row_widget()
        export = QPushButton("Exportieren …")
        export.clicked.connect(self.export_file)
        r.addWidget(export)
        read = QPushButton("Importdatei wählen …")
        read.clicked.connect(self.import_file)
        r.addWidget(read)
        audit = QPushButton("Sammlung prüfen")
        audit.clicked.connect(lambda: self.send("audit"))
        r.addWidget(audit)
        self.layout.addWidget(row)
        self.summary = self.text("")
        self.conflicts = QVBoxLayout()
        self.layout.addLayout(self.conflicts)
        self.results = QListWidget()
        self.results.setMinimumHeight(130)
        self.results.itemChanged.connect(self.check_result)
        self.layout.addWidget(self.results)
        self.skip = QCheckBox(
            "Nicht zugeordnete Favoriten- und Listeneinträge auslassen"
        )
        self.skip.toggled.connect(
            lambda checked: self.send("collectionSkipped", enabled=checked)
        )
        self.layout.addWidget(self.skip)
        self.apply = QPushButton("Ausgewählte Daten zusammenführen")
        self.apply.setEnabled(False)
        self.apply.clicked.connect(lambda: self.send("collectionApply"))
        self.layout.addWidget(self.apply)
        self.repair = QPushButton("Ausgewählte Verweise aktualisieren")
        self.repair.clicked.connect(lambda: self.send("auditRepair"))
        self.repair.hide()
        self.layout.addWidget(self.repair)
        self.cancel_audit = QPushButton("Prüfung abbrechen")
        self.cancel_audit.clicked.connect(lambda: self.send("auditCancel"))
        self.cancel_audit.hide()
        self.layout.addWidget(self.cancel_audit)
        self.done_button()
        self.signature = None
        self.send("collectionReset")

    def export_file(self):
        filename, _ = QFileDialog.getSaveFileName(
            self,
            "Sammlungsdaten exportieren",
            str(Path.home() / "vicious-sid-collection.json"),
            "Sammlungsdaten (*.json)",
        )
        if filename:
            self.send("collectionExport", path=filename)

    def import_file(self):
        filename, _ = QFileDialog.getOpenFileName(
            self,
            "Sammlungsdaten importieren",
            str(Path.home()),
            "Sammlungsdaten (*.json)",
        )
        if filename:
            self.send("collectionImport", path=filename)

    def refresh(self, state):
        value = state.get("collection", {})
        if value == self.signature:
            return
        self.signature = value
        self.summary.setText(
            value.get("error") or value.get("completion") or value.get("summary", "")
        )
        self.apply.setEnabled(value.get("canApply", False))
        self.skip.setVisible(value.get("skipped", 0) > 0)
        self.results.blockSignals(True)
        self.results.clear()
        for issue in value.get("issues", []):
            item = QListWidgetItem(issue["detail"])
            item.setData(Qt.ItemDataRole.UserRole, issue)
            if issue.get("checkable"):
                item.setFlags(item.flags() | Qt.ItemFlag.ItemIsUserCheckable)
                item.setCheckState(
                    Qt.CheckState.Checked
                    if issue.get("selected")
                    else Qt.CheckState.Unchecked
                )
            self.results.addItem(item)
        self.results.blockSignals(False)
        self.repair.setVisible(
            any(issue.get("kind") == "repair" for issue in value.get("issues", []))
        )
        self.repair.setEnabled(value.get("canRepair", False))
        self.cancel_audit.setVisible(value.get("auditing", False))
        for key, check in self.areas.items():
            check.blockSignals(True)
            check.setChecked(key in value.get("areas", []))
            check.setEnabled(not value.get("busy", False))
            check.blockSignals(False)
        existing = getattr(self, "conflict_ids", None)
        conflicts = value.get("conflicts", [])
        if existing != [c["id"] for c in conflicts]:
            self.conflict_ids = [c["id"] for c in conflicts]
            while self.conflicts.count():
                item = self.conflicts.takeAt(0)
                if item.widget():
                    item.widget().deleteLater()
            for conflict in conflicts:
                row, r = row_widget()
                text = label(conflict["label"], 11)
                text.setWordWrap(True)
                r.addWidget(text, 1)
                choice = QComboBox()
                choice.addItems(["Vorhandenes behalten", "Importiertes verwenden"])
                choice.setEnabled(conflict["canUseImported"])
                choice.currentIndexChanged.connect(
                    lambda i, ident=conflict["id"]: self.send(
                        "collectionChoice",
                        id=ident,
                        value="useImported" if i else "keepExisting",
                    )
                )
                r.addWidget(choice)
                self.conflicts.addWidget(row)

    def check_result(self, item):
        issue = item.data(Qt.ItemDataRole.UserRole)
        enabled = item.checkState() == Qt.CheckState.Checked
        if issue.get("kind") == "repair":
            self.send("auditSelect", id=issue["id"], enabled=enabled)
        else:
            self.send(
                "collectionAcceptPath", reference=issue["reference"], enabled=enabled
            )

    def closeEvent(self, event):
        self.send("auditCancel")
        super().closeEvent(event)
