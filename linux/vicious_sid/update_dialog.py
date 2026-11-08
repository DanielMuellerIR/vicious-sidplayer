"""Updatearbeit bleibt außerhalb des Qt-Zeichentakts und der Audiowiedergabe."""

import threading
import time
from PySide6.QtCore import QThread, QTimer, Signal, Qt
from PySide6.QtWidgets import QDialog, QHBoxLayout, QLabel, QProgressBar, QPushButton, QScrollArea, QVBoxLayout
from .update import Updater, UpdateError


class UpdateTask(QThread):
    completed = Signal(object)
    progress = Signal(int, int)

    def __init__(self, bundle, ticket=None, parent=None):
        super().__init__(parent)
        self.bundle = bundle
        self.ticket = ticket
        self.cancelled = threading.Event()

    def run(self):
        last = 0

        def progress(current, total):
            nonlocal last
            now = time.monotonic()
            if now - last >= 0.1:
                self.progress.emit(current, total)
                last = now

        updater = Updater(self.bundle, cancel=self.cancelled.is_set, progress=progress)
        try:
            result = (dict(installed=updater.install(self.ticket)) if self.ticket
                      else dict(ticket=updater.check()))
        except Exception as error:
            result = dict(error=str(error) if isinstance(error, UpdateError)
                          else "Updateprüfung oder Installation fehlgeschlagen. Bitte später erneut versuchen.")
        self.completed.emit(result)


class UpdateDialog(QDialog):
    def __init__(self, window):
        super().__init__(window)
        self.window = window
        self.task = None
        self.ticket = None
        self.automatic = False
        self.close_requested = False
        self.setWindowTitle("Softwareupdate")
        self.setMinimumWidth(460)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 20, 20, 20)
        layout.setSpacing(12)
        self.status = QLabel("Nach Updates suchen")
        self.status.setWordWrap(True)
        self.status.setTextFormat(Qt.TextFormat.PlainText)
        layout.addWidget(self.status)
        self.notes = QLabel()
        self.notes.setTextFormat(Qt.TextFormat.PlainText)
        self.notes.setWordWrap(True)
        self.notes_scroll = QScrollArea()
        self.notes_scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        self.notes_scroll.setWidgetResizable(True)
        self.notes_scroll.setMaximumHeight(220)
        self.notes_scroll.setWidget(self.notes)
        layout.addWidget(self.notes_scroll)
        self.progress = QProgressBar()
        layout.addWidget(self.progress)
        row = QHBoxLayout()
        row.addStretch()
        self.check_button = QPushButton("Erneut prüfen")
        self.check_button.clicked.connect(self.check)
        row.addWidget(self.check_button)
        self.install_button = QPushButton("Herunterladen und installieren")
        self.install_button.clicked.connect(self.install)
        row.addWidget(self.install_button)
        self.close_button = QPushButton("Schließen")
        self.close_button.clicked.connect(self.close)
        row.addWidget(self.close_button)
        layout.addLayout(row)

    @property
    def busy(self):
        return self.task is not None

    def cancel(self):
        if self.task:
            self.task.cancelled.set()
            self.status.setText("Aktualisierung wird beendet …")

    def start(self, ticket=None):
        if self.busy:
            return
        self.close_requested = False
        self.notes.clear()
        self.notes_scroll.hide()
        self.check_button.setEnabled(False)
        self.install_button.setEnabled(False)
        self.progress.setRange(0, 0)
        self.progress.show()
        self.close_button.setText("Abbrechen")
        self.status.setText("Update wird heruntergeladen und geprüft …" if ticket else "Updates werden geprüft …")
        self.task = UpdateTask(self.window.resources.parent, ticket, self)
        self.task.progress.connect(self.show_progress)
        self.task.completed.connect(self.completed)
        self.task.finished.connect(self.task_finished)
        self.task.start()

    def check(self, automatic=False):
        if self.busy:
            if not automatic:
                self.show()
            return
        self.automatic = automatic
        self.ticket = None
        self.install_button.hide()
        if not automatic:
            self.show()
        self.start()

    def install(self):
        if not self.ticket:
            return
        # Der Knopf ist die ausdrückliche Installationsbestätigung. Die laufende
        # App bleibt in ihrer alten Version aktiv; kein erzwungener Neustart.
        self.automatic = False
        self.start(self.ticket)

    def show_progress(self, current, total):
        if self.task and self.task.ticket:
            self.progress.setRange(0, 1000)
            self.progress.setValue(min(1000, current * 1000 // max(1, total)))

    def completed(self, result):
        self.progress.hide()
        if "error" in result:
            self.ticket = None
            self.status.setText(result["error"])
        elif "installed" in result:
            self.ticket = None
            self.status.setText(f"Version {result['installed']} ist installiert. Sie wird beim nächsten Start verwendet.")
        elif result.get("ticket"):
            self.ticket = result["ticket"]
            self.status.setText(f"Version {self.ticket['version']} ist verfügbar. Installiert: {self.window.version}.")
            self.notes.setText(self.ticket.get("notes", ""))
            self.notes_scroll.setVisible(bool(self.notes.text()))
            self.install_button.show()
            if not self.close_requested and not self.window.close_after_update:
                self.show()
        else:
            self.status.setText(f"Version {self.window.version} ist aktuell.")
        if self.automatic and "error" not in result:
            self.window.change_setting("lastUpdateCheck", time.time())

    def task_finished(self):
        self.task.deleteLater()
        self.task = None
        self.check_button.setEnabled(True)
        self.install_button.setEnabled(self.ticket is not None)
        self.close_button.setText("Schließen")
        if self.window.close_after_update:
            QTimer.singleShot(0, self.window.close)
        elif self.close_requested:
            self.close()

    def reject(self):
        self.close()

    def closeEvent(self, event):
        if self.busy:
            self.close_requested = True
            self.cancel()
            event.ignore()
        else:
            event.accept()
