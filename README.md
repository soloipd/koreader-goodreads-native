# Goodreads Native Sync for KOReader on Kindle

An experimental KOReader plugin for jailbroken Kindles that syncs Goodreads
shelf state, **live reading percentage, and explicit star ratings** through the
Kindle's existing Amazon/Goodreads session.

No Goodreads API key, Goodreads password, Amazon cookie, or manually supplied
account token is required or stored.

> [!WARNING]
> This plugin dynamically attaches a Java agent to Amazon's Kindle framework.
> It is firmware-specific, intended only for devices you own, and should be
> installed only from source or releases you trust.

## Features

- Puts a book on `Currently Reading` after KOReader records progress.
- Marks a book `Read` when KOReader completes it or reaches 99%.
- Silently sends the live rounded whole-number percentage shortly after open,
  periodically while reading, on suspend/resume, and on close.
- Runs KFX annotation-position translation in a detached worker, so page turns,
  suspend, book close, and the Bookshelf do not wait for the ARM extractor.
- Optionally imports native Kindle highlights and notes into the matching
  converted KOReader book using provenance-aware, conflict-safe reconciliation.
- Offers configurable 2, 5, 10, or 15 minute periodic checkpoints.
- Offers a one-time 1–5 star chooser when a book is completed.
- Supports manual rating updates and clearing an existing rating.
- Suppresses duplicate percentage updates per ASIN.
- Collapses duplicate highlight ranges while preserving an attached note, so
  rapid edits and removals converge on the latest KOReader state.
- Keeps shelf and percentage synchronization independently configurable.
- Provides opt-in, redacted, rotating diagnostics and an on-device status view.
- Includes a read-only, privacy-redacted SSH `doctor` that detects duplicate
  reader roots and missing runtime prerequisites without launching a reader.
- Persists a text-free per-book annotation receipt across KOReader restarts,
  distinguishing saved, waiting-for-Kindle, Amazon-queued, and independently
  cloud-observed states.
- Provides manual pending retry, confirmation-gated pending discard, and an
  anonymized support-summary export.
- Uses only the Kindle's native authenticated services.
- Never displays the native Goodreads sharing dialog.

## Requirements

- A jailbroken Kindle with KOReader.
- Kindle firmware whose Amazon framework includes Java 21 and `jdk.attach`.
- The Amazon account on the Kindle already linked to Goodreads.
- `kindle.koplugin`; notes/highlights require its position-map-enabled build,
  and native-to-KOReader import requires v0.0.7 or newer.
- The native Kindle framework must remain running; KOReader's
  `--framework_stop` mode is not supported.

Verified on:

- Kindle firmware **5.19.5**
- KOReader **v2026.07.1**

Other firmware versions may use different obfuscated class or method names.
Compatibility reports are welcome.

## Installation

1. Download `goodreads-native-koreader-vX.Y.Z.zip` from Releases.
2. Extract it into KOReader's plugin directory so this exact path exists:

   ```text
   /mnt/us/koreader/plugins/goodreads.koplugin/main.lua
   ```

3. Restart KOReader once.
4. Open **Main menu → Tools → More tools → Goodreads (native Kindle sync)**.
5. Leave **Automatic shelf sync**, **Silent percentage sync**,
   **Sync periodically while reading**, **Sync notes and highlights**, and
   **Prompt to rate completed books** enabled.

Existing cached EPUBs created before position-map support continue to work for
reading and progress, but annotation sync skips them safely. Regenerate each
cached conversion once with the position-map-enabled Kindle helper before
using annotation sync.

For an SSH installation from the repository checkout:

```sh
scp -P PORT -r goodreads.koplugin \
  root@KINDLE_IP:/mnt/us/koreader/plugins/
```

Restart KOReader after an install or upgrade. A full Kindle reboot is normally
unnecessary because the release agent uses a versioned class name.

The active product plan and release gates are maintained in
[ROADMAP.md](ROADMAP.md).

## Supported books

The plugin intentionally accepts only ten-character Amazon ASINs beginning
with `B`. It discovers them from:

- a `KINDLE_VIRTUAL://<ASIN>/...` path; or
- a filename ending in `_<ASIN>.<extension>`; or
- `kindle.koplugin`'s loaded virtual-library/content-catalog metadata for a
  converted cache UUID.

