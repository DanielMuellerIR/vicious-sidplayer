from functools import lru_cache
import math
from PySide6.QtCore import QAbstractListModel, QPointF, QRect, QRectF, QSize, Qt
from PySide6.QtGui import (
    QColor,
    QFont,
    QIcon,
    QKeySequence,
    QShortcut,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
    QPolygonF,
)
from PySide6.QtWidgets import (
    QButtonGroup,
    QHBoxLayout,
    QLabel,
    QLayout,
    QListView,
    QListWidget,
    QSizePolicy,
    QStyledItemDelegate,
    QToolButton,
    QWidget,
)


def label(text="", size=13, bold=False, secondary=False):
    result = QLabel(text)
    result.setFont(
        QFont(
            "Liberation Sans", size, QFont.Weight.Bold if bold else QFont.Weight.Normal
        )
    )
    result.setStyleSheet(f"font-size: {size}px; font-weight: {600 if bold else 400};")
    if secondary:
        result.setObjectName("secondary")
    return result


@lru_cache(maxsize=128)
def icon(name, color="#68686d", size=20):
    pix = QPixmap(size * 2, size * 2)
    pix.setDevicePixelRatio(2)
    pix.fill(Qt.GlobalColor.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    p.scale(size / 20, size / 20)
    p.setPen(
        QPen(
            QColor(color),
            1.6,
            Qt.PenStyle.SolidLine,
            Qt.PenCapStyle.RoundCap,
            Qt.PenJoinStyle.RoundJoin,
        )
    )
    p.setBrush(QColor(color))
    if name in ("play", "next", "previous"):
        if name == "previous":
            p.translate(20, 0)
            p.scale(-1, 1)
        p.drawPolygon(QPolygonF([QPointF(6, 4), QPointF(6, 16), QPointF(15, 10)]))
        if name != "play":
            p.drawLine(16, 4, 16, 16)
    elif name == "pause":
        p.drawRoundedRect(QRectF(5, 4, 3, 12), 0.5, 0.5)
        p.drawRoundedRect(QRectF(12, 4, 3, 12), 0.5, 0.5)
    elif name == "stop":
        p.drawRoundedRect(QRectF(5, 5, 10, 10), 1, 1)
    elif name == "star":
        points = [
            QPointF(
                10 + (8 if i % 2 == 0 else 3.5) * math.sin(i * math.pi / 5),
                10 - (8 if i % 2 == 0 else 3.5) * math.cos(i * math.pi / 5),
            )
            for i in range(10)
        ]
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawPolygon(QPolygonF(points))
    elif name == "shuffle":
        p.setBrush(Qt.BrushStyle.NoBrush)
        path = QPainterPath(QPointF(3, 5))
        path.cubicTo(10, 5, 10, 15, 17, 15)
        p.drawPath(path)
        path = QPainterPath(QPointF(3, 15))
        path.cubicTo(10, 15, 10, 5, 17, 5)
        p.drawPath(path)
        p.drawPolyline(QPolygonF([QPointF(14, 2), QPointF(17, 5), QPointF(14, 8)]))
        p.drawPolyline(QPolygonF([QPointF(14, 12), QPointF(17, 15), QPointF(14, 18)]))
    elif name in ("back15", "forward30"):
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawArc(QRectF(3, 3, 14, 14), 30 * 16, 285 * 16)
        p.drawPolyline(QPolygonF([QPointF(9, 1), QPointF(5, 4), QPointF(9, 6)]))
        p.setFont(QFont("Liberation Sans", 6, QFont.Weight.Bold))
        p.drawText(
            QRectF(3, 4, 14, 12),
            Qt.AlignmentFlag.AlignCenter,
            "15" if name == "back15" else "30",
        )
    elif name in ("mute", "sound"):
        p.drawPolygon(
            QPolygonF(
                [
                    QPointF(3, 8),
                    QPointF(6, 8),
                    QPointF(10, 4),
                    QPointF(10, 16),
                    QPointF(6, 12),
                    QPointF(3, 12),
                ]
            )
        )
        p.setBrush(Qt.BrushStyle.NoBrush)
        if name == "mute":
            p.drawLine(13, 7, 18, 13)
            p.drawLine(18, 7, 13, 13)
        else:
            p.drawArc(QRectF(8, 5, 8, 10), -70 * 16, 140 * 16)
            p.drawArc(QRectF(6, 2, 14, 16), -65 * 16, 130 * 16)
    elif name == "music-list":
        p.setBrush(Qt.BrushStyle.NoBrush)
        for y in (5, 9, 13):
            p.drawLine(3, y, 11, y)
        p.drawLine(15, 3, 15, 14)
        p.setBrush(QColor(color))
        p.drawEllipse(QRectF(10, 13, 5, 4))
    elif name == "list-box":
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(QRectF(2, 3, 16, 14), 1, 1)
        for y in (6, 10, 14):
            p.drawPoint(5, y)
            p.drawLine(8, y, 15, y)
    elif name == "queue":
        p.drawPolygon(QPolygonF([QPointF(2, 3), QPointF(2, 8), QPointF(7, 5.5)]))
        for y in (5, 10, 15):
            p.drawLine(9 if y == 5 else 3, y, 17, y)
    elif name == "history":
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawArc(QRectF(4, 3, 13, 14), -80 * 16, 300 * 16)
        p.drawLine(10, 6, 10, 10)
        p.drawLine(10, 10, 13, 12)
        p.drawPolyline(QPolygonF([QPointF(1, 4), QPointF(4, 8), QPointF(7, 4)]))
    elif name == "remove":
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawEllipse(QRectF(3, 3, 14, 14))
        p.drawLine(6, 10, 14, 10)
    elif name in ("chevron-up", "chevron-down"):
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawPolyline(
            QPolygonF(
                [
                    QPointF(5, 12 if name == "chevron-up" else 8),
                    QPointF(10, 8 if name == "chevron-up" else 12),
                    QPointF(15, 12 if name == "chevron-up" else 8),
                ]
            )
        )
    elif name == "close":
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawEllipse(QRectF(3, 3, 14, 14))
        p.drawLine(7, 7, 13, 13)
        p.drawLine(13, 7, 7, 13)
    elif name == "solo":
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawEllipse(QRectF(3, 3, 14, 14))
        p.setFont(QFont("Liberation Sans", 8, QFont.Weight.Bold))
        p.drawText(QRectF(3, 3, 14, 14), Qt.AlignmentFlag.AlignCenter, "S")
    elif name == "settings":
        p.setBrush(Qt.BrushStyle.NoBrush)
        for y, x in [(5, 8), (10, 13), (15, 6)]:
            p.drawLine(3, y, 17, y)
            p.setBrush(QColor(color))
            p.drawEllipse(QPointF(x, y), 2, 2)
            p.setBrush(Qt.BrushStyle.NoBrush)
    elif name == "trash":
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(QRectF(5, 6, 10, 11), 1, 1)
        p.drawLine(3, 4, 17, 4)
        p.drawLine(8, 2, 12, 2)
        p.drawLine(8, 8, 8, 14)
        p.drawLine(12, 8, 12, 14)
    elif name == "folder":
        p.setBrush(Qt.BrushStyle.NoBrush)
        path = QPainterPath(QPointF(2, 5))
        path.lineTo(8, 5)
        path.lineTo(10, 7)
        path.lineTo(18, 7)
        path.lineTo(18, 16)
        path.lineTo(2, 16)
        path.closeSubpath()
        p.drawPath(path)
    elif name == "mini":
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRoundedRect(QRectF(2, 4, 16, 12), 2, 2)
        p.drawLine(3, 11, 17, 11)
    elif name in ("down", "up"):
        p.setBrush(Qt.BrushStyle.NoBrush)
        for dy in (0, 5):
            points = [QPointF(5, 6 + dy), QPointF(10, 10 + dy), QPointF(15, 6 + dy)]
            if name == "up":
                points = [QPointF(v.x(), 20 - v.y()) for v in points]
            p.drawPolyline(QPolygonF(points))
    elif name == "list":
        for y in (5, 10, 15):
            p.drawLine(7, y, 17, y)
            p.drawPoint(3, y)
    else:
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawEllipse(QRectF(4, 4, 12, 12))
    p.end()
    return QIcon(pix)


def tool(name, text, callback=None, color="#68686d", size=24):
    result = QToolButton()
    result.setIcon(icon(name, color))
    result.setIconSize(QSize(20, 20))
    result.setFixedSize(size, size)
    result.setProperty("plain", True)
    result.setAccessibleName(text)
    result.setToolTip(text)
    if callback:
        result.clicked.connect(callback)
    return result


class Segments(QWidget):
    def __init__(self, titles, callback, parent=None, symbols=None):
        super().__init__(parent)
        self.setObjectName("segments")
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        self.group = QButtonGroup(self)
        for index, title in enumerate(titles):
            button = QToolButton()
            button.setText(title)
            if symbols:
                button.setText("")
                button.setIcon(icon(symbols[index], size=15))
                button.setIconSize(QSize(15, 15))
                button.setToolTip(title)
            button.setCheckable(True)
            button.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
            button.setStyleSheet(
                "font-size: 10px; padding: 0px 3px; min-height: 14px; border-radius: 4px;"
            )
            button.setFixedHeight(18)
            button.setAccessibleName(title)
            self.group.addButton(button, index)
            layout.addWidget(button)
        self.group.button(0).setChecked(True)
        self.group.idClicked.connect(callback)

    def select(self, index):
        self.group.button(index).setChecked(True)


class FlowLayout(QLayout):
    """Umbruch ausschließlich zwischen denselben Controlgruppen wie auf dem Mac."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.items = []
        self.setContentsMargins(16, 10, 16, 10)

    def addItem(self, item):
        self.items.append(item)

    def count(self):
        return len(self.items)

    def itemAt(self, index):
        return self.items[index] if index < len(self.items) else None

    def takeAt(self, index):
        return self.items.pop(index) if index < len(self.items) else None

    def expandingDirections(self):
        return Qt.Orientation.Horizontal

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, width):
        return self.arrange(QRect(0, 0, width, 0), True)

    def sizeHint(self):
        return self.minimumSize()

    def minimumSize(self):
        return QSize(560, self.heightForWidth(560))

    def setGeometry(self, rect):
        super().setGeometry(rect)
        self.arrange(rect, False)

    def arrange(self, rect, dry):
        margins = self.contentsMargins()
        area = rect.adjusted(
            margins.left(), margins.top(), -margins.right(), -margins.bottom()
        )
        x, y, height = area.x(), area.y(), 0
        sizes = [item.sizeHint() for item in self.items]
        if sizes:
            remainder = sum(size.width() + 10 for size in sizes[1:])
            sizes[0].setWidth(
                min(
                    sizes[0].width(),
                    max(self.items[0].minimumSize().width(), area.width() - remainder),
                )
            )
        for index, item in enumerate(self.items):
            size = sizes[index]
            if x > area.x() and x + size.width() > area.right() + 1:
                x = area.x()
                y += height + 8
                height = 0
            if index == len(self.items) - 1:
                x = max(x, area.right() + 1 - size.width())
            if not dry:
                item.setGeometry(QRect(x, y, size.width(), size.height()))
            x += size.width() + 10
            height = max(height, size.height())
        return y + height + margins.bottom() - rect.y()


class TrackModel(QAbstractListModel):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.rows = []

    def rowCount(self, parent=None):
        return 0 if parent and parent.isValid() else len(self.rows)

    def data(self, index, role=Qt.ItemDataRole.DisplayRole):
        if not index.isValid() or index.row() >= len(self.rows):
            return None
        row = self.rows[index.row()]
        if role in (Qt.ItemDataRole.DisplayRole, Qt.ItemDataRole.AccessibleTextRole):
            return row["name"] + " " + row.get("folder", "")
        if role == Qt.ItemDataRole.UserRole:
            return row
        if role == Qt.ItemDataRole.ToolTipRole:
            return row.get("id", "") + "\n" + row.get("detail", "")

    def replace(self, rows):
        self.beginResetModel()
        self.rows = rows
        self.endResetModel()


class TrackDelegate(QStyledItemDelegate):
    def __init__(self, window):
        super().__init__(window)
        self.window = window

    def sizeHint(self, option, index):
        return QSize(
            180, 28 if index.data(Qt.ItemDataRole.UserRole).get("folderRow") else 44
        )

    def paint(self, painter, option, index):
        row = index.data(Qt.ItemDataRole.UserRole)
        c = self.window.colors
        rect = option.rect
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        current = row["id"] == self.window.state.get("trackID") and not row.get(
            "folderRow"
        )
        if current:
            painter.setBrush(QColor(c["accent"]))
            painter.setPen(Qt.PenStyle.NoPen)
            painter.drawRoundedRect(rect.adjusted(8, 1, -8, -1), 5, 5)
        col = "#ffffff" if current else c["text"]
        secondary = "#ffffff" if current else c["secondary"]
        x = rect.x() + 18 + row.get("depth", 0) * 12
        if not row.get("folderRow"):
            painter.setPen(QColor(col))
            painter.setFont(QFont("Liberation Sans", 10))
            painter.drawText(QPointF(x, rect.y() + 25), "⏵" if current else "♪")
            x += 20
        painter.setPen(QColor(col))
        painter.setFont(QFont("Liberation Sans", 10 if row.get("folderRow") else 9))
        if row.get("folderRow"):
            painter.drawText(
                QRect(x, rect.y(), 12, rect.height()),
                Qt.AlignmentFlag.AlignVCenter,
                "⌄" if row.get("expanded") else "›",
            )
            icon("folder", c["secondary"], 15).paint(
                painter, QRect(x + 13, rect.y() + 6, 15, 15)
            )
            painter.drawText(
                QRect(x + 33, rect.y(), rect.width() - x - 60, rect.height()),
                Qt.AlignmentFlag.AlignVCenter,
                row["name"],
            )
            painter.setPen(QColor(c["secondary"]))
            painter.drawText(
                rect.adjusted(0, 0, -10, 0),
                Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter,
                str(row["count"]),
            )
        else:
            available = max(0, rect.right() - x - 30)
            name = painter.fontMetrics().elidedText(
                row.get("title", row["name"]), Qt.TextElideMode.ElideRight, available
            )
            painter.drawText(
                QRect(x, rect.y() + 4, available, 16),
                Qt.AlignmentFlag.AlignVCenter,
                name,
            )
            painter.setPen(QColor(secondary))
            painter.setFont(QFont("Liberation Sans", 8))
            detail = painter.fontMetrics().elidedText(
                row.get("detail") or row.get("folder") or "SID-Datei",
                Qt.TextElideMode.ElideRight,
                available,
            )
            painter.drawText(
                QRect(x, rect.y() + 22, available, 13),
                Qt.AlignmentFlag.AlignVCenter,
                detail,
            )
            icon(
                "star",
                "#ffcc00"
                if row.get("favorite")
                else "#ffffff"
                if current
                else c["border"],
                11,
            ).paint(painter, QRect(rect.right() - 24, rect.y() + 14, 11, 11))
        painter.restore()


class TrackView(QListView):
    def __init__(self, window):
        super().__init__()
        self.window = window

    def mouseReleaseEvent(self, event):
        index = self.indexAt(event.position().toPoint())
        if event.button() == Qt.MouseButton.LeftButton and index.isValid():
            row = index.data(Qt.ItemDataRole.UserRole)
            if (
                not row.get("folderRow")
                and event.position().x() > self.viewport().width() - 30
            ):
                self.window.send("favorite", id=row["id"])
                return
        super().mouseReleaseEvent(event)


class ElidingLabel(QLabel):
    def __init__(self, text=""):
        self.full_text = text
        super().__init__(text)
        self.setMinimumWidth(0)
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)

    def setText(self, text):
        self.full_text = text
        self.setToolTip(text)
        self.update_text()

    def update_text(self):
        super().setText(
            self.fontMetrics().elidedText(
                self.full_text, Qt.TextElideMode.ElideRight, self.width()
            )
        )

    def resizeEvent(self, event):
        self.update_text()
        super().resizeEvent(event)


class TrackControls(QWidget):
    def __init__(self):
        super().__init__()
        self.tune_menu = None

    def sizeHint(self):
        size = super().sizeHint()
        if self.tune_menu:
            size.setWidth(size.width() - self.tune_menu.width() + 260)
        return size

    def minimumSizeHint(self):
        size = super().minimumSizeHint()
        if self.tune_menu:
            size.setWidth(size.width() - self.tune_menu.width() + 150)
        return size

    def resizeEvent(self, event):
        if self.tune_menu:
            rest = super().sizeHint().width() - self.tune_menu.width()
            self.tune_menu.setFixedWidth(min(260, max(150, self.width() - rest)))
        super().resizeEvent(event)


class ListeningDelegate(QStyledItemDelegate):
    def __init__(self, window, queue=False):
        super().__init__(window)
        self.window = window
        self.queue = queue

    def sizeHint(self, option, index):
        return QSize(160, 44)

    def paint(self, painter, option, index):
        from pathlib import Path

        entry = index.data(Qt.ItemDataRole.UserRole)
        if not entry:
            return
        c = self.window.colors
        rect = option.rect.adjusted(0, 1, 0, -2)
        current = self.queue and entry["id"] == (
            self.window.state.get("listening", {}).get("queue") or {}
        ).get("currentID")
        painter.save()
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        if current:
            tint = QColor(c["accent"])
            tint.setAlphaF(0.15)
            painter.setBrush(tint)
            painter.setPen(Qt.PenStyle.NoPen)
            painter.drawRoundedRect(rect, 5, 5)
        title = Path(entry["trackID"]).stem
        font = QFont("Liberation Sans")
        font.setPixelSize(12)
        font.setWeight(QFont.Weight.Medium)
        painter.setFont(font)
        painter.setPen(QColor(c["text"]))
        left = rect.left() + 6
        if current:
            icon("play", c["text"], 9).paint(painter, QRect(left, rect.y() + 7, 9, 9))
            left += 13
        painter.drawText(
            QRect(left, rect.y() + 5, max(0, rect.width() - 84), 15),
            Qt.AlignmentFlag.AlignVCenter,
            painter.fontMetrics().elidedText(
                title, Qt.TextElideMode.ElideRight, max(0, rect.width() - 84)
            ),
        )
        font.setPixelSize(10)
        font.setWeight(QFont.Weight.Normal)
        painter.setFont(font)
        painter.setPen(QColor(c["secondary"]))
        detail = (
            f"Subtune {entry['subtune'] + 1}"
            if entry.get("subtune") is not None
            else "Alle Subtunes"
        )
        painter.drawText(
            QRect(rect.left() + 6, rect.y() + 23, max(0, rect.width() - 84), 13),
            Qt.AlignmentFlag.AlignVCenter,
            detail,
        )
        for offset, name in enumerate(["chevron-up", "chevron-down", "remove"]):
            icon(name, c["secondary"], 11).paint(
                painter, QRect(rect.right() - 67 + offset * 24, rect.y() + 13, 11, 11)
            )
        painter.restore()


class ListeningView(QListWidget):
    def __init__(self, window, queue=False):
        super().__init__()
        self.window = window
        self.queue = queue
        self.setItemDelegate(ListeningDelegate(window, queue))
        self.setStyleSheet("background:transparent; border:0;")
        self.setVerticalScrollMode(QListView.ScrollMode.ScrollPerPixel)
        self.setAccessibleDescription(
            "Eingabe spielt den ausgewählten Eintrag. Alt+Pfeil hoch oder runter verschiebt ihn, Entf entfernt ihn."
        )
        self.shortcuts = []
        for key, section in [("Alt+Up", 0), ("Alt+Down", 1), ("Delete", 2)]:
            shortcut = QShortcut(QKeySequence(key), self)
            shortcut.setContext(Qt.ShortcutContext.WidgetShortcut)
            shortcut.activated.connect(lambda action=section: self.edit_current(action))
            self.shortcuts.append(shortcut)
        self.itemActivated.connect(
            lambda item: (
                self.window.send(
                    "queuePlay", id=item.data(Qt.ItemDataRole.UserRole)["id"]
                )
                if self.queue
                else self.window.play_list_entry(item)
            )
        )

    def edit_current(self, section):
        item = self.currentItem()
        if item:
            self.edit_entry(item.data(Qt.ItemDataRole.UserRole), section)

    def edit_entry(self, entry, section):
        if self.queue:
            if section >= 2 and entry["id"] == (
                self.window.state.get("listening", {}).get("queue") or {}
            ).get("currentID"):
                return
            self.window.send(
                "queueRemove" if section >= 2 else "queueMove",
                id=entry["id"],
                offset=-1 if section == 0 else 1,
            )
        else:
            current = self.window.lists_view.currentData()
            if current:
                self.window.send(
                    "listRemove" if section >= 2 else "listMove",
                    id=entry["id"],
                    listID=current["id"],
                    offset=-1 if section == 0 else 1,
                )

    def mouseReleaseEvent(self, event):
        index = self.indexAt(event.position().toPoint())
        if (
            event.button() == Qt.MouseButton.LeftButton
            and index.isValid()
            and event.position().x() > self.viewport().width() - 75
        ):
            entry = self.item(index.row()).data(Qt.ItemDataRole.UserRole)
            section = int((event.position().x() - (self.viewport().width() - 75)) // 24)
            self.edit_entry(entry, section)
            return
        super().mouseReleaseEvent(event)
