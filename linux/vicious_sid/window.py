from pathlib import Path
import time
from PySide6.QtCore import QEvent, QSize, Qt, QTimer
from PySide6.QtGui import QAction, QIcon, QKeySequence, QPixmap
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QFileDialog,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QListView,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMenu,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSlider,
    QSplitter,
    QSizePolicy,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)
from .theme import apply_theme
from .widgets import (
    FlowLayout,
    ElidingLabel,
    Segments,
    TrackDelegate,
    TrackModel,
    TrackView,
    TrackControls,
    ListeningView,
    icon,
    label,
    tool,
)
from .scope import Analysis


def clock(seconds):
    seconds = max(0, int(seconds or 0))
    return f"{seconds // 60}:{seconds % 60:02d}"


def row_widget(spacing=8, margins=(0, 0, 0, 0)):
    widget = QWidget()
    layout = QHBoxLayout(widget)
    layout.setContentsMargins(*margins)
    layout.setSpacing(spacing)
    return widget, layout


def line():
    widget = QWidget()
    widget.setFixedHeight(1)
    widget.setObjectName("separator")
    return widget


class PlayerWindow(QMainWindow):
    def __init__(self, engine, resources, version):
        super().__init__()
        self.engine = engine
        self.resources = Path(resources)
        self.version = version
        self.state = {}
        self.settings = {}
        self.colors = apply_theme(QApplication.instance(), False)
        self.rows = []
        self.total = 0
        self.page = 0
        self.list_signature = None
        self.history_signature = None
        self.mini = False
        self.full_size = QSize(1200, 700)
        self.dialogs = []
        self.shutting_down = False
        self.update_dialog = None
        self.close_after_update = False
        self.setWindowTitle("Vicious SID Player")
        self.setWindowIcon(QIcon(str(self.resources / "AppIcon.png")))
        self.setMinimumSize(800, 560)
        self.resize(self.full_size)
        self.setAcceptDrops(True)
        self.stack = QStackedWidget()
        self.setCentralWidget(self.stack)
        self.splitter = QSplitter(Qt.Orientation.Horizontal)
        self.splitter.setHandleWidth(1)
        self.stack.addWidget(self.splitter)
        self.build_sidebar()
        self.build_player()
        self.build_mini()
        self.build_menus()
        self.splitter.setSizes([240, 960])
        self.splitter.setStretchFactor(0, 0)
        self.splitter.setStretchFactor(1, 1)
        self.splitter.setChildrenCollapsible(False)
        self.engine.stateChanged.connect(self.refresh)
        self.engine.libraryChanged.connect(self.refresh_library)
        self.engine.ready.connect(self.ready)
        self.engine.failed.connect(self.report)
        self.search_timer = QTimer(self)
        self.search_timer.setSingleShot(True)
        self.search_timer.setInterval(180)
        self.search_timer.timeout.connect(self.search_now)
        self.update_timer = QTimer(self)
        self.update_timer.setInterval(24 * 60 * 60 * 1000)
        self.update_timer.timeout.connect(self.automatic_update_check)
        self.update_timer.start()
        self.apply_appearance()

    def send(self, op, **values):
        self.engine.send(op, **values)

    def button(self, title, op, **values):
        button = QPushButton(title)
        button.clicked.connect(lambda: self.send(op, **values))
        return button

    def build_sidebar(self):
        self.sidebar = QWidget()
        self.sidebar.setObjectName("sidebar")
        self.sidebar.setMinimumWidth(180)
        self.sidebar.setMaximumWidth(600)
        layout = QVBoxLayout(self.sidebar)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        header, h = row_widget(12, (16, 16, 16, 12))
        header.setFixedHeight(77)
        logo = QLabel()
        logo.setPixmap(
            QPixmap(str(self.resources / "AppIcon.png")).scaled(
                48,
                48,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
        )
        logo.setFixedSize(48, 48)
        h.addWidget(logo)
        titles = QVBoxLayout()
        titles.setSpacing(2)
        titles.addWidget(label("Vicious SID Player", 15, True))
        titles.addWidget(label("Native Linux App", 11, secondary=True))
        h.addLayout(titles)
        h.addStretch()
        layout.addWidget(header)
        layout.addWidget(line())
        tabs_widget = QWidget()
        tabs_layout = QVBoxLayout(tabs_widget)
        tabs_layout.setContentsMargins(10, 10, 10, 0)
        self.tabs = Segments(
            ["Musik", "Listen", "Folge", "Verlauf"],
            self.change_page,
            symbols=["music-list", "list-box", "queue", "history"],
        )
        self.tabs.setObjectName("library-sidebar-tabs")
        tabs_layout.addWidget(self.tabs)
        layout.addWidget(tabs_widget)
        collection = QPushButton("⇄  Sammlungsdaten …")
        collection.setProperty("plain", True)
        collection.setStyleSheet(
            "text-align: left; padding: 6px 12px; font-size: 11px;"
        )
        collection.clicked.connect(self.show_collection)
        layout.addWidget(collection)
        self.sidebar_pages = QStackedWidget()
        layout.addWidget(self.sidebar_pages, 1)
        self.build_library_page()
        self.build_lists_page()
        self.build_queue_page()
        self.build_history_page()
        layout.addWidget(line())
        self.metadata_panel = QWidget()
        meta = QVBoxLayout(self.metadata_panel)
        meta.setContentsMargins(12, 12, 12, 12)
        meta.setSpacing(6)
        self.metadata_labels = {}
        for title in ["TITLE", "COMPOSER", "INFO"]:
            widget, r = row_widget(4)
            key = label(title + ":", 11, True, secondary=True)
            key.setFixedWidth(80)
            r.addWidget(key)
            value = ElidingLabel("—")
            value.setStyleSheet("font-size:11px;")
            value.setWordWrap(False)
            value.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            r.addWidget(value, 1)
            meta.addWidget(widget)
            self.metadata_labels[title] = value
        self.sub_favorite = QPushButton("☆  Subtune 1 merken")
        self.sub_favorite.setProperty("plain", True)
        self.sub_favorite.setStyleSheet("text-align:left; font-size:11px;")
        self.sub_favorite.clicked.connect(lambda: self.send("subtuneFavorite"))
        meta.addWidget(self.sub_favorite)
        self.stil = QLabel()
        self.stil.setWordWrap(True)
        self.stil.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.stil.setStyleSheet("font-size:11px;")
        self.stil_scroll = QScrollArea()
        self.stil_scroll.setWidgetResizable(True)
        self.stil_scroll.setWidget(self.stil)
        self.stil_scroll.setMaximumHeight(140)
        self.stil_scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        self.stil_scroll.hide()
        meta.addWidget(self.stil_scroll)
        self.error = label("", 11)
        self.error.setObjectName("error")
        self.error.setWordWrap(True)
        self.error.hide()
        meta.addWidget(self.error)
        layout.addWidget(self.metadata_panel)
        self.splitter.addWidget(self.sidebar)

    def build_library_page(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        head, h = row_widget(4, (16, 10, 12, 6))
        self.library_title = label("BIBLIOTHEK", 11, True, True)
        h.addWidget(self.library_title)
        h.addStretch()
        self.library_controls = []
        self.folder_controls = []
        for name, text, op in [
            ("list", "Ordneransicht", "folders"),
            ("down", "Alle Ordner aufklappen", "expandAll"),
            ("up", "Alle Ordner zuklappen", "collapseAll"),
        ]:
            control = tool(
                name, text, lambda checked=False, action=op: self.send(action), size=19
            )
            self.library_controls.append(control)
            if op in ("expandAll", "collapseAll"):
                self.folder_controls.append(control)
                control.hide()
            h.addWidget(control)
        self.favorites_button = tool(
            "star", "Nur Favoriten zeigen", self.toggle_favorites, size=19
        )
        h.addWidget(self.favorites_button)
        clear = tool("trash", "Playlist leeren", lambda: self.send("clear"), size=19)
        h.addWidget(clear)
        self.library_controls.extend([self.favorites_button, clear])
        layout.addWidget(head)
        search_wrap = QWidget()
        sw = QVBoxLayout(search_wrap)
        sw.setContentsMargins(12, 0, 12, 6)
        self.search = QLineEdit()
        self.search.setPlaceholderText("Suchen")
        self.search.setClearButtonEnabled(True)
        self.search.setAccessibleName("Titel oder Ordner suchen")
        self.search.setFixedHeight(27)
        self.search.textChanged.connect(lambda: self.search_timer.start())
        sw.addWidget(self.search)
        layout.addWidget(search_wrap)
        helpers, hr = row_widget(10, (12, 0, 12, 6))
        self.saved_button = QPushButton("Suchansichten")
        self.saved_button.setStyleSheet("font-size:11px; padding:0 4px;")
        self.saved_menu = QMenu(self.saved_button)
        self.saved_button.setMenu(self.saved_menu)
        hr.addWidget(self.saved_button, 1)
        help_button = QPushButton("Suchhilfe")
        help_button.setStyleSheet("font-size:11px; padding:0 4px;")
        help_button.clicked.connect(self.search_help)
        help_button.setFixedWidth(74)
        hr.addWidget(help_button)
        layout.addWidget(helpers)
        actions, ar = row_widget(0, (12, 0, 12, 6))
        selection = QPushButton("Auswahl")
        selection.setStyleSheet("font-size:11px; text-align:left;")
        selection_menu = QMenu(selection)
        selection_menu.addAction(
            "Gesamte Bibliothek abspielen",
            lambda: self.send("queueScope", scope="library"),
        )
        selection_menu.addAction(
            "Sichtbare Auswahl abspielen", lambda: self.send("queueSelection")
        )
        selection_menu.addAction(
            "Favoriten abspielen", lambda: self.send("queueScope", scope="favorites")
        )
        selection_menu.addSeparator()
        selection_menu.addAction(
            "Sichtbare Auswahl als Hörfolge sichern …", self.create_list
        )
        selection_menu.addAction(
            "Aktuellen Ordner abspielen",
            lambda: self.send("queueScope", scope="folder"),
        )
        selection.setMenu(selection_menu)
        ar.addWidget(selection)
        layout.addWidget(actions)
        self.query_status = label("", 10, secondary=True)
        self.query_status.setContentsMargins(12, 0, 12, 4)
        self.query_status.hide()
        layout.addWidget(self.query_status)
        self.track_model = TrackModel(self)
        self.track_view = TrackView(self)
        self.track_view.setModel(self.track_model)
        self.track_view.setItemDelegate(TrackDelegate(self))
        self.track_view.setVerticalScrollMode(QListView.ScrollMode.ScrollPerPixel)
        self.track_view.setAccessibleName("Bibliothek")
        self.track_view.setObjectName("track-list")
        self.track_view.clicked.connect(self.select_track)
        self.track_view.activated.connect(self.select_track)
        self.track_view.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.track_view.customContextMenuRequested.connect(self.track_menu)
        layout.addWidget(self.track_view, 1)
        self.empty = label("Keine Treffer.", 12, secondary=True)
        self.empty.setParent(self.track_view.viewport())
        self.empty.setAlignment(Qt.AlignmentFlag.AlignHCenter)
        self.empty.setGeometry(0, 12, 240, 40)
        self.library_count = label("0 Titel", 10, secondary=True)
        self.library_count.setContentsMargins(12, 5, 12, 6)
        self.library_count.hide()
        layout.addWidget(self.library_count)
        self.sidebar_pages.addWidget(page)
        self.favorites_only = False

    def build_lists_page(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(10, 10, 10, 0)
        layout.setSpacing(8)
        head, h = row_widget(6)
        h.addWidget(label("HÖRFOLGEN", 11, True, True))
        h.addStretch()
        new = QPushButton("+")
        new.setFixedWidth(24)
        new.clicked.connect(lambda: self.create_list(empty=True))
        h.addWidget(new)
        layout.addWidget(head)
        self.lists_view = QComboBox()
        self.lists_view.setAccessibleName("Hörfolge")
        self.lists_view.currentIndexChanged.connect(self.show_list_entries)
        layout.addWidget(self.lists_view)
        self.list_controls = QWidget()
        controls = QVBoxLayout(self.list_controls)
        controls.setContentsMargins(0, 0, 0, 0)
        controls.setSpacing(8)
        row, r = row_widget(8)
        play = QPushButton("Abspielen")
        play.clicked.connect(lambda: self.list_action("playList"))
        self.list_play = play
        r.addWidget(play)
        r.addStretch()
        rename = QPushButton("✎")
        rename.setFixedWidth(22)
        rename.setToolTip("Hörfolge umbenennen")
        rename.clicked.connect(self.rename_list)
        self.list_rename = rename
        r.addWidget(rename)
        delete = tool(
            "trash", "Hörfolge löschen", lambda: self.list_action("deleteList"), size=22
        )
        r.addWidget(delete)
        controls.addWidget(row)
        append = QPushButton("Aktuellen Subtune hinzufügen")
        append.clicked.connect(lambda: self.list_action("appendCurrent"))
        self.list_append = append
        controls.addWidget(append)
        self.list_detail = label("", 10, secondary=True)
        self.list_detail.setWordWrap(True)
        controls.addWidget(self.list_detail)
        layout.addWidget(self.list_controls)
        self.list_empty = label(
            "Noch keine Hörfolgen\n\nSpeichere eine Auswahl aus der Bibliothek oder lege mit + eine Liste an.",
            11,
            secondary=True,
        )
        self.list_empty.setWordWrap(True)
        layout.addWidget(self.list_empty)
        self.list_entries = ListeningView(self)
        self.list_entries.setFrameShape(QListWidget.Shape.NoFrame)
        self.list_entries.setAccessibleName("Einträge der Hörfolge")
        self.list_entries.itemClicked.connect(self.play_list_entry)
        self.list_entries.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.list_entries.customContextMenuRequested.connect(self.list_entry_menu)
        layout.addWidget(self.list_entries, 1)
        self.sidebar_pages.addWidget(page)

    def build_queue_page(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(12, 8, 12, 8)
        self.queue_title = label("WARTESCHLANGE", 11, True, True)
        layout.addWidget(self.queue_title)
        self.queue_name = label("", 13, True)
        layout.addWidget(self.queue_name)
        self.queue_detail = label("", 10, secondary=True)
        layout.addWidget(self.queue_detail)
        controls, c = row_widget(8)
        save = QPushButton("Als Liste sichern")
        save.clicked.connect(self.save_queue)
        c.addWidget(save)
        c.addStretch()
        c.addWidget(
            tool("stop", "Hörfolge beenden", lambda: self.send("queueEnd"), size=22)
        )
        layout.addWidget(controls)
        self.queue_view = ListeningView(self, queue=True)
        self.queue_view.setFrameShape(QListWidget.Shape.NoFrame)
        self.queue_view.setAccessibleName("Aktive Hörfolge")
        self.queue_view.itemClicked.connect(
            lambda item: self.send(
                "queuePlay", id=item.data(Qt.ItemDataRole.UserRole)["id"]
            )
        )
        layout.addWidget(self.queue_view, 1)
        self.sidebar_pages.addWidget(page)

    def build_history_page(self):
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(12, 10, 12, 0)
        layout.setSpacing(8)
        header, h = row_widget(8)
        h.addWidget(label("VERLAUF", 11, True, True))
        h.addStretch()
        manage = QPushButton("⋯")
        manage.setFixedWidth(24)
        menu = QMenu(manage)
        menu.addAction(
            "Noch nie gehört",
            lambda: (self.focus_search(), self.search.setText("heard:never")),
        )
        menu.addAction("Verlauf leeren …", self.clear_history)
        manage.setMenu(menu)
        h.addWidget(manage)
        layout.addWidget(header)
        controls, c = row_widget(8)
        self.bookmark_button = QPushButton("Marke")
        self.bookmark_button.clicked.connect(self.add_bookmark)
        c.addWidget(self.bookmark_button)
        self.note_button = QPushButton("Notiz")
        notes = QMenu(self.note_button)
        notes.addAction("Notiz zum Subtune", lambda: self.edit_note(False))
        notes.addAction("Notiz zur Datei", lambda: self.edit_note(True))
        self.note_button.setMenu(notes)
        c.addWidget(self.note_button)
        c.addStretch()
        layout.addWidget(controls)
        self.history_tabs = Segments(
            ["Hören", "Marken", "Notizen"], lambda i: self.show_history(i)
        )
        layout.addWidget(self.history_tabs)
        self.history_view = QListWidget()
        self.history_view.setFrameShape(QListWidget.Shape.NoFrame)
        self.history_view.setWordWrap(True)
        self.history_view.setStyleSheet("background:transparent; border:0;")
        self.history_view.setAccessibleName("Hörverlauf und Lesezeichen")
        self.history_view.itemDoubleClicked.connect(self.play_history_item)
        self.history_view.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.history_view.customContextMenuRequested.connect(self.history_menu)
        layout.addWidget(self.history_view, 1)
        layout.addWidget(
            label("Bis zu 2.000 Wiedergaben · 180 Tage", 10, secondary=True)
        )
        self.sidebar_pages.addWidget(page)
        self.history_page = 0

    def build_player(self):
        panel = QWidget()
        panel.setObjectName("surface")
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        toolbar = QWidget()
        toolbar.setObjectName("toolbar")
        toolbar.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        flow = FlowLayout(toolbar)
        track = TrackControls()
        t = QHBoxLayout(track)
        t.setContentsMargins(0, 0, 0, 0)
        t.setSpacing(10)
        t.addWidget(label("TUNE:", 12, True, True))
        self.tune_button = QPushButton("— Auswählen —")
        self.tune_button.setFixedWidth(150)
        track.tune_menu = self.tune_button
        self.tune_menu = QMenu(self.tune_button)
        self.tune_menu.aboutToShow.connect(self.populate_tune_menu)
        self.tune_button.setMenu(self.tune_menu)
        t.addWidget(self.tune_button)
        open_button = QPushButton("Öffnen…")
        open_button.clicked.connect(self.open_files)
        t.addWidget(open_button)
        self.auto_next = QCheckBox("AUTO NEXT")
        self.auto_next.setChecked(True)
        self.auto_next.toggled.connect(
            lambda value: self.change_setting("autoNext", value)
        )
        t.addWidget(self.auto_next)
        options = tool("settings", "Wiedergabeoptionen", self.show_playback, size=20)
        options.setFixedWidth(40)
        options.setProperty("plain", False)
        t.addWidget(options)
        flow.addWidget(track)
        sound, s = row_widget(10)
        self.model_box = QComboBox()
        self.model_box.addItems(["SID: Auto", "6581", "8580"])
        self.model_box.setFixedWidth(110)
        self.model_box.setAccessibleName("SID-Chip-Modell")
        self.model_box.currentIndexChanged.connect(
            lambda i: self.send("model", value=[0, 6581, 8580][i])
        )
        s.addWidget(self.model_box)
        self.clock_box = QComboBox()
        self.clock_box.addItems(["Auto: PAL", "PAL", "NTSC"])
        self.clock_box.setFixedWidth(120)
        self.clock_box.setAccessibleName("C64-Takt")
        self.clock_box.currentIndexChanged.connect(
            lambda i: self.send("clock", value=["auto", "pal", "ntsc"][i])
        )
        s.addWidget(self.clock_box)
        flow.addWidget(sound)
        self.subtune_widget, st = row_widget(8)
        self.sub_prev = tool(
            "previous", "Vorheriger Subtune", lambda: self.subtune(-1), "#007aff", 20
        )
        st.addWidget(self.sub_prev)
        self.subtune_label = label("1/1", 12, True)
        st.addWidget(self.subtune_label)
        st.addWidget(
            tool("next", "Nächster Subtune", lambda: self.subtune(1), "#007aff", 20)
        )
        flow.addWidget(self.subtune_widget)
        transport, tr = row_widget(12)
        self.transport_buttons = {}
        for name, text, op in [
            ("shuffle", "Zufallswiedergabe", None),
            ("previous", "Vorheriger Eintrag der Hörfolge", "previous"),
            ("back15", "15 Sekunden zurück", None),
            ("play", "Wiedergabe", "toggle"),
            ("forward30", "30 Sekunden vor", None),
            ("next", "Nächster Eintrag der Hörfolge", "next"),
            ("stop", "Stopp", "stop"),
        ]:
            cb = (
                (lambda checked=False, action=op: self.send(action))
                if op
                else {
                    "shuffle": self.toggle_shuffle,
                    "back15": lambda: self.skip(-15),
                    "forward30": lambda: self.skip(30),
                }[name]
            )
            button = tool(name, text, cb, size=20)
            self.transport_buttons[name] = button
            tr.addWidget(button)
        flow.addWidget(transport)
        layout.addWidget(toolbar)
        layout.addWidget(line())
        scrubber, sc = row_widget(12, (16, 8, 16, 8))
        scrubber.setObjectName("scrubber")
        scrubber.setFixedHeight(38)
        self.elapsed = label("0:00", 12, secondary=True)
        self.elapsed.setMinimumWidth(44)
        self.elapsed.setStyleSheet('font-family: "Liberation Mono"; font-size:12px;')
        sc.addWidget(self.elapsed)
        self.seek_slider = QSlider(Qt.Orientation.Horizontal)
        self.seek_slider.setRange(0, 360000)
        self.seek_slider.setAccessibleName("Wiedergabeposition")
        self.seek_slider.sliderReleased.connect(
            lambda: self.send("seek", seconds=self.seek_slider.value() / 1000)
        )
        self.seek_slider.actionTriggered.connect(self.seek_action)
        sc.addWidget(self.seek_slider, 1)
        self.duration = label("6:00", 12, secondary=True)
        self.duration.setMinimumWidth(44)
        self.duration.setStyleSheet('font-family: "Liberation Mono"; font-size:12px;')
        sc.addWidget(self.duration)
        sc.addWidget(label("VOL:", 12, True, True))
        self.volume = QSlider(Qt.Orientation.Horizontal)
        self.volume.setRange(0, 100)
        self.volume.setValue(100)
        self.volume.setFixedWidth(70)
        self.volume.setAccessibleName("Lautstärke")
        self.volume.valueChanged.connect(lambda v: self.send("volume", value=v / 100))
        sc.addWidget(self.volume)
        layout.addWidget(scrubber)
        layout.addWidget(line())
        loopbar = QWidget()
        loopbar.setObjectName("loopbar")
        self.loopbar = loopbar
        loopbar.setFixedHeight(78)
        lp = QVBoxLayout(loopbar)
        lp.setContentsMargins(16, 8, 16, 8)
        lp.setSpacing(6)
        buttons, br = row_widget(8)
        self.loop_a = self.button("A setzen", "loopA")
        self.loop_b = self.button("B setzen", "loopB")
        br.addWidget(self.loop_a)
        br.addWidget(self.loop_b)
        self.loop_toggle = QCheckBox("A/B")
        self.loop_toggle.setAccessibleName("A/B-Schleife")
        self.loop_toggle.clicked.connect(lambda: self.send("loopToggle"))
        br.addWidget(self.loop_toggle)
        br.addStretch()
        br.addWidget(
            tool("close", "A/B-Marker löschen", lambda: self.send("loopClear"), size=20)
        )
        lp.addWidget(buttons)
        self.loop_label = label("A — · B —", 12, secondary=True)
        self.loop_label.setStyleSheet('font-family: "Liberation Mono"; font-size:12px;')
        lp.addWidget(self.loop_label)
        lp.addWidget(
            label(
                "Mindestens 0,25 s. Ein Sprung außerhalb A/B schaltet die Schleife aus.",
                11,
                secondary=True,
            )
        )
        self.loop_status = label("Schleife wird vorbereitet …", 11, secondary=True)
        self.loop_status.hide()
        lp.addWidget(self.loop_status)
        layout.addWidget(loopbar)
        layout.addWidget(line())
        self.analysis = Analysis(self)
        layout.addWidget(self.analysis, 1)
        self.splitter.addWidget(panel)

    def build_mini(self):
        widget, r = row_widget(14, (16, 12, 16, 12))
        logo = QLabel()
        logo.setPixmap(
            QPixmap(str(self.resources / "AppIcon.png")).scaled(
                34,
                34,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
        )
        logo.setFixedSize(34, 34)
        r.addWidget(logo)
        titles = QVBoxLayout()
        titles.setSpacing(2)
        self.mini_title = label("Vicious SID Player", 13, True)
        self.mini_composer = ElidingLabel("—")
        self.mini_composer.setObjectName("secondary")
        self.mini_composer.setStyleSheet("font-size:11px;")
        titles.addWidget(self.mini_title)
        titles.addWidget(self.mini_composer)
        r.addLayout(titles, 1)
        self.mini_time = label("0:00 / 6:00", 11, secondary=True)
        self.mini_time.setStyleSheet('font-family: "Liberation Mono"; font-size:11px;')
        r.addWidget(self.mini_time)
        self.mini_play = tool(
            "play", "Wiedergabe / Pause", lambda: self.send("toggle"), size=20
        )
        r.addWidget(
            tool("previous", "Vorheriger Titel", lambda: self.send("previous"), size=20)
        )
        r.addWidget(self.mini_play)
        r.addWidget(tool("next", "Nächster Titel", lambda: self.send("next"), size=20))
        r.addWidget(tool("mini", "Vollansicht", self.toggle_mini, size=20))
        self.stack.addWidget(widget)

    def build_menus(self):
        menu = self.menuBar()
        file = menu.addMenu("Datei")
        playback = menu.addMenu("Wiedergabe")
        view = menu.addMenu("Darstellung")
        help_menu = menu.addMenu("Hilfe")

        def action(target, title, callback, shortcut=None):
            item = QAction(title, self)
            item.triggered.connect(callback)
            if shortcut:
                item.setShortcut(QKeySequence(shortcut))
            target.addAction(item)
            return item

        action(file, "Öffnen …", self.open_files, "Ctrl+O")
        action(file, "Ordner öffnen …", self.open_folder, "Ctrl+Shift+O")
        action(file, "Audio exportieren …", self.show_export, "Ctrl+E")
        file.addSeparator()
        action(file, "Einstellungen …", self.show_settings, "Ctrl+,")
        action(file, "Sammlungsdaten …", self.show_collection)
        action(file, "Beenden", self.close, "Ctrl+Q")
        action(playback, "Wiedergabe / Pause", lambda: self.send("toggle"), "Space")
        action(playback, "Stopp", lambda: self.send("stop"), "Ctrl+.")
        action(playback, "Nächster Titel", lambda: self.send("next"), "Ctrl+Right")
        action(playback, "Vorheriger Titel", lambda: self.send("previous"), "Ctrl+Left")
        action(playback, "Wiedergabeoptionen …", self.show_playback)
        action(view, "Mini-Player", self.toggle_mini, "Ctrl+M")
        action(view, "Hell / Dunkel", self.toggle_theme, "Ctrl+T")
        action(view, "Bibliothek abgleichen", lambda: self.send("rescan"), "F5")
        action(view, "Suchen", self.focus_search, "Ctrl+F")
        action(help_menu, "Nach Updates suchen …", self.show_updates)
        action(
            help_menu,
            "Über Vicious SID Player",
            lambda: QMessageBox.about(
                self,
                "Vicious SID Player",
                f"Vicious SID Player {self.version}\n\nEntwickelt von Daniel Müller.\nSID-/6502-Emulation aus jsSID 0.9.1 von Hermit (Mihály Horváth).\nProjektcode: WTFPL.\nQt / PySide6: LGPLv3; Lizenztexte liegen bei.",
            ),
        )

    def ready(self, message):
        self.settings = message.get("settings", {})
        self.settings["root"] = message["root"]
        self.auto_next.blockSignals(True)
        self.auto_next.setChecked(self.settings.get("autoNext", True))
        self.auto_next.blockSignals(False)
        self.apply_appearance()
        if self.settings.get("mini", False):
            self.toggle_mini()
        if isinstance(self.settings.get("sidebarWidth"), int):
            self.splitter.setSizes(
                [
                    self.settings["sidebarWidth"],
                    max(560, self.width() - self.settings["sidebarWidth"]),
                ]
            )
        self.send("snapshot")
        QTimer.singleShot(3000, self.automatic_update_check)

    def show_updates(self):
        if self.update_dialog is None:
            from .update_dialog import UpdateDialog
            self.update_dialog = UpdateDialog(self)
        self.update_dialog.check()

    def automatic_update_check(self):
        from .update import Updater, UpdateError
        if (self.shutting_down or not self.settings.get("automaticUpdates", True)
                or time.time() - self.settings.get("lastUpdateCheck", 0) < 86400):
            return
        try:
            Updater(self.resources.parent).installation()
        except (OSError, UpdateError):
            return
        self.change_setting("lastUpdateCheck", time.time())
        if self.update_dialog is None:
            from .update_dialog import UpdateDialog
            self.update_dialog = UpdateDialog(self)
        self.update_dialog.check(automatic=True)

    def apply_appearance(self):
        mode = self.settings.get("theme", "auto")
        dark = (
            mode == "dark"
            or mode == "auto"
            and QApplication.styleHints().colorScheme() == Qt.ColorScheme.Dark
        )
        self.colors = apply_theme(QApplication.instance(), dark)
        self.dark = dark
        self.setStyleSheet(f"QWidget#separator {{background:{self.colors['border']};}}")
        for index, name in enumerate(["music-list", "list-box", "queue", "history"]):
            self.tabs.group.button(index).setIcon(icon(name, self.colors["text"], 15))
        self.track_view.viewport().update()
        self.analysis.refresh()

    def refresh(self, state):
        old_state = self.state
        self.state = state
        for key, value in [
            ("TITLE", state.get("title", "—")),
            ("COMPOSER", state.get("composer", "—")),
            ("INFO", state.get("info", "—")),
        ]:
            self.metadata_labels[key].setText(value)
        title = state.get("title", "—")
        tune_name = state.get("filename", "— Auswählen —")
        self.tune_button.setText(
            self.tune_button.fontMetrics().elidedText(
                tune_name,
                Qt.TextElideMode.ElideRight,
                max(0, self.tune_button.width() - 28),
            )
        )
        self.tune_button.setToolTip(title)
        self.elapsed.setText(clock(state.get("elapsed")))
        self.duration.setText(clock(state.get("duration")))
        self.duration.setToolTip(
            "Songlänge: " + state.get("durationSource", "fallback")
        )
        if not self.seek_slider.isSliderDown():
            self.seek_slider.blockSignals(True)
            self.seek_slider.setMaximum(round(state.get("duration", 360) * 1000))
            self.seek_slider.setValue(round(state.get("elapsed", 0) * 1000))
            self.seek_slider.blockSignals(False)
        self.seek_slider.setEnabled(
            bool(state.get("trackID")) and not state.get("seeking")
        )
        if not self.volume.isSliderDown():
            self.volume.blockSignals(True)
            self.volume.setValue(round(state.get("volume", 1) * 100))
            self.volume.blockSignals(False)
        self.subtune_widget.setVisible(state.get("subtunes", 1) > 1)
        self.subtune_label.setText(
            f"{state.get('subtune', 0) + 1}/{state.get('subtunes', 1)}"
        )
        self.sub_favorite.setText(
            f"{'★' if state.get('subtuneFavorite') else '☆'}  Subtune {state.get('subtune', 0) + 1} {'gemerkt' if state.get('subtuneFavorite') else 'merken'}"
        )
        self.sub_favorite.setVisible(bool(state.get("trackID")))
        self.model_box.blockSignals(True)
        self.model_box.setCurrentIndex(
            {0: 0, 6581: 1, 8580: 2}.get(state.get("model"), 0)
        )
        self.model_box.blockSignals(False)
        self.clock_box.blockSignals(True)
        self.clock_box.setItemText(0, "Auto: " + state.get("clockLabel", "PAL"))
        self.clock_box.setCurrentIndex(
            {"auto": 0, "pal": 1, "ntsc": 2}.get(state.get("clock"), 0)
        )
        self.clock_box.blockSignals(False)
        for name, button in self.transport_buttons.items():
            active = state.get("state") == "Playing"
            draw_name = ("pause" if active else "play") if name == "play" else name
            color = (
                self.colors["accent"]
                if name == "shuffle"
                and self.settings.get("shuffle")
                or name == "play"
                and active
                else (
                    "#34c759"
                    if name == "play"
                    else "#ff453a"
                    if name == "stop"
                    else self.colors["text"]
                )
            )
            button.setIcon(icon(draw_name, color))
            if name == "play":
                button.setAccessibleName("Pause" if active else "Wiedergabe")
        self.mini_composer.setText(state.get("composer", "—"))
        self.mini_time.setText(
            clock(state.get("elapsed")) + " / " + clock(state.get("duration"))
        )
        self.mini_play.setIcon(self.transport_buttons["play"].icon())
        self.mini_title.setText(
            self.mini_title.fontMetrics().elidedText(
                title, Qt.TextElideMode.ElideRight, max(120, self.width() - 320)
            )
        )
        a, b = state.get("loopA"), state.get("loopB")
        self.loop_label.setText(
            f"A {str(round(a, 2)) + ' s' if a is not None else '—'} · B {str(round(b, 2)) + ' s' if b is not None else '—'}"
        )
        self.loop_toggle.setEnabled(a is not None and b is not None)
        self.loop_toggle.setChecked(state.get("loopEnabled", False))
        preparing = state.get("loopPreparing", False)
        self.loop_status.setVisible(preparing)
        self.loopbar.setFixedHeight(97 if preparing else 78)
        self.loop_a.setEnabled(bool(state.get("trackID")))
        self.loop_b.setEnabled(a is not None)
        if state.get("stil") != old_state.get("stil"):
            self.stil.setText(
                "STIL\n"
                + "\n\n".join(
                    f"{field['label']}\n{field['value']}"
                    for field in state.get("stil", [])
                )
            )
            self.stil_scroll.setVisible(bool(state.get("stil")))
        self.library_title.setText(
            "BIBLIOTHEK" + ("  ◌" if state.get("scanning") else "")
        )
        if state.get("error"):
            self.report(state["error"])
        elif self.error.isVisible():
            self.error.hide()
        if state.get("trackID") != old_state.get("trackID"):
            self.track_view.viewport().update()
        self.bookmark_button.setEnabled(bool(state.get("trackID")))
        self.note_button.setEnabled(bool(state.get("trackID")))
        self.analysis.refresh()
        doc = state.get("listening", {})
        if doc != self.list_signature:
            self.list_signature = doc
            self.refresh_lists(doc)
        history = state.get("history", {})
        if history != self.history_signature:
            self.history_signature = history
            if self.page == 3:
                self.show_history(self.history_page)
        for dialog in self.dialogs[:]:
            if dialog.isVisible() and hasattr(dialog, "refresh"):
                dialog.refresh(state)

    def refresh_library(self, value):
        scroll = self.track_view.verticalScrollBar().value()
        self.rows = value.get("rows", [])
        self.tune_rows = value.get("tunes", [])
        self.total = value.get("count", 0)
        self.track_model.replace(self.rows)
        self.track_view.verticalScrollBar().setValue(
            0 if getattr(self, "_reset_library_scroll", False) else scroll
        )
        self._reset_library_scroll = False
        for control in self.library_controls:
            control.setVisible(self.total > 0)
        for control in self.folder_controls:
            control.setVisible(self.total > 0 and value.get("folders", False))
        self.empty.setVisible(self.total == 0)
        self.library_count.setText(
            f"{value.get('visible', 0)} / {self.total} Titel"
            if value.get("visible") != self.total
            else f"{self.total} Titel"
        )
        status = value.get("queryError", "") or (
            f"Metadaten: {value.get('indexed', 0)}/{value.get('total', 0)}"
            if value.get("indexing")
            else ""
        )
        self.query_status.setText(status)
        self.query_status.setVisible(bool(status))
        self.saved_menu.clear()
        self.saved_menu.addAction("Aktuelle Suche sichern …", self.save_search)
        for search in value.get("saved", {}).get("searches", []):
            self.saved_menu.addAction(
                search["name"], lambda checked=False, s=search: self.restore_search(s)
            )

    def select_track(self, index):
        row = index.data(Qt.ItemDataRole.UserRole)
        if row.get("folderRow"):
            self.send("expand", id=row["id"])
        else:
            self.send("select", index=row["index"])

    def track_menu(self, point):
        index = self.track_view.indexAt(point)
        if not index.isValid():
            return
        row = index.data(Qt.ItemDataRole.UserRole)
        if row.get("folderRow"):
            return
        menu = QMenu(self)
        menu.addAction(
            "Als Nächstes", lambda: self.send("enqueueNext", trackID=row["id"])
        )
        lists = menu.addMenu("Zu Hörfolge hinzufügen")
        for value in self.state.get("listening", {}).get("lists", []):
            lists.addAction(
                value["name"],
                lambda checked=False, v=value: self.send(
                    "appendTrack", id=v["id"], trackID=row["id"]
                ),
            )
        menu.addAction(
            "Neue Hörfolge mit diesem Titel …",
            lambda: self.create_list(track_id=row["id"]),
        )
        menu.addAction(
            "Favorit entfernen" if row.get("favorite") else "Als Favorit merken",
            lambda: self.send("favorite", id=row["id"]),
        )
        menu.addAction(
            "Abspielen",
            lambda: (self.send("select", index=row["index"]), self.send("play")),
        )
        menu.exec(self.track_view.viewport().mapToGlobal(point))

    def populate_tune_menu(self):
        self.tune_menu.clear()
        for row in getattr(self, "tune_rows", []):
            self.tune_menu.addAction(
                row["name"],
                lambda checked=False, r=row: self.send("select", index=r["index"]),
            )
        if self.total > 300:
            self.tune_menu.addAction(
                "Weitere Titel: links in der Liste suchen"
            ).setEnabled(False)

    def search_now(self):
        self._reset_library_scroll = True
        self.send(
            "library", query=self.search.text(), favoritesOnly=self.favorites_only
        )

    def toggle_favorites(self):
        self.favorites_only = not self.favorites_only
        self.favorites_button.setIcon(
            icon("star", "#ffcc00" if self.favorites_only else self.colors["secondary"])
        )
        self.search_now()

    def search_help(self):
        QMessageBox.information(
            self,
            "Suchhilfe",
            'Wörter durchsuchen Dateiname, Ordner und Metadaten.\n\nFelder: title:, author:, released:, chips:, model:\nDauer von Subtune 1: min:1:00 max:3:00\nHörstatus: heard:never heard:yes heard:unknown\nUnbekannt: duration:unknown model:unknown metadata:unknown\n\nBegriffe gelten zusammen. Leerzeichen: author:"Rob Hubbard"',
        )

    def save_search(self):
        name, ok = QInputDialog.getText(self, "Suchansicht sichern", "Name")
        if ok and name.strip():
            self.send("saveSearch", name=name)

    def restore_search(self, search):
        self.search.setText(search["query"])
        self.favorites_only = search["favoritesOnly"]
        self.search_now()

    def change_page(self, index):
        self.page = index
        self.sidebar_pages.setCurrentIndex(index)
        if index == 3:
            self.show_history(self.history_page)

    def focus_search(self):
        self.change_page(0)
        self.tabs.select(0)
        self.search.setFocus()
        self.search.selectAll()

    def subtune(self, offset):
        self.send(
            "subtune",
            value=(self.state.get("subtune", 0) + offset)
            % self.state.get("subtunes", 1),
        )

    def skip(self, seconds):
        self.send("seek", seconds=max(0, self.state.get("elapsed", 0) + seconds))

    def seek_action(self, action):
        if not self.seek_slider.isSliderDown():
            QTimer.singleShot(
                0,
                lambda: self.send(
                    "seek", seconds=self.seek_slider.sliderPosition() / 1000
                ),
            )

    def change_setting(self, name, value):
        self.settings[name] = value
        self.send("settings", values={name: value})
        if name == "scopeQuality":
            self.analysis.scope.refresh()

    def toggle_shuffle(self):
        self.change_setting("shuffle", not self.settings.get("shuffle", False))

    def toggle_theme(self):
        self.change_setting("theme", "light" if self.dark else "dark")
        self.apply_appearance()

    def toggle_mini(self):
        if self.mini:
            self.mini = False
            self.setMinimumSize(800, 560)
            self.stack.setCurrentIndex(0)
            self.resize(self.full_size)
            self.menuBar().show()
        else:
            self.full_size = self.size()
            self.mini = True
            self.setMinimumSize(420, 64)
            self.stack.setCurrentIndex(1)
            self.menuBar().hide()
            self.resize(560, 64)
        self.change_setting("mini", self.mini)
        self.analysis.scope.sync_activity()

    def report(self, message):
        self.error.setText(message)
        self.error.show()

    def open_files(self):
        paths, _ = QFileDialog.getOpenFileNames(
            self,
            "SID-Dateien öffnen",
            self.settings.get("root", str(Path.home())),
            "SID-Musik (*.sid *.SID)",
        )
        if paths:
            self.send("open", paths=paths)

    def open_folder(self):
        folder = QFileDialog.getExistingDirectory(
            self, "SID-Ordner öffnen", self.settings.get("root", str(Path.home()))
        )
        if folder:
            self.send("open", paths=[folder])

    def dragEnterEvent(self, event):
        if event.mimeData().hasUrls():
            event.acceptProposedAction()

    def dropEvent(self, event):
        paths = [
            url.toLocalFile() for url in event.mimeData().urls() if url.isLocalFile()
        ]
        if paths:
            self.send("open", paths=paths)
            event.acceptProposedAction()

    def refresh_lists(self, doc):
        selected = self.lists_view.currentData()
        selected_id = selected["id"] if selected else None
        self.lists_view.blockSignals(True)
        self.lists_view.clear()
        for value in doc.get("lists", []):
            self.lists_view.addItem(value["name"], value)
        for index in range(self.lists_view.count()):
            if self.lists_view.itemData(index)["id"] == selected_id:
                self.lists_view.setCurrentIndex(index)
        self.lists_view.blockSignals(False)
        self.lists_view.setVisible(self.lists_view.count() > 0)
        self.list_controls.setVisible(self.lists_view.count() > 0)
        self.list_empty.setVisible(self.lists_view.count() == 0)
        queue = doc.get("queue") or {}
        current = queue.get("currentID")
        selected = self.queue_view.currentItem()
        selected_id = (
            selected.data(Qt.ItemDataRole.UserRole)["id"] if selected else None
        )
        self.queue_view.clear()
        self.queue_name.setText(queue.get("name", "Noch keine Hörfolge"))
        items = queue.get("items", [])
        position = next(
            (i + 1 for i, value in enumerate(items) if value["id"] == current), 0
        )
        self.queue_detail.setText(
            f"{position} / {len(items)} · "
            + ("Zufall" if queue.get("shuffled") else "Reihenfolge")
            if items
            else "Starte eine Auswahl in der Bibliothek oder eine gespeicherte Liste."
        )
        for entry in queue.get("items", []):
            item = QListWidgetItem(
                ("▶ " if entry["id"] == current else "") + self.entry_title(entry)
            )
            item.setData(Qt.ItemDataRole.UserRole, entry)
            self.queue_view.addItem(item)
            if entry["id"] == selected_id:
                self.queue_view.setCurrentItem(item)
        self.show_list_entries()

    def entry_title(self, entry):
        return (
            Path(entry["trackID"]).stem
            + "\n"
            + (
                f"Subtune {entry['subtune'] + 1}"
                if entry.get("subtune") is not None
                else "Alle Subtunes"
            )
        )

    def show_list_entries(self):
        selected = self.list_entries.currentItem()
        selected_id = (
            selected.data(Qt.ItemDataRole.UserRole)["id"] if selected else None
        )
        self.list_entries.clear()
        current = self.lists_view.currentData()
        if current:
            same_library = current.get("libraryID") == self.state.get("activeLibraryID")
            self.list_play.setEnabled(same_library)
            self.list_append.setEnabled(
                same_library and bool(self.state.get("trackID"))
            )
            self.list_entries.setEnabled(same_library)
            self.list_rename.setVisible(current.get("kind") == "regular")
            entries = current.get("entries", [])
            self.list_detail.setText(
                f"{len(entries)} Einträge · Änderungen gelten beim nächsten Start"
            )
            for entry in entries:
                item = QListWidgetItem(self.entry_title(entry))
                item.setData(Qt.ItemDataRole.UserRole, entry)
                self.list_entries.addItem(item)
                if entry["id"] == selected_id:
                    self.list_entries.setCurrentItem(item)

    def play_list_entry(self, item):
        current = self.lists_view.currentData()
        if current:
            self.send(
                "playList",
                id=current["id"],
                entryID=item.data(Qt.ItemDataRole.UserRole)["id"],
            )

    def list_entry_menu(self, point):
        item = self.list_entries.itemAt(point)
        current = self.lists_view.currentData()
        if not item or not current:
            return
        entry = item.data(Qt.ItemDataRole.UserRole)
        args = dict(id=entry["id"], listID=current["id"])
        menu = QMenu(self)
        menu.addAction("Nach oben", lambda: self.send("listMove", offset=-1, **args))
        menu.addAction("Nach unten", lambda: self.send("listMove", offset=1, **args))
        menu.addAction("Entfernen", lambda: self.send("listRemove", **args))
        menu.addSeparator()
        menu.addAction(
            "Alle Subtunes", lambda: self.send("listSubtune", value=None, **args)
        )

        def choose_subtune():
            value, ok = QInputDialog.getInt(
                self,
                "Subtune auswählen",
                "Subtune (ab 1)",
                (entry.get("subtune") or 0) + 1,
                1,
                256,
            )
            if ok:
                self.send("listSubtune", value=value - 1, **args)

        menu.addAction("Subtune auswählen …", choose_subtune)
        menu.exec(self.list_entries.mapToGlobal(point))

    def list_action(self, op, **values):
        current = self.lists_view.currentData()
        if current:
            if (
                op == "deleteList"
                and QMessageBox.question(
                    self,
                    "Liste löschen?",
                    "Die gespeicherte Hörfolge löschen? Die Musikdateien bleiben erhalten.",
                )
                != QMessageBox.StandardButton.Yes
            ):
                return
            self.send(op, id=current["id"], **values)

    def queue_action(self, op, **values):
        item = self.queue_view.currentItem()
        if item:
            self.send(op, id=item.data(Qt.ItemDataRole.UserRole)["id"], **values)

    def create_list(self, empty=False, track_id=None):
        name, ok = QInputDialog.getText(
            self, "Neue Hörfolge" if empty else "Auswahl als Hörfolge sichern", "Name"
        )
        if ok and name.strip():
            values = dict(name=name, empty=empty)
            if track_id:
                values["trackID"] = track_id
            self.send("createList", **values)

    def rename_list(self):
        current = self.lists_view.currentData()
        if current:
            name, ok = QInputDialog.getText(
                self, "Hörfolge umbenennen", "Name", text=current["name"]
            )
            if ok and name.strip():
                self.list_action("renameList", name=name)

    def save_queue(self):
        name, ok = QInputDialog.getText(self, "Hörfolge sichern", "Name")
        if ok and name.strip():
            self.send("saveQueue", name=name)

    def show_history(self, index):
        scroll = (
            self.history_view.verticalScrollBar().value()
            if self.history_page == index
            else 0
        )
        selected = self.history_view.currentItem()
        selected_id = (
            selected.data(Qt.ItemDataRole.UserRole)["id"] if selected else None
        )
        self.history_page = index
        self.history_view.clear()
        doc = self.state.get("history", {})
        key = ["events", "bookmarks", "notes"][index]
        for entry in reversed(doc.get(key, [])):
            ref = entry["reference"]
            title = entry.get("title") or entry.get("name") or Path(ref["trackID"]).stem
            text = (
                f"{title}\nSubtune {(ref.get('subtune') or 0) + 1} · {clock(entry.get('lastPosition', entry.get('position', 0)))}"
                if index < 2
                else f"{title}\n{entry.get('text', '')}"
            )
            item = QListWidgetItem(text)
            item.setData(Qt.ItemDataRole.UserRole, entry)
            self.history_view.addItem(item)
            if entry["id"] == selected_id:
                self.history_view.setCurrentItem(item)
        self.history_view.verticalScrollBar().setValue(scroll)

    def play_history_item(self, item):
        entry = item.data(Qt.ItemDataRole.UserRole)
        ref = entry["reference"]
        self.send(
            "playReference",
            trackID=ref["trackID"],
            subtune=ref.get("subtune") or 0,
            position=entry.get("position", entry.get("lastPosition", 0)),
        )

    def edit_note(self, file=False):
        target = dict(self.state.get("personalReference") or {})
        if file:
            target.pop("subtune", None)
        ref_id, sub = target.get("trackID"), target.get("subtune")
        note = next(
            (
                n["text"]
                for n in self.state.get("history", {}).get("notes", [])
                if n["reference"]["trackID"] == ref_id
                and n["reference"].get("subtune") == (None if file else sub)
            ),
            "",
        )
        text, ok = QInputDialog.getMultiLineText(
            self, "Notiz zum Subtune", self.state.get("title", ""), note
        )
        if ok:
            self.send("noteReference", text=text, reference=target)

    def add_bookmark(self):
        target = dict(self.state.get("personalReference") or {})
        position = self.state.get("elapsed", 0)
        name, ok = QInputDialog.getText(
            self,
            "Lesezeichen",
            "Position " + clock(position),
            text=self.state.get("title", ""),
        )
        if ok and name.strip():
            self.send("bookmark", name=name, reference=target, position=position)

    def history_menu(self, point):
        item = self.history_view.itemAt(point)
        if not item:
            return
        entry = item.data(Qt.ItemDataRole.UserRole)
        reference = entry["reference"]
        menu = QMenu(self)
        menu.addAction(
            "Abspielen",
            lambda: self.send(
                "playReference",
                trackID=reference["trackID"],
                subtune=reference.get("subtune") or 0,
                position=0,
            ),
        )
        if self.history_page != 2:
            menu.addAction(
                "Ab " + clock(entry.get("position", entry.get("lastPosition", 0))),
                lambda: self.play_history_item(item),
            )
        if self.history_page == 1:
            menu.addAction(
                "Lesezeichen löschen",
                lambda: self.send("removeBookmark", id=entry["id"]),
            )
        if self.history_page == 2:

            def edit():
                text, ok = QInputDialog.getMultiLineText(
                    self,
                    "Persönliche Notiz",
                    Path(reference["trackID"]).stem,
                    entry.get("text", ""),
                )
                if ok:
                    self.send("noteReference", reference=reference, text=text)

            menu.addAction("Bearbeiten", edit)
        menu.exec(self.history_view.mapToGlobal(point))

    def clear_history(self):
        if (
            QMessageBox.question(
                self,
                "Hörverlauf leeren",
                "Den Hörverlauf und die Kennzeichnung „schon gehört“ zurücksetzen? Lesezeichen und Notizen bleiben erhalten.",
            )
            == QMessageBox.StandardButton.Yes
        ):
            self.send("clearHistory")

    def show_dialog(self, dialog):
        self.dialogs = [existing for existing in self.dialogs if existing.isVisible()]
        self.dialogs.append(dialog)
        dialog.setAttribute(Qt.WidgetAttribute.WA_DeleteOnClose, True)
        dialog.destroyed.connect(
            lambda obj=None, d=dialog: (
                self.dialogs.remove(d) if d in self.dialogs else None
            )
        )
        dialog.show()

    def show_settings(self):
        from .dialogs import SettingsDialog

        self.show_dialog(SettingsDialog(self))

    def show_playback(self):
        from .dialogs import PlaybackDialog

        self.show_dialog(PlaybackDialog(self))

    def show_mix(self):
        from .dialogs import MixDialog

        self.show_dialog(MixDialog(self))

    def show_export(self):
        from .dialogs import ExportDialog

        self.show_dialog(ExportDialog(self))

    def show_collection(self):
        from .dialogs import CollectionDialog

        self.show_dialog(CollectionDialog(self))

    def changeEvent(self, event):
        if event.type() == QEvent.Type.WindowStateChange:
            self.analysis.scope.sync_activity()
        super().changeEvent(event)

    def closeEvent(self, event):
        if self.update_dialog is not None and self.update_dialog.busy:
            self.close_after_update = True
            self.update_dialog.cancel()
            event.ignore()
            return
        if self.shutting_down:
            event.accept()
            return
        self.shutting_down = True
        self.send("settings", values={"sidebarWidth": self.splitter.sizes()[0]})
        self.engine.close()
        event.accept()
