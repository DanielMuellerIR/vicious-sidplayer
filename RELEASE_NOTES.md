Vicious SID Player 1.9.35 adds collection transfer to macOS and iPhone.

- Export selected favorites, ordered listening lists, favorite subtunes, bookmarks, notes and custom end times as local JSON. History is optional and disabled by default.
- Preview file identity, concrete conflicts and skipped entries before merging. Existing values are kept unless you choose the imported values. The active queue, playback position and timer are retained.
- Interrupted imports recover before personal data loads; changed, damaged or newer files remain protected. HTML5 transfer follows in a separate step. See [validation](docs/validation-1.9.35.md).

Vicious SID Player 1.9.34 prepares the portable collection format and conflict-aware merge in the shared core.

- Relative paths and MD5 content fingerprints distinguish moved, missing, changed and ambiguous files. Repeated import preserves list identities and does not add listening time twice.
- Bookmarks, file/subtune notes and personal end times retain explicit conflicts. History is optional and disabled by default. The import/export interface is still in development; collection transfer is not yet available in the apps.

Vicious SID Player 1.9.33 protects saved listening lists and playback settings against external changes. Temporary playback options remain available when their storage is read-only.

- Existing, changed, damaged or newer personal data is preserved before pending saves or a future import.
- The first storage component for collection transfer is tested, including rollback and interrupted-operation recovery. Import/export and conflict preview remain in development. See [validation](docs/validation-1.9.33.md).

Vicious SID Player 1.9.32 adds listening history, bookmarks and personal notes to macOS, iPhone and the standalone HTML5 player.

Automated checks and native/HTML5 visual acceptance have passed. See [validation](docs/validation-1.9.32.md).

- History sits beside Music, Lists and Queue. It records actual listening time after ten seconds, or half of a known short subtune. Seeking does not count as listening, and a prepared iPhone track stays unrecorded until playback starts.
- Named bookmarks return to a file, subtune and position. Personal notes can apply to the whole file or one subtune. Missing or changed files remain visible and cannot silently play a different tune.
- `heard:never`, `heard:yes` and `heard:unknown` extend the structured search. History keeps up to 2,000 plays from 180 days; the heard index survives automatic pruning. Explicitly clearing history also resets that index and preserves bookmarks and notes.
- Personal data stays local. Unsupported, damaged or externally changed data is preserved. The Mac waits for pending history saves when quitting; iPhone saves when moving to the background. Browser users must select their music files again after restarting.
- Bookmarks beyond 20 minutes remain stored with an explicit position-jump limit; playback from the beginning remains available. Cross-platform transfer of personal data is planned separately.

Vicious SID Player 1.9.26 adds Sparkle updates to the macOS app.

- The app checks for signed updates in the background. “Nach Updates suchen…” in the app menu starts an immediate check; installation requires your approval.
- The release workflow validates the notarized DMG and signs the update feed. Feed and archive signatures are checked against the public key in the shipped app before publication.
- The first Sparkle-enabled release needs a manual installation. GitHub Pages and the signing secret must be configured before publishing the first feed.

## Earlier changes

Vicious SID Player 1.9.25 fixes seek, library import and iOS reset behavior.

- Native seek applies voice mute before fast-forwarding, preserving the correct filter state at the destination.
- Large flat imports read each destination directory once per batch. Numbered variants, gaps and Unicode case variants remain covered by duplicate detection.
- iOS library reset prevents track and subtune changes from starting new song-length estimates while reset is in progress.
- Release tagging keeps the verified branch commit even when a tag has the same name as the branch.

Vicious SID Player 1.9.24 improves library safety, playback state and compatibility across macOS, iOS, Linux and the standalone HTML5 player.

## Library and native apps

- STIL folder notes now appear even when a tune has no separate file entry. Wide macOS sidebars keep their controls and labels visible.
- iOS library selection prepares the tune; Play starts it. A new selection stops the previous tune. Invalid or missing selections preserve the current state.
- Library reset validates the complete operation before moving files and commits the new state only after every move succeeds. A failed move restores the previous files, index and app state. Recovery paths and retained storage are reported if a later filesystem error prevents full cleanup.
- Import deduplication preserves differently cased collision variants, finds duplicates beyond gaps in numbered names, and excludes symlinks outside the library. Aliased music and support roots are rejected during reset.
- Paused and stopped tunes no longer trigger automatic advancement. Startup scans respect explicit track selection and Stop. External files remain visible in folder view, and Play after clearing the playlist stays stopped.
- Now Playing updates follow seek, subtune and duration changes without excessive updates.
- Quick Look and the macOS file picker also accept the SID file type registered by SIDPLAY, so an existing SIDPLAY installation does not hide SID files or prevent the preview.

## Emulation and playback

- Seek reconstructs the complete SID state, including CPU decisions that depend on SID register readbacks. Native seek preparation runs away from the main thread and can be cancelled by a newer seek, Stop or a track change.
- Restart and subtune changes restore the original RAM image before initialization, including tunes with self-modifying or non-idempotent initialization routines.
- Corrected zero-page indirect addressing and noise restart state. PSID version 1 and malformed or overlapping headers are handled consistently.
- The HTML5 engine applies the file's model preference separately for each SID chip.
- The Apple CLI waits for the final audio buffer and output latency before reporting natural completion. Pipe output remains interruptible when the receiver stops reading, and external termination restores terminal settings.
- Song-length parsing rejects malformed rows without shifting subtune durations. Invalid dump durations fail with a controlled error.

## Standalone HTML5 player and releases

- Embedded AudioWorklet code loads through a data URL, allowing the generated single-file player to run directly from `file://`.
- Track names are rendered as text. Import deduplication compares path and content and handles concurrent batches consistently.
- Stop during asynchronous audio setup remains stopped. Failed selections cannot play the previous file, and late playback completions cannot reactivate the display. The first theme change also works with the system dark theme; light-mode labels and oscilloscope traces remain readable.
- DMG creation uses isolated temporary files and detaches only its own mounted image. Installation validates app identity and notarization before replacement. Publishing uses an explicit destination and checks branch and tag identity.

## Verification

- Swift core tests, JavaScript regressions, iOS simulator build and tests, CLI signal/pipe checks, release guards and publication-history checks passed.
- Swift and HTML5 output matched sample for sample for 88,200 samples per model, tested separately for 6581 and 8580.
- Native macOS and iOS simulator views were inspected with synthetic SID/STIL fixtures. No copyrighted music is bundled.
- A synthetic 50,001-track library used about 281 MiB RSS with a warm index and a paused tune. Three app scan runs took 2.20–2.22 seconds without an index and 2.33–2.45 seconds with an index and playback. These measurements describe the tested local storage and fixtures.
- Linux MPRIS and Cinnamon media-key routing were exercised in an isolated desktop session with silent audio output.
- Physical iPhone background playback, lock-screen controls, AirPods, calls, headphone removal and audio-service resets remain device checks in `ios/GERAETETEST.md`. Simulator tests do not establish those behaviors or subjective audio quality.
