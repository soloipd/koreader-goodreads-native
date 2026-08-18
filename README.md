# Goodreads Native Sync for KOReader on Kindle

An experimental KOReader plugin for jailbroken Kindles that syncs Goodreads
shelf state, **live reading percentage, manual shelf choices, and explicit star
ratings** through the Kindle's existing Amazon/Goodreads session.

No Goodreads API key, Goodreads password, Amazon cookie, or manually supplied
account token is required or stored.

> [!WARNING]
> This plugin dynamically attaches a Java agent to Amazon's Kindle framework.
> It is firmware-specific, intended only for devices you own, and should be
> installed only from source or releases you trust.

## Features

- Puts a book on `Currently Reading` after KOReader records progress.
- Marks a book `Read` only when KOReader explicitly completes it or you choose
  the native Read shelf; 99% remains `Currently Reading`.
- Lets you explicitly choose `Want to Read`, `Currently Reading`, or `Read`
  through Kindle's native Goodreads bridge.
- Keeps bounded private local first-read, reread, completion, and DNF sessions
  with streak, pace, projected-finish, annual-goal, and export views.
- Silently sends the live rounded whole-number percentage shortly after open,
  periodically while reading, on suspend/resume, and on close.
- Runs KFX annotation-position translation in a detached worker, so page turns,
  suspend, book close, and the Bookshelf do not wait for the ARM extractor.
- Optionally imports native Kindle highlights and notes into the matching
  converted KOReader book using provenance-aware, conflict-safe reconciliation.
- Recognizes an exported KOReader annotation by its exact canonical KFX range,
  even when reverse translation spells an EPUB endpoint one character
  differently, so a native echo cannot create a duplicate.
- Offers configurable 2, 5, 10, or 15 minute periodic checkpoints.
- Offers a one-time 1–5 star chooser when a book is completed.
- Supports manual rating updates and clearing an existing rating.
- Suppresses duplicate percentage updates per ASIN.
- Collapses only exact duplicate highlight ranges while preserving an attached
  note. Nearby selections that share Kindle's coarse locations remain separate
  through their precise KFX offsets.
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

When KOReader explicitly marks the document complete, it displays a one-time
rating chooser after returning to the file browser. The chosen 1–5 star value
is submitted through the Kindle's native `rateABook` service. Rating `0` is
exposed as **Clear rating**. A manual Read shelf choice records local
completion and enables **Rate last completed book…**; a percentage, including
99%, never implies completion or a rating. The plugin never guesses a rating
from reading behavior.

You can also use **Rate current book…** while reading or **Rate last completed
book…** from the file browser.

## Manual shelf selection

With an ASIN-backed book open, choose **Goodreads (native Kindle sync) → Set
Goodreads shelf…** and select **Want to Read**, **Currently Reading**, or
**Read**. These are the three canonical shelves exposed by the tested Kindle
firmware.

A manual selection is reported as successful only when the native Kindle
response names that exact shelf. The plugin stores a bounded local override so
an unchanged periodic checkpoint cannot immediately reverse your choice.
Selecting Want to Read or Read suppresses contradictory percentage writes while
the book remains at the same whole-number percentage. New reading progress—or
an explicit KOReader completion—consumes the override and resumes automatic
shelf and percentage behavior. A confirmed Read choice completes the active
local history session. A confirmed Currently Reading choice starts an initial
session or a separate reread when the previous session ended. The override
stores no title or account data.

## Private reading history

Open **Goodreads (native Kindle sync) → Private reading history** to view local
statistics, mark or undo DNF, start a separate reread, choose an annual
completion goal, or export CSV and JSON.

The history is local to this plugin. Kindle firmware 5.19.5 exposes native
Goodreads writes only for Want to Read, Currently Reading, Read, percentage,
and rating; it does not expose DNF, start/finish dates, reread sessions, goals,
or statistics. The plugin therefore never claims those local facts reached
Goodreads.

Checksummed primary and backup state live under the root-only directory:

```text
/var/local/koreader-goodreads-native/
```

It contains only ASINs, timestamps, outcomes, percentages, and day keys—never
titles, authors, paths, annotation text, account data, or device identifiers.
Writes are serialized, bounded, and atomically replaced. A corrupt primary can
recover from the last valid backup; if both copies are invalid, the feature
fails closed instead of overwriting them. Lock and state readers accept only
bounded regular files, while exclusive random temporary files prevent a stale
or malformed filesystem object from blocking a reader hook or being reused.

