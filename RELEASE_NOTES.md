Vicious SID Player 1.8.1 brings the emulation core to Linux as a native
command-line player and hardens song-length analysis, rendering, and scripted
output. The notarized macOS app and Quick Look extension remain included in the
DMG.

## Linux command-line player

- `vicious-sid` plays SID files in real time through ALSA and therefore works
  with PipeWire and PulseAudio.
- Raw 16-bit PCM can be streamed to stdout for pipelines, while diagnostics
  stay on stderr.
- Terminal controls provide pause/resume, subtune navigation, and clean quit;
  non-interactive stdin is detected automatically.
- MPRIS2 integration exposes playback, metadata, and subtune changes
  to desktop media keys and sound controls. Playback continues normally when
  no D-Bus session is available.
- `build_deb.sh` builds a Debian package containing the statically linked CLI,
  desktop entry, file association, and icon.
- Linux builds and tests now run on every push in the pinned Swift 6 container.

## Reliability and safety

- Song-length database loading and background estimation are cancellable and
  generation-safe, so an older asynchronous result cannot overwrite the
  currently selected tune.
- Intermediate silence no longer causes a tune that resumes later to be cached
  as prematurely ended.
- Computed song lengths are stored atomically, and stale or invalid cache data
  is handled without replacing valid state.
- WAV and CLI durations are validated before frame-count conversion or output;
  oversized and non-finite values fail cleanly.
- WAV export is streamed to a temporary file and replaces the destination only
  after a successful render, avoiding an in-memory full-song copy and partial
  output files.
- SID payload truncation is surfaced as a diagnostic instead of remaining
  silent.

## Verification and compatibility

- The complete Swift suite, deterministic synthetic SID rendering, the signed
  app/Quick Look build, and Linux CI cover the release paths.
- The macOS DMG is Developer ID-signed, notarized by Apple, and stapled for
  offline Gatekeeper verification.
- No SID music files are bundled. The HTML5 player is generated locally from
  the repository sources with `python3 build.py`.

Requires macOS 13 or later for the native app. The Linux CLI requires ALSA and
D-Bus runtime libraries.