Local EPUBs without an Amazon ASIN are ignored because Goodreads book matching
would otherwise be ambiguous.

## Progress checkpoints

1. The plugin reads the open reader's live `ReaderPaging` or `ReaderRolling`
   percentage. The saved `percent_finished` sidecar is only a fallback because
   it may be stale until KOReader saves document settings.
2. A checkpoint runs shortly after open, at the configured interval, on
   suspend/resume, on close, or when **Sync current book now** is selected.
3. The plugin invokes the native KAF shelf action when applicable.
4. A helper attaches the release agent to the running Kindle framework.
5. The agent sends the same native `PostShareProgressRequest` used by Amazon's
   reader-sharing implementation.
6. HTTP 200 or 202 without a native error envelope counts as success.
7. The accepted integer percentage is saved under:

   ```text
   /mnt/us/koreader/settings/goodreads_native_progress/<ASIN>
   ```

The saved value contains no account information and prevents unchanged
percentages from being sent repeatedly. The periodic timer defaults to five
minutes, but only a changed whole-number percentage reaches the native service.

Periodic checkpoints use only the percentage transport; they do not repeatedly
publish an unchanged Currently Reading shelf action. When experimental native
annotation import confirms that Kindle has opened the exact local book, its
watcher captures the snapshot and then asks KOReader to exit normally. This
avoids leaving KOReader's power-event listener active behind KPP on affected
firmware. The handoff never force-kills KOReader.

On close, the live position is captured before KOReader unloads the document.
The delayed shell work survives a full KOReader exit and lets other close hooks
finish their native content-database writes first.

When the book is complete, KOReader displays a one-time rating chooser after
returning to the file browser. The chosen 1–5 star value is submitted through
the Kindle's native `rateABook` service. Rating `0` is exposed as **Clear
rating**. The plugin never guesses a rating from reading behavior.

You can also use **Rate current book…** while reading or **Rate last completed
book…** from the file browser.

## Diagnostics

Enable **Redacted debug log**, then select **Show sync diagnostics**. The view
compares:

- the currently open book's live percentage;
- the last percentage accepted and persisted for that ASIN; and
- the latest native result, including success, HTTP status, or failure stage.

For annotation sync, the same view also reads a durable per-book receipt from:

```text
/mnt/us/koreader/settings/goodreads_native_sync_receipts/<ASIN>
```

The receipt survives KOReader restarts and reports annotation/note counts,
timestamps, retry reason, agent generation, native lane, local readback,
upload-request status, and system-queue status. It contains no highlight or
note text. An accepted upload request is shown as **queued to Amazon**; it is
never called **cloud observed** without separate server readback.

Under **Sync receipts and recovery**, you can retry the selected book's pending
snapshot, discard only that pending snapshot after confirmation, or export an
anonymized support summary. The export replaces ASINs with `book_001`-style
labels and never reads annotation payload text. It is written to:

```text
/mnt/us/koreader/settings/goodreads_native_support.txt
```

The rotating log is stored at:

```text
/mnt/us/koreader/settings/goodreads_native_debug.log
```

It is capped at 128 KiB plus one rotated copy. It records timestamps, triggers,
ASINs, whole-number percentages, ratings, native status fields, and annotation
counts. It never records credentials, session values, response bodies, book
text, highlight text, or note text. Use **Clear debug log** before sharing a
device or support bundle if you do not want to disclose your reading ASINs.

## Notes and highlights

Annotation sync requires a converted book created by a position-map-enabled
`kindle.koplugin`. The converter records a text-free coordinate map, allowing
the plugin to translate KOReader's EPUB highlight ranges back to the original
Kindle KFX positions.

The plugin synchronizes:

- new and deleted highlights;
- new, edited, and removed notes; and
- the latest complete annotation state after rapid consecutive changes.

Synchronization is triggered when the reader opens, annotations change, the
device suspends or resumes, the book closes, or the manual sync action runs.
Requests are processed one at a time, and newer changes replace stale queued
snapshots for the same book.

### When the native Kindle book is closed