The explicit export action writes:

```text
/mnt/us/koreader/settings/goodreads_reading_history.csv
/mnt/us/koreader/settings/goodreads_reading_history.json
```

Those user-facing files include ASINs and reading timestamps. They are not
uploaded by the plugin, but `/mnt/us` is USB-visible and its FUSE filesystem
does not provide a dependable POSIX privacy boundary. Treat the files as a
private personal export and remove them when no longer needed.

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

The receipt survives KOReader restarts and reports KOReader source-entry and
note counts alongside the deduplicated native KFX range count, plus timestamps,
retry reason, agent generation, native lane, local readback, upload-request
status, and system-queue status. Multiple EPUB ranges can resolve to one exact
KFX range; in that case Kindle stores one highlight and retains the note-bearing
version. The receipt contains no highlight or note text. A reconciliation that
actually writes the native cloud lane is
shown as **queued to Amazon**. An idempotent native readback with no new cloud
write is shown as **verified unchanged** and does not claim an upload or wake
the system queues. Neither state is called **cloud observed** without separate
server readback.

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

### Recommended KOReader workflow

For dependable outbound synchronization, treat the mapped KOReader book as the
source of truth. Make each change once in KOReader and allow it to reconcile
before changing the same annotation in the native Kindle reader. Amazon
Notebook is a downstream destination; this plugin does not import changes
directly from the website.

To create a highlight or note:

1. Select the text and create the highlight in KOReader.
2. Add a note to that existing highlight, if wanted, and save it.
3. Continue reading normally. The annotation-change hook schedules the newest
   complete snapshot; closing the book is not required.

To edit an annotation, edit the note attached to the existing highlight and
save it. Removing only the note keeps the highlight. To change the selected
text range, delete the old highlight and create a new one; rapid consecutive
changes are serialized and the newest complete snapshot replaces stale queued
work.

To delete an annotation, delete the highlight in KOReader. Its attached note is
deleted with it. Do not repeat the deletion in the native reader or Amazon
Notebook while the KOReader change is pending.

To check delivery, open **Main menu → Tools → More tools → Goodreads (native
Kindle sync) → Show sync diagnostics**:

- **waiting for native reader** means the newest snapshot is safely queued.
  Open the exact downloaded local Kindle copy once and let the book finish
  loading; the low-power listener will retry automatically. A cloud-only
  placeholder with the same ASIN is intentionally ignored.
- **queued to Amazon** means the local Kindle store was verified, the supported
  native journal was written, and an Amazon upload was requested. Amazon
  Notebook can still take time to display the change.
- **verified unchanged** means the native store already matched the requested
  snapshot, so no duplicate cloud write or queue wake was needed.

**Sync current book now** is a recovery nudge, not a required step after every
change. Select it once if needed; repeated taps are unnecessary. Open, close,
suspend, and resume remain additional safety checkpoints, and durable pending
work survives KOReader exit, sleep, framework restart, and reboot.

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

The listener keeps one filtered DBus subscription rather than repeatedly
starting monitor processes. One exact native-book activation permits one group
of at most three attempts: immediately, then after approximately 200 ms and
600 ms. The reader-start event produced by the helper's own Java attachment is
ignored, so it cannot recursively start more retry groups. A newer queued
snapshot, or a real transition away from and back to the exact local book,
re-arms the group. The listener owns and reaps its DBus child and exits when the
pending queue is empty.

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
book next opens or resumes in KOReader, `kindle.koplugin` v0.0.7 or newer
reverse-translates the native ranges in a detached batch.

The v3 exporter writes `snapshot_complete=true` only after the full bounded
native list has been enumerated, validated, and serialized. Missing or
incomplete snapshots cannot remove a KOReader highlight or note, or acknowledge
a pending deletion tombstone.

The provenance-aware importer records component-level ownership in KOReader's
own annotation metadata. Missing native highlights are created as native-owned.
If a native note fills an existing KOReader highlight, only the note is
native-owned; the highlight remains local. Later complete snapshots can apply
native note edits, note removal, and deletion of an unchanged native-created
highlight.

