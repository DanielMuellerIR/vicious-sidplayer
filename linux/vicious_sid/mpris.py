"""MPRIS über typisierte Qt-Adaptoren, ohne zusätzlichen Netzwerkdienst."""

import hashlib
from PySide6.QtCore import ClassInfo, Property, QUrl, Slot
from PySide6.QtDBus import (
    QDBusAbstractAdaptor,
    QDBusConnection,
    QDBusMessage,
    QDBusObjectPath,
)

ROOT = "org.mpris.MediaPlayer2"
PLAYER = ROOT + ".Player"
PATH = "/org/mpris/MediaPlayer2"


@ClassInfo(**{"D-Bus Interface": ROOT})
class RootAdaptor(QDBusAbstractAdaptor):
    def __init__(self, window):
        super().__init__(window)
        self.window = window

    @Slot()
    def Raise(self):
        self.window.showNormal()
        self.window.raise_()
        self.window.activateWindow()

    @Slot()
    def Quit(self):
        self.window.close()

    CanQuit = Property(bool, lambda self: True, constant=True)
    CanRaise = Property(bool, lambda self: True, constant=True)
    HasTrackList = Property(bool, lambda self: False, constant=True)
    Identity = Property(str, lambda self: "Vicious SID Player", constant=True)
    DesktopEntry = Property(str, lambda self: "vicious-sid-player", constant=True)
    SupportedUriSchemes = Property("QStringList", lambda self: ["file"], constant=True)
    SupportedMimeTypes = Property(
        "QStringList", lambda self: ["audio/prs.sid"], constant=True
    )


@ClassInfo(**{"D-Bus Interface": PLAYER})
class PlayerAdaptor(QDBusAbstractAdaptor):
    def __init__(self, window):
        super().__init__(window)
        self.window = window

    def track_id(self):
        key = (
            self.window.state.get("trackID", "")
            + ":"
            + str(self.window.state.get("subtune", 0))
        )
        return PATH + "/track/" + hashlib.sha256(key.encode()).hexdigest()

    @Slot()
    def Play(self):
        self.window.send("play")

    @Slot()
    def Pause(self):
        self.window.send("pause")

    @Slot()
    def PlayPause(self):
        self.window.send("toggle")

    @Slot()
    def Stop(self):
        self.window.send("stop")

    @Slot()
    def Next(self):
        self.window.send("next")

    @Slot()
    def Previous(self):
        self.window.send("previous")

    @Slot("qlonglong")
    def Seek(self, offset):
        self.window.skip(offset / 1000000)

    @Slot(QDBusObjectPath, "qlonglong")
    def SetPosition(self, track, position):
        if (
            track.path() == self.track_id()
            and 0 <= position / 1000000 <= self.window.state.get("duration", 0)
        ):
            self.window.send("seek", seconds=position / 1000000)

    @Slot(str)
    def OpenUri(self, uri):
        url = QUrl(uri)
        if url.isLocalFile() and url.toLocalFile().lower().endswith(".sid"):
            self.window.send("open", paths=[url.toLocalFile()])

    def metadata(self):
        state = self.window.state
        return {
            "mpris:trackid": QDBusObjectPath(self.track_id()),
            "xesam:title": state.get("title", ""),
            "xesam:artist": [state.get("composer", "")],
            "xesam:url": QUrl.fromLocalFile(state.get("path", "")).toString(),
        }

    def set_volume(self, value):
        self.window.send("volume", value=max(0, min(1, value)))

    def set_shuffle(self, value):
        self.window.change_setting("shuffle", value)

    PlaybackStatus = Property(
        str, lambda self: self.window.state.get("state", "Stopped")
    )
    Metadata = Property("QVariantMap", metadata)
    Position = Property(
        "qlonglong", lambda self: round(self.window.state.get("elapsed", 0) * 1000000)
    )
    Volume = Property(
        float, lambda self: float(self.window.state.get("volume", 1)), set_volume
    )
    Shuffle = Property(
        bool, lambda self: self.window.settings.get("shuffle", False), set_shuffle
    )
    Rate = Property(float, lambda self: 1.0, lambda self, value: None)
    MinimumRate = Property(float, lambda self: 1.0, constant=True)
    MaximumRate = Property(float, lambda self: 1.0, constant=True)
    CanPlay = Property(bool, lambda self: bool(self.window.state.get("trackID")))
    CanPause = Property(bool, lambda self: bool(self.window.state.get("trackID")))
    CanSeek = Property(bool, lambda self: bool(self.window.state.get("trackID")))
    CanControl = Property(bool, lambda self: True, constant=True)
    CanGoNext = Property(bool, lambda self: self.window.total > 1)
    CanGoPrevious = Property(bool, lambda self: self.window.total > 1)


class MPRIS:
    def __init__(self, window):
        self.window = window
        self.bus = QDBusConnection.sessionBus()
        self.root = RootAdaptor(window)
        self.player = PlayerAdaptor(window)
        self.previous = None
        self.active = self.bus.isConnected() and self.bus.registerService(
            "org.mpris.MediaPlayer2.vicioussid"
        )
        if self.active:
            self.bus.registerObject(
                PATH, window, QDBusConnection.RegisterOption.ExportAdaptors
            )
            window.engine.stateChanged.connect(self.changed)

    def changed(self, state):
        signature = (
            state.get("trackID"),
            state.get("subtune"),
            state.get("state"),
            state.get("volume"),
            self.window.settings.get("shuffle"),
        )
        if signature == self.previous:
            return
        self.previous = signature
        values = dict(
            PlaybackStatus=state.get("state", "Stopped"),
            Metadata=self.player.metadata(),
            Volume=float(state.get("volume", 1)),
            Shuffle=self.window.settings.get("shuffle", False),
        )
        signal = QDBusMessage.createSignal(
            PATH, "org.freedesktop.DBus.Properties", "PropertiesChanged"
        )
        signal.setArguments([PLAYER, values, []])
        self.bus.send(signal)
