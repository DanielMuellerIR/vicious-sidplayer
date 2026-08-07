Vicious SID Player 1.9.0 adds a native iPhone app that shares the existing
emulation core, and moves the music library — index, recursive import, reset —
into that core as platform-neutral, tested logic. The iPhone app is its first
user; the macOS app still runs on its previous playlist code and will migrate
to the shared library later. The notarized macOS app and Quick Look extension
remain included in the DMG; macOS behaviour is unchanged.

## iOS app (iPhone)

- A native SwiftUI app in `ios/`, built from source and sideloaded with your own
  Apple Developer team. No private APIs, a privacy manifest, and clean UTIs, so
  the App Store route stays open.
- Background playback with lock-screen, Control Center and AirPods controls via
  `MPRemoteCommandCenter` and `MPNowPlayingInfoCenter`.
- Audio session handling for the cases a music app must get right: an incoming
  call pauses and resumes only when the system allows it, and unplugging
  headphones pauses instead of switching to the speaker.
- Recursive folder import that keeps the directory structure, skips duplicates by
  content, reports progress, can be cancelled, and collects per-file errors
  instead of aborting the whole run. Placeholder files from file providers such
  as iCloud Drive or Nextcloud are materialised before copying.
- Finder file sharing: connect the iPhone by cable and drag whole folders into
  the app. Files added or removed from outside are reconciled automatically.
- Reset library, confirmed twice, with an option to keep favorites.
- Oscilloscope, subtunes, voice muting, filter bypass, SID model selection, song
  lengths, search, favorites, shuffle, session restore, theme and WAV export.
- The oscilloscope and all UI timers only run in the foreground; in the
  background the audio keeps playing and the drawing stops.
- German and English, following the system language.

## Shared core

- The music library moved into `ViciousSIDPlayerCore`: index, recursive scan and
  reconcile, importer, and reset are platform-neutral and covered by tests.
- Track identity is a path relative to the library root rather than an absolute
  URL, so favorites and session restore survive a reinstall.
- Library reset can only delete below the library root; the check compares path
  components rather than string prefixes.
- `SidFileType` holds the `.sid` extension and the `com.viben.sid-tune` UTI in
  one place. The macOS open dialog now filters on it instead of offering every
  file.
- The core builds for iOS as well; two Foundation calls that do not exist there
  were replaced without changing macOS behaviour.

## Verification

- The Swift suite covers the new library logic, including structure-preserving
  import, deduplication, cancellation, reconcile against outside changes, and the
  reset path guard.
- A simulator suite covers the app model, the Info.plist contract, the privacy
  manifest, and a full import round-trip against a synthetic nested tree.
- Background playback, lock-screen control, AirPods, incoming calls and
  unplugging headphones **cannot be verified in the simulator** and are therefore
  not claimed as verified. The manual checklist for a real device is in
  `ios/GERAETETEST.md`.
- No SID music files are bundled. The HTML5 player is generated locally from the
  repository sources with `python3 build.py`.

Requires macOS 13 or later for the native app, iOS 17 or later and Xcode 16 or
later for the iPhone app. The Linux CLI requires ALSA and D-Bus runtime
libraries.
