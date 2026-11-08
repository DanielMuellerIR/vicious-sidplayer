# Linux desktop application

The desktop player uses Qt Widgets for its interface and the existing Swift
core for parsing, emulation, ALSA audio, library indexing, metadata search,
listening lists, history, playback completion, A/B loops and WAV export.
It runs without a browser or a local web server. The command-line player
`vicious-sid` remains a separate executable.

## Build and install

On an x86-64 Linux desktop with Python 3.10–3.15:

```sh
# Mint / Ubuntu build dependencies:
sudo apt install libasound2-dev libdbus-1-dev libxcb-cursor0
# Install Swift 6, or use an existing Docker installation for the Swift build.
./build.sh
./install.sh --from-build "$PWD/build/vicious-sid-player-linux"
```

`build.sh` downloads the pinned Qt/PySide runtime from PyPI into the build
folder. It does not change system Python. The signature runtime uses an abi3
cryptography wheel and includes CFFI extensions for Python 3.10–3.15. `install.sh` installs the complete
application under `~/.local/share/vicious-sid-player/`, with a launcher at
`~/.local/bin/vicious-sid-player` and an application-menu entry. An installed
copy requires neither Swift nor Docker. Standard desktop ALSA and graphics
libraries remain system dependencies. `libxcb-cursor0` is needed for X11;
Wayland uses the Qt Wayland plugin shipped with the application.

Run `vicious-sid-player`, choose a SID file, or drag files and folders into the
window. The default library is `~/Music/Vicious SID Player`; choose another
folder in Settings. The file manager's **Open With** menu uses the GUI.
The `vicioussid://` URL scheme uses the same restricted Core command parser
as the macOS application.

A new installation activates an immutable version through an atomic symlink
change. Previous versions stay available for rollback. Failed activation
restores the previous launcher and desktop entry. Music and personal data are
separate from the installed program, under
`${XDG_DATA_HOME:-$HOME/.local/share}/Vicious SID Player/`.

`./release.sh` creates a local tar archive in `build/`; it does not publish or
install it. The existing `build_deb.sh` still packages the CLI separately.

## GitHub updates

The installed player checks the signed GitHub Pages update feed when it starts
and while it stays open, at most once a day. Disable **Automatisch nach Updates suchen** in Settings to
stop these background checks. **Hilfe → Nach Updates suchen …** checks manually.
A newer version is shown with release notes. Only **Herunterladen und installieren**
downloads and installs it. Playback continues, and the new version is used on the
next launch; the app does not force a restart.

The update manifest is verified against the public Ed25519 key shipped with the
app. The downloaded archive must match its signed SHA256 digest and size. Updates
are limited to this application's active per-user installation, reject unsafe
archive paths, preserve the old version and keep music and personal data separate.
The existing installer checks the runtime before atomically activating the new
version. A local build or an inactive older app cannot replace another installation.

**Bootstrap:** 1.9.52 and earlier have no Linux updater. Download and extract the
new Linux archive once, then run:

```sh
python3 vicious-sid-player-linux/install.py vicious-sid-player-linux
```

Quit the old player and start it from the application menu. Subsequent higher
releases can be installed from the player. Update checks contact GitHub Pages;
confirmed package downloads contact GitHub Releases. No music or library content
is sent. macOS retains its separate Sparkle updater.

## Interface parity

The macOS SwiftUI application supplies the reference layout, spacing, colors,
labels, control groups and oscilloscope equations. Both light and dark themes,
resizable library sidebar, mini-player, three analysis views, multi-SID mixing,
subtunes, search, favorites, listening lists, history and personal collection
transfer are available on Linux.

In Settings → Oszilloskop, choose **Flüssig** (about 60 FPS, the default),
**Sparsam** (15 FPS), or **Aus**. The choice is saved. Painting uses a local
animation timer; increasing its rate does not increase Core polling beyond
30 Hz. The economical mode also reduces polling to 15 Hz. Off skips waveform
painting and SID analysis snapshots; piano and registers still work at 30 Hz.
Paused scopes freeze. Hidden/minimized windows and the mini-player suspend
scope animation and SID analysis snapshots while playback continues.

Platform differences:

- Qt replaces SwiftUI/AppKit. Window decorations, the in-window Linux menu
  bar, file dialogs and font rasterization follow the Linux desktop.
- Liberation Sans/Mono replace Apple's system fonts. Independently drawn
  vector icons replace SF Symbols; the original application icon is shared.
- AudioToolbox and Sparkle are Apple frameworks. Linux currently exports WAV
  and uses its own signed GitHub updater; M4A/FLAC system encoding and the
  Sparkle interface are unavailable.
- Linux media controls use MPRIS on the session D-Bus. Audio uses ALSA and
  therefore the desktop's PipeWire/PulseAudio routing.

The layout is closely matched to the reference. It is not a claim of
bit-identical rendering across different text and window systems.

## Verification

```sh
swift test
python3 linux/tests/install_tests.py
# With the built application's bundled Python modules on PYTHONPATH:
PYTHONPATH="$PWD/build/vicious-sid-player-linux/python:$PWD/build/vicious-sid-player-linux/ui" \
  dbus-run-session -- xvfb-run -a python3 linux/tests/gui_smoke.py \
  build/vicious-sid-player-linux /tmp/vicious-sid-gui-evidence
```

`scope_animation.py` uses the same arguments to check actual paint events,
resource modes, pause, hidden/minimized windows, mini-player, and persistence.
Its CPU figures describe a synthetic tune under Xvfb, not battery life or
monitor presentation timing.

For `desktop_regressions.py`, route audio to a dedicated test sink and set
`VICIOUS_TEST_MONITOR` to its monitor source. The test checks real MPRIS
commands, A/B looping, WAV samples and channel count, collection transfer,
folder drops, persistence, and cancellation of a library scan.
Use a separate audio sink so the test does not affect normal playback.

The tests generate their own short 6502 programs. No SID music is bundled.
Qt/PySide license and source information is in [THIRD_PARTY.md](THIRD_PARTY.md).
