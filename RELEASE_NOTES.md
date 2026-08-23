Vicious SID Player 1.9.21 is about making the macOS app work with a real
collection. Tested against 50,001 files — the size of a full High Voltage SID
Collection — the previous version crashed on launch. It now starts in a fraction
of a second and stays there. On top of that: the folder view the iPhone app
already had, the HVSC tune notes (STIL), a mini player, a remote-control URL
scheme, and roughly half the idle CPU load. The iPhone app gains the same tune
notes and a fix that would otherwise have left it silent after a system audio
restart.

## Large collections on macOS

- **The app no longer crashes with a large library.** Two independent causes,
  both found by measurement: the "TUNE:" chooser was a picker over the entire
  playlist, which macOS turns into a menu with one item per track — 5.2 GB of
  memory at 50,001 tracks — and the track list built every row up front, which
  exhausted the SwiftUI view graph. The chooser is now a menu over a bounded
  window around the current track, and the list only builds the rows it shows.
  Result: 340 MB instead of a crash.
- **The library scan runs in the background.** The list appears immediately from
  the stored index and playback starts before the scan finishes; the result is
  merged in afterwards and the playing track is followed by its identity, not by
  its position in the list.
- **Folder view.** The sidebar shows the collection either as a flat track list
  or as an expandable folder tree with a track count per folder, switched in the
  playlist header. Expand and collapse all, and the expanded state survives a
  restart. Search and the favourites filter still show the flat list of matches.
- Collapsed folders cost nothing: at 50,001 tracks the tree renders 100 rows
  instead of 50,100.

## Tune notes from the HVSC (STIL)

- The app reads the `STIL.txt` of the High Voltage SID Collection and shows what
  does not fit into the SID file header: which original a tune covers, who wrote
  the melody, and notes on individual subtunes — ordered from the subtune to the
  file to the folder.
- On macOS the file is found automatically under `DOCUMENTS/` in or above the
  autoplay folder, or picked in the settings. On iOS it is imported once, like
  the song length database.
- Tunes are matched by their path below the HVSC root; for collections copied out
  of the HVSC, a unique path ending is used instead. Ambiguous matches are
  dropped — a wrong note is worse than none. The database itself is not bundled;
  it belongs to the HVSC project.

## Mini player and remote control

- **Mini player** (⌘⌥M): the window shrinks to a slim bar with app icon, title,
  composer, elapsed time and transport controls, and returns to its previous
  size with the same shortcut.
- **Remote control via a URL scheme**, for scripts and shortcuts:
  `open "vicioussid://next"`, `playpause`, `stop`, `previous`,
  `seek?seconds=90`, `subtune?index=1`, `track?path=Hubbard_Rob/Commando.sid`.
  Deliberately not an HTTP server: a URL scheme is delivered locally and opens no
  port. Because any web page can trigger one, the scheme offers playback control
  only — track paths must stay below the autoplay folder and end in `.sid`, and
  anything else is rejected before it reaches the app.

## Performance

- Idle CPU load with a tune playing dropped from 48 % to 31 % of a core. The
  cause was neither the emulation nor the drawing: the per-voice display values
  (envelope, frequency, gate, waveform, pulse width) were published 50 times a
  second and rebuilt the entire user interface each time. The oscilloscopes now
  read them when they draw, and the elapsed time is only forwarded when it has
  changed by at least a tenth of a second.

## Correctness fixes since 1.9.0

- **Song lengths with Windows line endings were ignored entirely.** The HVSC
  ships `Songlengths.md5` with CRLF, and in Swift `"\r\n"` is a single character
  — splitting on `"\n"` found one giant line and therefore no entries at all.
- A prepared database with an infinite or absurd duration no longer reaches the
  scrubber or auto-advance.
- A malformed SID claiming an absurd number of subtunes no longer crashes the
  parser.
- The pulse waveform of the native engine matched the HTML5 engine only by
  accident; both now follow the same definition.
- Quick Look could crash on a file whose playing time could not be computed.
- Playlist, deduplication, search, favourites and the next-track calculation moved
  from the macOS view into the shared core, as did the song length resolution —
  both apps now follow the same tested rule instead of two similar ones.
- Track identity on macOS is a path relative to the autoplay folder. Two files
  with the same name in different folders are two tracks; previously entire
  folders were unreachable in a collection sorted by composer.
- **iOS:** after a system audio services restart the app rebuilt the tune but kept
  using the now invalid `AVAudioEngine`, which would have left it permanently
  silent while title and status looked correct. The engine is now recreated.
- **Linux CLI:** the arrow keys switch subtunes. Escape sequences are assembled
  instead of falling through as individual letters.
- The sidebar splitter no longer jitters, and the header keeps its labels at the
  minimum window width.

## Verification

- 192 tests in the Swift suite, including the new library outline, the STIL
  parser, the remote command validation, the terminal key decoder and the first
  test of the audio coordinator.
- The macOS app was measured against a synthetic collection of 50,001 files:
  memory, CPU load and scan duration, plus window captures of the folder tree,
  the tune notes and the mini player. The collection was generated locally and
  deleted afterwards.
- The iPhone app builds without warnings of its own and its simulator suite is
  green.
- Background playback, lock screen, AirPods, incoming calls, unplugging headphones
  and a media services reset **cannot be verified in the simulator** and are
  therefore not claimed as verified. The manual checklist for a real device is in
  `ios/GERAETETEST.md`.
- The tune notes were verified against a rebuilt `STIL.txt` in the documented
  format, not against a real HVSC file — none was available here.
- No SID music files are bundled. The HTML5 player is generated locally from the
  repository sources with `python3 build.py`.

Requires macOS 13 or later for the native app, iOS 17 or later and Xcode 16 or
later for the iPhone app. The Linux CLI requires ALSA and D-Bus runtime
libraries.
