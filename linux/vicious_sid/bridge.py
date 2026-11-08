import json
from PySide6.QtCore import QObject, QProcess, QTimer, Signal


class Engine(QObject):
    stateChanged = Signal(dict)
    libraryChanged = Signal(dict)
    ready = Signal(dict)
    failed = Signal(str)

    def __init__(self, binary, arguments=(), parent=None):
        super().__init__(parent)
        self.process = QProcess(self)
        self.buffer = bytearray()
        self.stderr = bytearray()
        self.state = {}
        self.closing = False
        self.include_visuals = True
        self.pending_poll = False
        self.pending_commands = []
        self.process.readyReadStandardOutput.connect(self.read)
        self.process.readyReadStandardError.connect(self.read_error)
        self.process.errorOccurred.connect(
            lambda error: (
                self.failed.emit(self.process.errorString())
                if not self.closing
                else None
            )
        )
        self.process.finished.connect(self.finished)
        self.timer = QTimer(self)
        self.timer.setInterval(33)
        self.timer.timeout.connect(self.poll)
        self.process.started.connect(self.started)
        self.process.start(str(binary), list(arguments))

    def started(self):
        for command in self.pending_commands:
            self.process.write(command)
        self.pending_commands.clear()
        self.timer.start()

    def send(self, op, **values):
        command = (
            json.dumps(dict(op=op, **values), ensure_ascii=False, allow_nan=False)
            + "\n"
        ).encode()
        if self.process.state() == QProcess.ProcessState.Running:
            self.process.write(command)
        elif self.process.state() == QProcess.ProcessState.Starting:
            self.pending_commands.append(command)

    def poll(self):
        if not self.pending_poll:
            self.pending_poll = True
            self.send("snapshot", visuals=self.include_visuals)

    def read(self):
        self.buffer.extend(bytes(self.process.readAllStandardOutput()))
        while b"\n" in self.buffer:
            line, _, self.buffer = self.buffer.partition(b"\n")
            try:
                message = json.loads(line)
            except (ValueError, UnicodeError):
                self.failed.emit(
                    "Die Audio-Engine hat eine ungültige Antwort geliefert."
                )
                continue
            event = message.get("event")
            if event == "state":
                self.pending_poll = False
                self.state.update(message)
                export = self.state.get("export", {})
                export["items"] = self.state.get("exportItems", [])
                export["selected"] = self.state.get("exportSelected", [])
                self.stateChanged.emit(self.state.copy())
            elif event == "library":
                self.libraryChanged.emit(message)
            elif event == "ready":
                self.ready.emit(message)
            elif event == "error":
                self.failed.emit(message.get("message", "Unbekannter Fehler"))

    def read_error(self):
        self.stderr.extend(bytes(self.process.readAllStandardError()))
        self.stderr = self.stderr[-8192:]

    def finished(self, code, status):
        self.timer.stop()
        if not self.closing:
            self.state["state"] = "Stopped"
            self.stateChanged.emit(self.state.copy())
            detail = self.stderr.decode(errors="replace").strip()
            self.failed.emit(f"Die Audio-Engine wurde beendet ({code}). {detail}")

    def close(self):
        self.closing = True
        self.timer.stop()
        self.send("quit")
        self.process.closeWriteChannel()
        if not self.process.waitForFinished(5000):
            self.process.terminate()
            if not self.process.waitForFinished(1000):
                self.process.kill()
                self.process.waitForFinished(1000)
