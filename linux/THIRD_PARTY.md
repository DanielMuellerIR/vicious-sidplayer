# Qt for Python

The Linux interface uses unmodified PySide6 Essentials and Shiboken 6.12.0,
loaded dynamically from the `python/` directory. The player source is included
in `ui/`; replacing compatible Qt/PySide libraries does not require rebuilding
or signing the application. The project code remains WTFPL.

The Qt/PySide components used by this interface are available under LGPLv3.
The upstream wheel also contains optional modules. Their original metadata is
retained; the LGPLv3, GPLv2, GPLv3 and Qt exception texts are included here.

- [Qt for Python licensing](https://doc.qt.io/qtforpython-6/licenses.html)
- [PySide source, version 6.12.0](https://code.qt.io/cgit/pyside/pyside-setup.git/tree/?h=v6.12.0)
- [Qt source, version 6.12.0](https://code.qt.io/cgit/qt/qtbase.git/tree/?h=v6.12.0)
- [Upstream source downloads](https://download.qt.io/official_releases/QtForPython/)

The original SID/6502 emulation is based on jsSID 0.9.1 by Hermit
(Mihály Horváth), licensed under WTFPL. The root `LICENSE` applies to the
player. No music files are included.

The Linux updater verifies Ed25519 signatures with [cryptography 50.0.2](https://pypi.org/project/cryptography/50.0.2/)
by the Python Cryptographic Authority (Apache-2.0 OR BSD-3-Clause). The binary
wheel and its dependencies retain their license notices under `python/`. No
cryptographic implementation is copied into the player.
