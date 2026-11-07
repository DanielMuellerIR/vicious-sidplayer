import random
import time
from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QFont, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import (
    QComboBox,
    QHBoxLayout,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)
from .widgets import icon, label, tool


class Scope(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        self.phase_time = 0
        self.selected_chip = 0
        self.mode = 0
        self.setMinimumHeight(180)
        self.setAccessibleName("SID-Oszilloskop und Analyse")
        self.mutes = [
            tool(
                "sound",
                f"Stimme {voice + 1} stummschalten",
                lambda checked=False, v=voice: window.send(
                    "mute", channel=self.selected_chip * 3 + v
                ),
            )
            for voice in range(3)
        ]
        self.solos = [
            tool(
                "solo",
                f"Stimme {voice + 1} Solo",
                lambda checked=False, v=voice: window.send(
                    "solo", channel=self.selected_chip * 3 + v
                ),
            )
            for voice in range(3)
        ]
        for button in self.mutes + self.solos:
            button.setParent(self)
        self.filter = QPushButton("FILTER: ON", self)
        self.filter.setProperty("plain", True)
        self.filter.setStyleSheet("font-family: monospace; font-size: 9px;")
        self.filter.setAccessibleName("SID-Filter")
        self.filter.clicked.connect(lambda: window.send("filter"))
        self.filter.resize(100, 24)
        self.noise = random.Random(0)

    def refresh(self):
        s = self.window.state
        if s.get("state") == "Playing":
            self.phase_time = time.monotonic()
        chips = s.get("chips", [])
        if self.selected_chip >= len(chips):
            self.selected_chip = 0
        for v in range(3):
            channel = self.selected_chip * 3 + v
            muted = s.get("mixMuted", [False] * 9)[channel]
            solo = channel in s.get("solos", [])
            self.mutes[v].setIcon(
                icon(
                    "mute" if muted else "sound",
                    "#ff453a" if muted else self.window.colors["traces"][v],
                )
            )
            self.solos[v].setIcon(
                icon("solo", "#ff9f0a" if solo else self.window.colors["secondary"])
            )
            self.mutes[v].setVisible(self.mode == 0)
            self.solos[v].setVisible(self.mode == 0)
        self.filter.setVisible(self.mode == 0)
        self.filter.setText("FILTER: " + ("ON" if s.get("filter", True) else "OFF"))
        self.filter.setStyleSheet(
            f"font-family: monospace; font-size: 9px; color: {self.window.colors['traces'][1] if s.get('filter', True) else '#ff453a'};"
        )
        if self.isVisible():
            self.update()

    def resizeEvent(self, event):
        for v in range(3):
            self.mutes[v].move(self.width() - 60, round(self.height() / 3 * v) + 1)
            self.solos[v].move(self.width() - 32, round(self.height() / 3 * v) + 1)
        self.filter.move(2, self.height() - 25)
        super().resizeEvent(event)

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        c = self.window.colors
        s = self.window.state
        p.fillRect(self.rect(), QColor(c["surface"]))
        chips = s.get("chips") or []
        chip = (
            chips[self.selected_chip]
            if self.selected_chip < len(chips)
            else dict(voices=[{}] * 3, model=6581, registers=[])
        )
        if self.mode == 1:
            self.paint_piano(p, chip)
            return
        if self.mode == 2:
            self.paint_registers(p, chip)
            return
        w, h = self.width(), self.height()
        p.setPen(QPen(QColor(c["grid"]), 1))
        for x in range(10):
            p.drawLine(QPointF(w / 10 * x, 0), QPointF(w / 10 * x, h))
        for y in range(8):
            p.drawLine(QPointF(0, h / 8 * y), QPointF(w, h / 8 * y))
        show = s.get("state") in ("Playing", "Paused")
        for v, voice in enumerate(chip["voices"]):
            ch = h / 3
            baseline = ch * v + ch / 2
            frequency = voice.get("hertz", 0) if show else 0
            env = voice.get("envelope", 0) if show else 0
            waveform = voice.get("waveform", 0) if show else 0
            duty = voice.get("pulsewidth", 0.5)
            gate = voice.get("gate", 0) if show else 0
            p.setPen(QPen(QColor(c["baseline"]), 1))
            p.drawLine(QPointF(0, baseline), QPointF(w, baseline))
            amplitude = env * ch * 0.38 if show else 0
            wavelength = min(300, max(10, 3000 / frequency)) if frequency > 10 else 150
            phase = (frequency * self.phase_time * 0.02) % 1 if frequency > 0 else 0
            path = QPainterPath()
            self.noise.seed(v + int(self.phase_time * 30))
            for x in range(0, w + 1, 2):
                f = (x / wavelength - phase) % 1
                if waveform & 0x80:
                    value = self.noise.uniform(-1, 1)
                elif waveform & 0x40:
                    value = 1 if f < duty else -1
                elif waveform & 0x20:
                    value = 2 * f - 1
                elif waveform & 0x10:
                    value = 4 * f - 1 if f < 0.5 else 3 - 4 * f
                else:
                    value = 0
                point = QPointF(x, baseline + value * amplitude)
                if x == 0:
                    path.moveTo(point)
                else:
                    path.lineTo(point)
            muted = s.get("effectiveMuted", [False] * 9)[self.selected_chip * 3 + v]
            color = QColor(c["traces"][v])
            color.setAlphaF(0.25 if muted else 1)
            p.setPen(QPen(color, 2 if gate else 1))
            p.drawPath(path)
            p.setFont(QFont("Liberation Mono", 7))
            name = next(
                (
                    name
                    for flag, name in [
                        (0x80, "NOI"),
                        (0x40, "PUL"),
                        (0x20, "SAW"),
                        (0x10, "TRI"),
                    ]
                    if waveform & flag
                ),
                "---",
            )
            text = (
                f"SID {self.selected_chip + 1} V{v + 1} | {name} | [GATE:{'ON ' if gate else 'OFF'}] | Freq: {round(frequency) if frequency > 20 else 0} Hz | Env: {round(env * 100)}%"
                + (" | MUTED" if muted else "")
            )
            p.drawText(QPointF(10, ch * v + 15), text)
        p.setPen(QColor(c["traces"][1]))
        p.setFont(QFont("Liberation Mono", 7))
        p.drawText(
            QRectF(110, h - 22, w - 120, 20),
            Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter,
            f"SID {self.selected_chip + 1} · {chip['model']} // 3 TRACE",
        )

    def paint_piano(self, p, chip):
        c = self.window.colors
        w = self.width()
        p.setPen(QColor(c["secondary"]))
        p.setFont(QFont("Liberation Mono", 8))
        p.drawText(
            QPointF(10, 20),
            f"SID {self.selected_chip + 1} · ${chip.get('address', 0xD400):04X} · {chip['model']} · {self.window.state.get('clockLabel', 'PAL')}",
        )
        for v, voice in enumerate(chip["voices"]):
            top = 35 + v * 61
            p.setPen(QColor(c["text"]))
            p.setFont(QFont("Liberation Sans", 9, QFont.Weight.DemiBold))
            p.drawText(QPointF(10, top + 15), f"V{v + 1}")
            p.setFont(QFont("Liberation Mono", 9))
            note = voice.get("note", "—")
            text = f"{note} · {voice.get('hertz', 0):.1f} Hz" + (
                f" · {voice.get('cents', 0):+.0f} ct" if note != "—" else ""
            )
            p.drawText(QPointF(38, top + 12), text)
            p.setPen(QColor(c["secondary"]))
            p.setFont(QFont("Liberation Mono", 8))
            p.drawText(
                QRectF(w - 130, top, 120, 18),
                Qt.AlignmentFlag.AlignRight,
                f"G{voice.get('gate', 0)} · {round(voice.get('envelope', 0) * 100)}%",
            )
            key_width = (w - 58 - 22) / 12
            for key in range(12):
                black = key in (1, 3, 6, 8, 10)
                rect = QRectF(
                    38 + key * (key_width + 2),
                    top + 22 + (3 if black else 0),
                    key_width,
                    12 if black else 18,
                )
                color = (
                    QColor(c["accent"])
                    if voice.get("midi", -1) >= 0 and voice["midi"] % 12 == key
                    else QColor(c["secondary"])
                )
                if color != QColor(c["accent"]):
                    color.setAlphaF(0.6 if black else 0.16)
                p.setPen(Qt.PenStyle.NoPen)
                p.setBrush(color)
                p.drawRoundedRect(rect, 2, 2)
        p.setPen(QColor(c["secondary"]))
        p.setFont(QFont("Liberation Sans", 8))
        p.drawText(
            QRectF(10, 225, w - 20, 50),
            Qt.TextFlag.TextWordWrap,
            "Ungefähre Register-Tonhöhe, A4 = 440 Hz. Noise, kombinierte Wellenformen und Digi-Töne sind nicht verlässlich erkennbar.",
        )

    def paint_registers(self, p, chip):
        c = self.window.colors
        width = self.width()
        p.setPen(QColor(c["secondary"]))
        p.setFont(QFont("Liberation Mono", 8))
        p.drawText(
            QPointF(10, 20),
            f"SID {self.selected_chip + 1} · ${chip.get('address', 0xD400):04X} · {chip['model']} · {self.window.state.get('clockLabel', 'PAL')}",
        )
        p.setFont(QFont("Liberation Sans", 8))
        p.drawText(
            QPointF(10, 39),
            "Geschriebene Register und emulierte OSC3/ENV3-Werte; nur Leseansicht.",
        )
        p.setFont(QFont("Liberation Mono", 9))
        for i, row in enumerate(chip.get("registers", [])):
            y = 62 + i * 18
            p.setPen(QColor(c["secondary"]))
            p.drawText(
                QPointF(10, y), f"${chip.get('address', 0xD400) + row['offset']:04X}"
            )
            p.setPen(QColor(c["text"]))
            p.drawText(QPointF(70, y), row["label"])
            p.setFont(QFont("Liberation Mono", 9, QFont.Weight.Bold))
            p.drawText(
                QRectF(width - 45, y - 13, 35, 18),
                Qt.AlignmentFlag.AlignRight,
                f"{row['value']:02X}",
            )
            p.setFont(QFont("Liberation Mono", 9))


class Analysis(QWidget):
    def __init__(self, window):
        super().__init__()
        self.window = window
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        bar = QWidget()
        bar.setFixedHeight(36)
        row = QHBoxLayout(bar)
        row.setContentsMargins(8, 4, 8, 4)
        row.setSpacing(10)
        self.chips = QComboBox()
        self.chips.setFixedWidth(72)
        self.chips.addItem("SID 1")
        self.chips.currentIndexChanged.connect(self.chip_changed)
        row.addWidget(self.chips)
        self.model = label("6581", 11)
        row.addWidget(self.model)
        row.addStretch()
        self.mode = QComboBox()
        self.mode.addItems(["Oszilloskop", "Piano / Hz", "Register"])
        self.mode.setFixedWidth(130)
        self.mode.setAccessibleName("Analyseansicht")
        self.mode.setObjectName("analysis-view")
        self.mode.currentIndexChanged.connect(self.mode_changed)
        row.addWidget(self.mode)
        mix = QPushButton("Mischung …")
        mix.clicked.connect(window.show_mix)
        row.addWidget(mix)
        layout.addWidget(bar)
        self.scope = Scope(window)
        self.scroll = QScrollArea()
        self.scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        self.scroll.setWidgetResizable(True)
        self.scroll.setWidget(self.scope)
        layout.addWidget(self.scroll, 1)

    def chip_changed(self, index):
        self.scope.selected_chip = max(0, index)
        self.scope.refresh()

    def mode_changed(self, index):
        self.scope.mode = index
        self.scope.setMinimumHeight(560 if index == 2 else 280 if index == 1 else 180)
        self.scope.refresh()

    def refresh(self):
        chips = self.window.state.get("chips", [])
        if self.chips.count() != len(chips) and chips:
            self.chips.blockSignals(True)
            self.chips.clear()
            self.chips.addItems([f"SID {chip['chip'] + 1}" for chip in chips])
            self.chips.blockSignals(False)
        index = min(self.chips.currentIndex(), len(chips) - 1)
        self.model.setText(str(chips[index]["model"]) if chips else "6581")
        self.scope.refresh()
