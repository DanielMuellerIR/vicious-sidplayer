Vicious SID Player 1.9.49 improves iPhone selection and makes better use of the screen.

- Selecting a library tune during playback starts the new tune immediately. Selection while paused or stopped, and session restoration, prepare it. Native apps use the filename when the SID header has no title.
- Compact library rows and fixed collection tabs above search show more music. Mute and solo sit beside the waveforms; section looping and details are expandable. Start, end and repeat labels explain the previous A/B controls.
- Unknown song length is visible as “Max. 6:00”. Extended transition tests and system logs without tune names or paths support investigation of a reported device stop; its cause remains unconfirmed.

See [validation](docs/validation-1.9.49.md).

Vicious SID Player 1.9.48 respects explicit pause commands during iPhone audio interruptions.

- A Pause command received during Siri or another audio interruption cancels the pending automatic resume, even when the interruption has already paused the player.
- Preparing a different library tune also cancels that old resume permission. Missing, malformed or invalid selections preserve the previous tune and its resume state.
- Clarify real-device setup and add these cases to the [iPhone checklist](ios/GERAETETEST.md). Hardware acceptance remains open; see [validation](docs/validation-1.9.48.md).

Vicious SID Player 1.9.47 aligns the 6581 filter across output sample rates.

- Keep the existing 44.1 kHz output bit for bit and adapt its integrator coefficients to other output rates in native and HTML5 playback. The low-cutoff transition at 48 kHz no longer causes a large level drop.
- Prepare all 2048 cutoff coefficients once per emulator; the audio callback uses a lookup instead of additional exponentiation. The 8580 curve, resonance, warm mute/bypass state and A/B restoration retain their existing rules.

See [validation](docs/validation-1.9.47.md) for the approved reference, comparisons and limits.

Vicious SID Player 1.9.46 reduces unnecessary display work.

- Cap the Mac and HTML5 scope at 30 frames per second. Hidden or minimized Mac windows pause their visualizers and update playback time once per second; returning restores the display without restarting audio.
- Update native playback time at 10 Hz while the playback view is visible. The iPhone scope also pauses outside the Playback tab; audio, Auto-Next and media commands keep their independent paths.
- Keep the HTML5 position display moving in Piano and Registers views. Hidden pages skip analysis DOM updates; audio and song completion remain active.

See [validation](docs/validation-1.9.46.md) for matched measurements and hardware limits.

Vicious SID Player 1.9.45 improves keyboard access, spoken control names and compact layouts.

- Focus Mac library search with ⌘F and switch collection pages with ⌘1–4. Control groups wrap in narrow windows; the mini player keeps the same window.
- Navigate HTML5 collection tabs with arrow keys, Home and End. File loading, sliders and full metadata are accessible from the keyboard. Dialogs contain focus and restore it after closing; VoiceOver modifiers leave player shortcuts alone.
- Use larger iPhone subtune, transport and mini-player targets. Long metadata wraps fully; accessibility text switches analysis and playback controls to vertical groups, and landscape uses a shorter scope.
- Give search help, folder controls, filter state and subtune position explicit accessibility names and values. iPhone VoiceOver and external-keyboard acceptance remain part of the real-device checklist.

See [validation](docs/validation-1.9.45.md).

Vicious SID Player 1.9.44 adds SID v5 parsing and explicit compatibility limits.

- Decode Windows-1252 metadata in all supported versions. V5 accepts longer shared metadata, all seven multi-SID address layouts with up to three chips, and a common SID model.
- Use valid embedded v5 lengths for playback, subtune changes, search, audits and native export. Strip the length trailer from the C64 program; zero remains unknown. Personal end times and HVSC retain native priority.
- Report unsupported MUS, BASIC-start RSID, OPL and larger chip configurations clearly. Validate RSID header fields; simple machine-code IRQ cases start with CIA timing. V1 and PlaySID-specific files repeat the 32 speed bits for higher subtunes.
- Rebuild the derived metadata cache with the new interpretation while retaining the music index and personal data.

See [compatibility limits](docs/sid-compatibility.md) and [validation](docs/validation-1.9.44.md).

Vicious SID Player 1.9.43 keeps filtered voices warm while muted.

- Voice and chip mutes now remove filtered contributions at the output, preserving the continuously emulated shared filter state. Unmuting no longer introduces a filter transient caused by missing input while muted.
- Per-voice contributions also follow routing changes and native filter bypass. Prepared A/B loops retain these states; a completely muted chip produces exact silence.

See [validation](docs/validation-1.9.43.md).

Vicious SID Player 1.9.42 adds collection audits and explicit recovery of moved references on Mac, iPhone and HTML5.