Local work always wins. Editing or removing an imported note is never undone by
a stale native snapshot and protects the highlight from deletion. If Kindle
later echoes that exact local note state, the baseline safely rebases and normal
two-way deletion resumes. Changing an imported highlight's style detaches
highlight ownership. Native deletion may remove an unchanged imported note from
a pre-existing KOReader highlight, but never the highlight itself. Ambiguous
v0.7 markers are preserved and detached rather than guessed. Exact and reversed
duplicate ranges collapse. A durable root-only identity receipt maps each
current KOReader range to the exact KFX endpoints accepted by Kindle. Import
uses that native identity instead of requiring a byte-for-byte XPointer match;
only an unchanged native-owned echo is removed, while local notes, edits, and
ownership are preserved.

Deleting either a native-imported highlight or a previously exported local
highlight in KOReader records a bounded, text-free native-range tombstone. This
prevents an older or direction-reversed native snapshot from recreating the
highlight while KOReader's outbound deletion is still queued. The tombstone is
removed only when a later complete native snapshot no longer contains that
range. Tombstones contain coordinates and timestamps, never annotation text.

The root-only snapshot is removed only after KOReader's annotation persistence
event succeeds; a failed event is replayed without duplicating annotations.
That plugin-origin persistence event is not treated as a new user edit, so a
native import does not immediately enqueue an outbound echo. On reader startup,
pending native import is resolved before one converged outbound snapshot is
captured. A transient reverse-position helper exit retries the complete
import-first flow twice after short delays; malformed snapshots, rejected
coordinates, and an exhausted retry budget block the stale pre-import snapshot
instead of exporting it. Retries are cancelled if the reader changes books.
The same ordering guard covers suspend, close, manual sync, and recovered
outboxes. Later user edits continue to schedule normal reconciliation.
Annotation and note text never enter debug logs or dedupe receipts. The note
baseline used to detect local edits remains private inside KOReader's existing
annotation metadata.

Before annotation import or export, the plugin validates the native source
against Kindle's current read-only content catalog. If a conversion still
points at a file that Kindle moved or replaced, the unique readable, visible,
non-archived local ebook row is used. Multiple valid local rows are never
guessed between; annotation handoff pauses until the ambiguity is resolved.
The same validation runs before a pre-upgrade durable outbox is resumed. Unique
current native-book and converted-EPUB paths are atomically rewritten together
at one newer sequence before execution, while a stale or ambiguous outbox
remains safely pending.

### Native and cloud delivery

When the exact native book is active, the plugin updates Kindle's local
annotation store and sends its annotation-change notification. It then uses the
pipeline enabled by the firmware:

- legacy firmware writes `JournalingService` entries and requests a
  `WhisperSyncV1` upload;
- KSDK-enabled firmware uses the KSDK annotation proxy; and
- the optional WhisperStore snapshot path is used only when the firmware has
  explicitly enabled it.

When a change is required, a request is reported as queued only after local
readback, native notification, a supported journal, KSDK, or enabled snapshot
write, and the corresponding upload-queue request all succeed. If exact native
readback proves that every requested range and note is already present, the
plugin reports **verified unchanged**, acknowledges the local outbox, and does
not pretend that a new upload occurred. Contradictory or incomplete delivery
proof fails closed and remains retryable. Diagnostics report every stage
separately and never treat a disabled service as successful delivery.

After a verified mutation of the exact active book, the agent emits one
payload-free native annotation-change notification. This refreshes the
already-open Kindle page after a create, note edit, note removal, or deletion;
an unchanged reconciliation emits no full overlay refresh.

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
The root-only annotation identity receipt contains normalized EPUB XPointers,
exact KFX coordinates, a sequence, and a checksum—but no title, selected text,
note text, account data, or credential.
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

On macOS, the scripts reject Apple's nonfunctional Java placeholders and also
look in common Homebrew OpenJDK locations. `JAVA_HOME`, `JAVA`, `JAVAC`, and
`JAR` remain available as explicit overrides.

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
- Native shelf selection is limited to Want to Read, Currently Reading, and
  Read. Custom shelves and DNF are not exposed by this firmware bridge.
- Start/finish dates, reread sessions, DNF, streaks, goals, and history exports
  are local-only; the firmware's native Goodreads bridge does not accept those
  fields.
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
