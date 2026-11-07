import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
from PySide6.QtCore import QUrl
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import QApplication, QMessageBox
from .bridge import Engine
from .window import PlayerWindow


def run():
    parser = argparse.ArgumentParser(description="Vicious SID Player für Linux")
    parser.add_argument("files", nargs="*")
    parser.add_argument(
        "--engine",
        default=str(
            Path(__file__).resolve().parents[2] / "bin" / "vicious-sid-desktop-engine"
        ),
    )
    parser.add_argument("--support-dir")
    parser.add_argument("--root")
    args = parser.parse_args()
    app = QApplication(sys.argv[:1])
    app.setApplicationName("Vicious SID Player")
    app.setOrganizationName("ViciousSIDPlayer")
    app.setDesktopFileName("vicious-sid-player")
    app.setStyle("Fusion")
    base = Path(__file__).resolve().parents[2]
    support = args.support_dir or str(
        Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
        / "Vicious SID Player"
    )
    support = str(Path(support).expanduser().resolve())
    # Eine Instanz je Benutzer und Datenverzeichnis, auch bei „Öffnen mit“.
    server_name = "vicious-sid-" + hashlib.sha256(support.encode()).hexdigest()[:24]
    socket = QLocalSocket()
    socket.connectToServer(server_name)
    if socket.waitForConnected(300):
        socket.write((json.dumps(args.files) + "\n").encode())
        socket.waitForBytesWritten(1000)
        socket.disconnectFromServer()
        return 0
    server = QLocalServer()
    server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption)
    QLocalServer.removeServer(server_name)
    if not server.listen(server_name):
        QMessageBox.critical(
            None,
            "Vicious SID Player",
            "Die lokale App-Verbindung konnte nicht geöffnet werden.",
        )
        return 1
    arguments = ["--support-dir", support] + (
        ["--root", args.root] if args.root else []
    )
    engine = Engine(args.engine, arguments)
    version_file = base / "VERSION"
    version = (
        version_file.read_text().strip() if version_file.exists() else "development"
    )
    window = PlayerWindow(engine, base / "resources", version)

    def open_arguments(files):
        paths = []
        for value in files:
            url = QUrl(value)
            if url.scheme() == "vicioussid":
                engine.send("remote", url=value)
            elif url.isLocalFile():
                paths.append(url.toLocalFile())
            elif not url.scheme():
                paths.append(str(Path(value).resolve()))
        if paths:
            engine.send("open", paths=paths)

    connections = []

    def connect():
        client = server.nextPendingConnection()
        connections.append(client)
        client.disconnected.connect(
            lambda c=client: connections.remove(c) if c in connections else None
        )
        client.disconnected.connect(client.deleteLater)

        def read():
            if not client.canReadLine():
                return
            try:
                files = json.loads(bytes(client.readLine()))
                if files:
                    open_arguments(files)
                window.showNormal()
                window.raise_()
                window.activateWindow()
            except ValueError:
                pass
            client.disconnectFromServer()

        client.readyRead.connect(read)
        if client.bytesAvailable():
            read()

    server.newConnection.connect(connect)
    if args.files:
        engine.ready.connect(lambda data: open_arguments(args.files))
    app.styleHints().colorSchemeChanged.connect(
        lambda scheme: (
            window.apply_appearance()
            if window.settings.get("theme", "auto") == "auto"
            else None
        )
    )
    from .mpris import MPRIS

    window.mpris = MPRIS(window)
    window.show()
    result = app.exec()
    engine.close()
    server.close()
    return result


if __name__ == "__main__":
    sys.exit(run())