- Check readable SID headers, complete content identities, duplicates, missing files and moved references without changing music. Native checks also report missing matches in loaded STIL and song-length databases.
- Inspect unique MD5 proposals before updating selected favorites, lists, bookmarks, notes and history. Ambiguous matches and references without a proven identity stay unresolved; the active listening sequence is retained.
- Cancel a check, filter findings, browse 20 per page and save the complete JSON report. Native inventories retain unresolved identities for a later check and preserve unreadable or newer inventory files.
- Browser imports retain moved references until an audit proposal is approved. File and folder drops capture their data before asynchronous work and work directly from the generated local HTML file.

See [validation and limits](docs/validation-1.9.42.md).

Vicious SID Player 1.9.41 adds M4A and FLAC to native batch export.

- Choose WAV, lossless 16-bit FLAC, or AAC in M4A at 128, 192, or 256 kbit/s. All formats use the existing duration, mix, filter, fade, naming, and cancellation rules on Mac and iPhone.
- M4A and FLAC include title, author, SID information, and subtune metadata. FLAC preserves the rendered WAV samples exactly. M4A retains the AAC encoder delay information and validates the exact number of usable samples.
- Short FLAC files use an explicit encoder block size; durations below 192 samples receive a clear error. Missing system encoders also produce a clear error without adding a codec dependency.

See [validation](docs/validation-1.9.41.md).

Vicious SID Player 1.9.40 adds batch WAV export with an explicit mix choice on Mac and iPhone.

- Preview the current subtune, all subtunes in a file, the listening sequence or visible library; macOS also offers the selected saved list. Choose entries and inspect resolved duration sources, file names and output size before rendering.
- Render the full mix, current mute/solo selection or one SID voice, with a filter setting, shared model/clock/fade options and an optional A/B interval. Single-voice files retain the chip filter state; rounding and clipping prevent a promise of bit-exact addition.
- Existing batch files receive collision-free names and cannot be overwritten by a race after preview. Cancellation removes the unfinished output and keeps complete files. Mac save panels and iPhone sharing use the same export plan without changing playback.
- Files using the first and third SID slots now retain both chips in stereo playback and WAV output.

See [validation](docs/validation-1.9.40.md).

Vicious SID Player 1.9.39 adds per-chip piano/frequency and register views, plus A/B loops on Mac, iPhone and HTML5.

- Read effective PAL/NTSC frequencies, approximate notes and emulated register values. Noise, combined waveforms and digi samples have visible pitch limitations; registers are read only.
- Set temporary A/B markers and repeat the interval without another history entry or Auto-Next. Pause retains the loop; Stop keeps the markers. Seeking outside turns it off, and a new file or subtune clears it. Native sleep expiry stops playback.
- Long A positions are prepared outside the audio callback. Repeated jumps restore the prepared CPU, memory, oscillator, envelope and filter state into existing buffers.

See [validation](docs/validation-1.9.39.md).

Vicious SID Player 1.9.38 fixes import recovery, personal data saving and queue control.

- An interrupted import no longer leaves an empty staging folder that blocks startup. macOS warns before quitting if custom end times could not be saved and allows a retry.
- Ending an iPhone queue closes its listening interval. Native subtune changes include the first interval in listening history.
- A personal data import no longer brings back old iPhone library entries after a reset. macOS applies an autoplay folder change made during an import when the merge finishes.
- List conflicts show the complete ordered paths and subtunes, including changes with the same name and entry count. In HTML5, delayed loading cannot restore an ended queue or a cleared library.

See [validation](docs/validation-1.9.38.md).

Vicious SID Player 1.9.37 adds separate mute and solo controls for up to three SID chips on Mac, iPhone and HTML5.

- Select the chip shown in the oscilloscope, with its model. Control each of nine voices or mute a whole chip. Multiple solos form a combined selection; mutes retain priority, and clearing solos keeps existing mutes.
- Mix choices survive pause, seek and emulator rebuilds. Solos on unavailable chips do not silence a tune with fewer chips. Analysis choices are temporary; music and exported personal data are unchanged.
- Native and web mixing, state transitions and real interfaces have been checked. See [validation](docs/validation-1.9.37.md).

Vicious SID Player 1.9.36 adds personal collection transfer to the standalone HTML5 player.

- Import native collection JSON with explicit conflict choices, reversible path acceptance and optional history. Export downloaded browser data in the same native format, preserving ordered duplicate list entries and exact bookmark positions.
- Verified music bytes supply MD5 identities; legacy FNV data and original storage remain protected. Browser writes share a Web Lock and recover interrupted two-document imports. Unsupported browsers keep personal data read-only.
- Native custom end times are explicitly excluded in HTML5; the original archive remains unchanged. Single-file file-system use is preserved. See [validation](docs/validation-1.9.36.md).

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