This firmware cannot reliably apply annotations through a detached background
book handle. A call may appear to succeed without producing a visible native
annotation or an Amazon upload. The plugin therefore writes the newest snapshot
to a private, root-only outbox under `/var/local` before position translation
or Java attachment. Each atomic replacement carries a monotonic per-book
sequence and SHA-256. A translated pending request then waits for the exact
local Kindle book to open, and a low-power listener retries automatically. A
cloud placeholder sharing the same ASIN is never used as a substitute for the
local book.

After KOReader exit, framework restart, sleep, or reboot, the source outbox is
reloaded and the newest snapshot resumes. Native success deletes the source
snapshot only through an atomic sequence/checksum comparison, so an older
in-flight request cannot erase a newer edit or deletion.

If startup replay briefly overlaps ReaderReady reconciliation, lock contention
is reported immediately and the newest snapshot retries after 15 seconds. It
does not consume the 120-second missing-result timeout.

### Experimental native Kindle → KOReader import

Enable **Import native Kindle highlights (experimental)** under **Tools →
Goodreads (native Kindle sync)**. Open or resume the local book once in the
native Kindle reader. A low-power watcher captures its current annotation
snapshot while ReaderSDK owns the exact local book. When the mapped converted
book next opens or resumes in KOReader, `kindle.koplugin` v0.0.7 reverse-
translates the native ranges in a detached batch.

The v2 exporter writes `snapshot_complete=true` only after the full bounded
native list has been enumerated, validated, and serialized. Missing or
incomplete snapshots cannot remove a KOReader highlight or note, or acknowledge
a pending deletion tombstone.

Version 0.8 records component-level provenance in KOReader's own annotation
metadata. Missing native highlights are created as native-owned. If a native
note fills an existing KOReader highlight, only the note is native-owned; the
highlight remains local. Later complete snapshots can apply native note edits,
note removal, and deletion of an unchanged native-created highlight.

Local work always wins. Editing or removing an imported note is never undone by
a stale native snapshot and protects the highlight from deletion. If Kindle
later echoes that exact local note state, the baseline safely rebases and normal
two-way deletion resumes. Changing an imported highlight's style detaches
highlight ownership. Native deletion may remove an unchanged imported note from
a pre-existing KOReader highlight, but never the highlight itself. Ambiguous
v0.7 markers are preserved and detached rather than guessed. Exact and reversed
duplicate ranges collapse.

Deleting a native-imported highlight in KOReader records a bounded, text-free
native-range tombstone. This prevents an older native snapshot from recreating
the highlight while KOReader's outbound deletion is still queued. The tombstone
is removed only when a later complete native snapshot no longer contains that
range. Tombstones contain coordinates and timestamps, never annotation text.

The root-only snapshot is removed only after KOReader's annotation persistence
event succeeds; a failed event is replayed without duplicating annotations.
That plugin-origin persistence event is not treated as a new user edit, so a
native import does not immediately enqueue an outbound echo. On reader startup,
pending native import is resolved before one converged outbound snapshot is
captured; an invalid or failed pending import blocks the stale pre-import
snapshot. The same guard covers suspend, close, manual sync, and recovered
outboxes. Later user edits continue to schedule normal reconciliation.
Annotation and note text never enter debug logs or dedupe receipts. The note
baseline used to detect local edits remains private inside KOReader's existing
annotation metadata.

Before annotation import or export, the plugin validates the native source
against Kindle's current read-only content catalog. If a conversion still
points at a file that Kindle moved or replaced, the unique readable, visible,
non-archived local ebook row is used. Multiple valid local rows are never
guessed between; annotation handoff pauses until the ambiguity is resolved.
The same validation runs before a pre-upgrade durable outbox is resumed. A
unique moved path is atomically rewritten at a newer sequence before execution,
while a stale or ambiguous outbox remains safely pending.

### Native and cloud delivery

When the exact native book is active, the plugin updates Kindle's local
annotation store and sends its annotation-change notification. It then uses the
pipeline enabled by the firmware:

- legacy firmware writes `JournalingService` entries and requests a
  `WhisperSyncV1` upload;
- KSDK-enabled firmware uses the KSDK annotation proxy; and
- the optional WhisperStore snapshot path is used only when the firmware has
  explicitly enabled it.

