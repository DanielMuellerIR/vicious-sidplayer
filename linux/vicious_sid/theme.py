from pathlib import Path
from PySide6.QtGui import QColor, QPalette

LIGHT = dict(
    side="#f5f5f7",
    surface="#ffffff",
    border="#d3d3d3",
    text="#1d1d1f",
    secondary="#68686d",
    accent="#007aff",
    warning="#9e5205",
    grid="#efefef",
    baseline="#dfdfdf",
    traces=["#00738c", "#218021", "#bf1a73"],
)
DARK = dict(
    side="#2d2d2f",
    surface="#141416",
    border="#3c3c3e",
    text="#ffffff",
    secondary="#a5a5a5",
    accent="#0a84ff",
    warning="#ffb340",
    grid="#222224",
    baseline="#303032",
    traces=["#00ffff", "#00ff00", "#ff2d55"],
)


def apply_theme(app, dark):
    colors = DARK if dark else LIGHT
    palette = QPalette()
    for role, key in [
        (QPalette.ColorRole.Window, "side"),
        (QPalette.ColorRole.Base, "surface"),
        (QPalette.ColorRole.AlternateBase, "side"),
        (QPalette.ColorRole.Text, "text"),
        (QPalette.ColorRole.WindowText, "text"),
        (QPalette.ColorRole.ButtonText, "text"),
        (QPalette.ColorRole.Button, "surface"),
        (QPalette.ColorRole.Highlight, "accent"),
    ]:
        palette.setColor(role, QColor(colors[key]))
    palette.setColor(QPalette.ColorRole.HighlightedText, QColor("white"))
    palette.setColor(
        QPalette.ColorGroup.Disabled,
        QPalette.ColorRole.ButtonText,
        QColor(colors["secondary"]),
    )
    app.setPalette(palette)
    c = colors
    segment_bg = "#3c3c3e" if dark else "#e7e7e9"
    arrows = (
        Path(__file__).parent
        / "assets"
        / ("arrows-dark.svg" if dark else "arrows-light.svg")
    ).as_posix()
    check = (
        Path(__file__).parent
        / "assets"
        / ("check-dark.svg" if dark else "check-light.svg")
    ).as_posix()
    app.setStyleSheet(f"""
    QWidget {{ color: {c["text"]}; font-family: "Liberation Sans", "Arial", sans-serif; font-size: 13px; }}
    QMainWindow, QDialog, QWidget#sidebar, QWidget#toolbar, QWidget#scrubber, QWidget#loopbar {{ background: {c["side"]}; }}
    QWidget#surface, QListView, QTableWidget, QTextEdit {{ background: {c["surface"]}; }}
    QLabel#secondary {{ color: {c["secondary"]}; }}
    QLabel#caption {{ color: {c["secondary"]}; font-size: 11px; }}
    QLabel#heading {{ color: {c["secondary"]}; font-size: 11px; font-weight: 600; }}
    QLabel#error {{ color: {"#ff6961" if dark else "#b3261e"}; font-size: 11px; }}
    QPushButton, QToolButton, QComboBox {{ font-size:12px; background: {c["surface"]}; border: 1px solid {c["border"]}; border-radius: 5px; min-height: 16px; padding: 1px 7px; }}
    QPushButton:hover, QToolButton:hover, QComboBox:hover {{ border-color: {c["accent"]}; }}
    QPushButton:pressed, QToolButton:pressed, QToolButton:checked {{ background: rgba(10, 132, 255, 32); }}
    QPushButton:disabled, QToolButton:disabled {{ color: {c["secondary"]}; }}
    QToolButton[plain="true"], QPushButton[plain="true"] {{ background: transparent; border: 0; padding: 0; }}
    QPushButton[accent="true"] {{ background: {c["accent"]}; color: white; border-color: {c["accent"]}; }}
    QLineEdit, QSpinBox, QDoubleSpinBox, QTextEdit {{ background: {c["surface"]}; border: 1px solid {c["border"]}; border-radius: 5px; padding: 4px 7px; selection-background-color: {c["accent"]}; }}
    QLineEdit:focus, QTextEdit:focus {{ border-color: {c["accent"]}; }}
    QComboBox::drop-down {{ border: 0; width: 16px; }}
    QComboBox::down-arrow {{ image: url("{arrows}"); width: 8px; height: 12px; }}
    QSlider::groove:horizontal {{ height: 4px; border-radius: 2px; background: {c["border"]}; }}
    QSlider::sub-page:horizontal {{ background: {c["accent"]}; border-radius: 2px; }}
    QSlider::handle:horizontal {{ width: 13px; height: 13px; margin: -5px 0; background: white; border: 1px solid {c["border"]}; border-radius: 7px; }}
    QCheckBox {{ spacing: 4px; font-size: 11px; }}
    QCheckBox::indicator {{ width: 12px; height: 12px; border: 1px solid {c["border"]}; border-radius: 3px; background: {c["surface"]}; }}
    QCheckBox::indicator:checked {{ background: {c["surface"]}; border-color: {c["secondary"]}; image: url("{check}"); }}
    QSplitter::handle {{ background: {c["border"]}; width: 1px; }}
    QListView {{ border: 0; outline: none; }}
    QScrollBar:vertical {{ width: 8px; background: transparent; }}
    QScrollBar::handle:vertical {{ background: {c["border"]}; border-radius: 4px; min-height: 30px; }}
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
    QMenu {{ background: {c["side"]}; border: 1px solid {c["border"]}; padding: 4px; }}
    QMenu::item {{ padding: 5px 20px; }} QMenu::item:selected {{ background: {c["accent"]}; color: white; }}
    QGroupBox {{ border: 1px solid {c["border"]}; border-radius: 6px; margin-top: 14px; padding-top: 12px; }}
    QGroupBox::title {{ subcontrol-origin: margin; left: 10px; }}
    QTabWidget::pane {{ border: 1px solid {c["border"]}; }}
    QTabBar::tab {{ background: {c["side"]}; padding: 5px 12px; }}
    QTabBar::tab:selected {{ background: {c["surface"]}; }}
    QWidget#segments {{ background: {segment_bg}; border: 1px solid {c["border"]}; border-radius: 5px; }}
    QWidget#segments QToolButton {{ background: transparent; border: 0; }}
    QWidget#segments QToolButton:checked {{ background: {c["surface"]}; border: 1px solid {c["border"]}; }}
    QToolTip {{ background: {c["side"]}; color: {c["text"]}; border: 1px solid {c["border"]}; padding: 4px; }}
    """)
    return colors