A request is reported as successful only after local readback, native
notification, a supported journal or KSDK write, and an upload-queue request
all succeed. Diagnostics report these stages separately and never treat a
disabled service as successful delivery.

### Upgrade repairs

The upgrade migration removes malformed annotations created by older
zero-endpoint mappings before replaying corrected ranges. Terminal KFX
positions are rebuilt through Kindle's native position factory, preventing a
small selection from expanding into an oversized highlight beginning at
location 1. Native highlight color is left unchanged.

### Privacy

Highlight and note text is limited to KOReader's metadata, root-only source and
pending files under `/var/local`, transient requests, Kindle's native annotation
store, and Amazon's normal annotation pipeline. Temporary and successfully
delivered requests are removed.
Diagnostics and support summaries contain counts and state only, never
annotation text. Text-free receipts and anonymized support summaries remain on
USB-visible `/mnt/us`; annotation payloads do not.

Annotations are delivered to Kindle/Amazon Notebook, not Goodreads. Goodreads
integration covers shelves, reading progress, completion, and ratings. This
plugin does not publish annotation text or change its sharing visibility.

See [Architecture](docs/architecture.md) and
[Kindle native-service notes](docs/reverse-engineering-notes.md) for details.

## Troubleshooting

Percentage synchronization is intentionally silent. Prefer **Show sync
diagnostics**. For a read-only SSH health report, run:

```sh
/mnt/us/koreader/plugins/goodreads.koplugin/bin/goodreads-doctor
```

Exit status `0` is healthy, `1` means warnings, and `2` means a hard error such
as multiple independent KOReader roots or an invalid agent installation. The
fixed-schema report contains only versions, booleans, and counts. It never
launches a reader and never prints ASINs, filenames, process arguments,
credentials, notes, highlights, or device identifiers.

These lower-level files remain available over SSH:

```text
/tmp/goodreads-progress-result.log
/tmp/goodreads-progress-attach.log
/tmp/goodreads-annotation-result.log
/tmp/goodreads-annotation-attach.log
```

A successful result resembles:

```text
http_status=202
response_valid=true
error_envelope=false
success=true
```

Common failure points:

- `failed_stage=parse_arguments`: invalid ASIN, percentage, or application.
- `failed_stage=resolve_native_services`: Amazon's Grok or reader-sharing
  service is unavailable, often because the native framework was stopped.
- `failed_stage=send_request`: network, account-linking, or firmware mismatch.
- HTTP 422: Amazon changed or rejected a request parameter.
- No result file: Java attachment failed; inspect the attach log.

The native Kindle Goodreads UI should work with the same account before this
plugin is expected to work.

Rating failures are shown immediately in KOReader. A successful rating is also
remembered locally so the completion prompt is not repeated for the same ASIN.

## Build and verify

With JDK 8 or newer, Lua 5.1/LuaJIT, ZIP, and optionally ShellCheck:

```sh
make build
make check
make package
```

Artifacts are written to `dist/` with a SHA-256 checksum. GitHub Actions runs
the same build and checks on every push and pull request.

## Security

The agent runs inside the Kindle framework and therefore deserves the same
trust scrutiny as any jailbreak extension. Review the source and verify release
checksums. Keep Kindle SSH key-only and disable it when not needed.

Please read [SECURITY.md](SECURITY.md) before reporting sensitive findings. Do
not post Amazon session data, device identifiers, credentials, or unredacted
framework logs in public issues.

## Limitations

- Goodreads receives integer percentages, matching Amazon's native request.
- Goodreads ratings are whole stars from 1–5; half-star ratings are not
  supported by the native service.
- Native annotation synchronization requires an EPUB produced by the
  position-map-enabled Kindle converter; older cached conversions must be
  safely regenerated once.
- Native-to-KOReader annotation import remains experimental and requires an
  exact active local KFX copy plus a compatible position map.
- Progress is sent from KOReader to Goodreads; this plugin does not download a
  Goodreads percentage into KOReader.
- Only ASIN-backed books are supported.
- Amazon may break compatibility in future firmware updates.
- This project is not affiliated with Amazon, Goodreads, or KOReader.

## License

[MIT](LICENSE)
