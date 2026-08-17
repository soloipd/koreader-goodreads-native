# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

## [0.11.1] - 2026-08-17

### Fixed

- Diagnostics now distinguish KOReader source entries from deduplicated native
  KFX ranges, and the doctor counts the real root-only annotation pending queue
  plus only exact native-import watcher processes.
- Native-reader startup replay now follows the firmware's filtered DBus
  `appStarted` signal with staggered exact-handle attempts, while retaining the
  bounded LIPC fallback. Watcher locks carry an owner PID, recover dead owners,
  cannot be removed by a departing older instance, and TERM interrupts the
  blocking Kindle event child so upgrades leave exactly one watcher.
- Close-time snapshots no longer supersede an identical translated snapshot
  that is already pending for the same outbox sequence.
- Idempotent annotation readback is reported as `verified_unchanged`; it no
  longer claims a journal write, upload request, or system-queue wake that did
  not occur. Contradictory delivery proof fails closed and stays retryable.
- Annotation agent generation 30 forces the corrected delivery contract to
  load even when an older agent class remains resident in Kindle's JVM.
- Java-agent archives now use fixed entry timestamps and a fixed manifest
  producer; the release gate rebuilds them and requires identical checksums.
- A transient native-to-KOReader position-helper exit now retries the complete
  import-first reconciliation twice with short backoff. Invalid snapshots and
  rejected coordinates still fail immediately, and retries remain latest-book
  scoped so they cannot run after the reader changes books.

### Tests

- Added source-entry versus unique-native-range diagnostics, delivery-contract
  regressions, deterministic agent checks, blocked-TERM recovery, stale-lock
  takeover, 1,000 handoffs, and 50 simultaneous watcher starters.

## [0.11.0] - 2026-08-17

### Added

- Private local start/finish dates and separate first-read, reread, and manual
  reading sessions for ASIN-backed books.
- Explicit local DNF, undo DNF, and start-reread actions under **Private
  reading history**. DNF never changes the native Goodreads shelf.
- Local reading streak, pace, projected-finish, completion, reread, and DNF
  statistics plus annual completion goals.
- Explicit CSV and JSON history export containing only ASINs, lifecycle
  timestamps, outcomes, percentages, and reading-day keys.

### Changed

- Ninety-nine percent remains Currently Reading. A book becomes Read only from
  KOReader's explicit complete status or the manual native Read action.
- A confirmed manual Read completes the current local session; a confirmed
  manual Currently Reading action starts or resumes an active session.
- Build and check scripts now verify that Java tools actually run and discover
  common Homebrew JDK paths, bypassing macOS's nonfunctional Java placeholders.

### Safety

- Lifecycle state is bounded, strictly parsed, sequence numbered, SHA-256
  protected, atomically replaced under `/var/local`, and recovered from one
  previous valid copy after interrupted writes.
- A lock serializes file-manager and reader instances. Stale locks recover,
  narrowly named interrupted temporary files are removed on the next write,
  and two invalid state copies fail closed without overwrite.
- Stale-lock recovery is itself serialized. Missing, oversized, FIFO, and
  symlink lock owners are never opened as trusted owner records, so malformed
  lock state cannot block the KOReader UI.
- Checksum inputs, lifecycle replacements, and user exports use exclusive,
  mode-0600 random temporary files. Package preflight rejects symlinks and all
  primary, backup, or suffixed private-history artifacts.
- Release archives use sorted file input with host-specific ZIP metadata
  removed, so unchanged plugin source reproduces the same checksum while
  retaining executable helper modes.
- Repeating Read is idempotent even if the current page changed; it cannot
  invent another completion. Rereads become separate active sessions first.
- The native firmware bridge is still canonical only for Want to Read,
  Currently Reading, Read, progress, and ratings. Local DNF, lifecycle dates,
  rereads, statistics, goals, and exports are never reported as Goodreads
  cloud fields.
- Private state and user-created history exports are explicitly excluded from
  release packages.

### Tests

- Added 99%-versus-complete integration coverage, codec and bounds tests,
  1,000 same-day checkpoints, 32 rereads, active/stale lock behavior, every
  atomic-write interruption boundary, checksum corruption, backup recovery,
  failed-closed dual corruption, export privacy, and mode-0600 verification.
- Added FIFO/symlink nonblocking probes, 24-writer normal concurrency and
  64-writer release stress, stale-lock contention, parser-amplification bounds,
  and clean/suffixed-private/symlink package fixtures.

## [0.10.0] - 2026-08-17

### Added

- Manual native Goodreads shelf selection for Want to Read, Currently Reading,
  and Read from the KOReader menu.
- A bounded per-book explicit-choice override so an unchanged periodic
  checkpoint cannot immediately undo the selected shelf.

### Safety

- Manual shelf changes succeed only when the Kindle native response reports
  the exact requested shelf. A missing or different readback creates no local
  success receipt.
- A failed background shelf-command launch is reported as a failure and creates
  no queued receipt.
- Want to Read and manually selected Read suppress contradictory percentage
  traffic until genuine new progress or completion resumes automatic policy.
- Durable overrides contain only an ASIN, native action, whole percentage, and
  timestamp; malformed entries are discarded and only the newest 64 survive.

### Tests

- Added exact-readback, prefix-confusion, process-launch failure,
  override-consumption, zero-progress, invalid-state, and 100-book bounded-state
  coverage.

## [0.9.1] - 2026-08-16

### Fixed

- Distinct nearby highlights that share Kindle's coarse KFX locations now use
  their exact short offsets as part of the durable identity. They are no
  longer rejected or merged during KOReader-to-Kindle reconciliation.
- If two EPUB ranges resolve to the same exact KFX range at a map boundary,
  Kindle receives its one representable highlight with the non-empty note;
  both source annotations remain untouched in KOReader.
- Native Kindle export and KOReader import use the same exact identity, so a
  note remains paired with the correct nearby highlight in both directions.
- Generation-27 coordinate-only state and version-1 import provenance migrate
  conservatively; annotation text is not added to state, receipts, or logs.

### Tests

- Added regressions for adjacent same-location highlights, exact note pairing,
  exact-duplicate rejection, provenance migration, and the existing
  1,000-annotation conflict/deletion stress suite.

## [0.9.0] - 2026-08-16

### Added

- `goodreads-doctor`, a read-only SSH health command with a fixed redacted
  schema. It reports plugin/runtime state, exact KOReader reader/root counts,
  watcher state, queue counts, and agent count without launching a reader.
- A maintained roadmap on `main` with implementation status and explicit
  release/UAT gates.

### Safety

- Doctor output never contains ASINs, filenames, process arguments,
  credentials, annotation text, note text, or device identifiers.
- Duplicate independent KOReader roots and stale/multiple export agents are
  hard errors; missing Java/framework prerequisites are explicit warnings.
- CI and release stress include privacy fixtures, fault injection, forbidden
  mutation-primitive checks, and a synthetic 1,003-process reader tree.
- Native-import persistence events are origin-guarded so importing a Kindle
  snapshot cannot enqueue an unnecessary outbound echo; later user edits still
  schedule normally.
- Reader startup now resolves a pending native snapshot before capturing any
  outbound annotation state. Invalid, mismatched, or failed pending imports
  block the pre-import snapshot instead of risking stale native deletions.
- The same fail-closed ordering applies to suspend, close, manual sync, and
  crash-recovered outboxes, preventing lifecycle races around ReaderReady.
- Annotation handoff repairs a stale `kindle.koplugin` source path from
  Kindle's current content catalog. Only one readable, visible, non-archived,
  fully local ebook row is accepted; ambiguous catalog results fail closed.
- Pre-upgrade durable annotation outboxes are revalidated before crash
  recovery. Unique current native-book and converted-EPUB paths are rewritten
  together at one newer sequence; stale or ambiguous paths remain pending and
  are never executed.

## [0.8.0] - 2026-08-16

### Added

- Component-level native annotation provenance in KOReader metadata. A newly
  imported highlight records native range ownership, while a native note added
  to an existing KOReader highlight owns only that note component.
- Safe native-to-KOReader reconciliation for native note edits, note removal,
  and highlight deletion from complete native snapshots.
- Durable, text-free native-range tombstones prevent a stale native snapshot
  from recreating a highlight that was just deleted in KOReader. They clear
  only after a complete native snapshot confirms the deletion.

### Safety

- A native deletion removes a native-created KOReader highlight only while its
  imported note and style remain unchanged. A local note edit wins over stale
  native snapshots and protects the highlight until Kindle echoes the same edit;
  that exact echo safely rebases ownership. A local style edit detaches it.
- A native deletion can remove an unchanged imported note from a pre-existing
  KOReader highlight, but can never delete that highlight.
- Ambiguous v0.7 import markers migrate by preserving the annotation and
  discarding the marker; this release never guesses historical ownership.
- Failed KOReader persistence events retain and replay the private snapshot.
  Annotation text remains confined to Kindle's native store and KOReader's own
  private annotation metadata and never enters diagnostics or receipts.
- The release gate stress-tests a maximum-size 1,000-annotation import and mass
  deletion with 500 local conflicts that must all survive.

## [0.7.1] - 2026-08-17

### Fixed

- After a confirmed native-reader annotation capture, the watcher now asks the
  main KOReader process to exit through its normal `SIGTERM` shutdown path.
  This prevents a Kindle firmware power-event/D-Bus loop when KOReader remains
  alive behind KPP; child helpers are excluded and no force-kill is used.
- Periodic percentage checkpoints no longer republish an unchanged native
  Goodreads shelf action. Shelf state still syncs on reader lifecycle and
  manual checkpoints, while periodic ticks use only the percentage transport.
- CI and tagged releases now require lifecycle stress tests covering 1,000
  handoffs, 50 concurrent watcher starts, 1,000 forked helper candidates, and
  1,000 periodic checkpoints.

## [0.7.0] - 2026-08-16

### Added

- Opt-in experimental import of native Kindle highlights and notes into the
  matching converted KOReader book.
- A read-only framework exporter, low-power native-reader watcher, root-only
  durable handoff, and detached reverse translation through
  `kindle.koplugin` v0.0.7.

### Safety

- Import is additive: missing ranges are created and empty notes may be filled.
  Existing non-empty KOReader notes are never overwritten.
- Native deletions do not delete KOReader annotations in this release, and
  snapshots are acknowledged only after KOReader's persistence event.

## [0.6.2] - 2026-08-16

### Fixed

- Native annotation lock contention now publishes an immediate retryable
  `lock_busy` result instead of making KOReader poll for 120 seconds.
- Startup/ReaderReady overlap now produces a redacted durable receipt and uses
  the existing 15-second bounded retry/coalescing path.

## [0.6.1] - 2026-08-16

### Fixed

- KFX annotation-position translation now runs in a detached, mode-0600
  worker instead of blocking KOReader's UI thread during page turns, suspend,
  book close, or the return to Bookshelf.
- Translation output is committed by atomic rename and polled asynchronously.
  Invalid, failed, and timed-out jobs retain the durable source outbox and use
  the existing bounded retry path.

### Added

- Regression checks that reject a blocking annotation translator and verify
  the detached translation-to-native-helper handoff.

## [0.6.0] - 2026-08-16

### Added

- A crash-safe source annotation outbox under `/var/local` that is atomically
  replaced before position translation or Java attachment.
- Monotonic per-ASIN sequence numbers and SHA-256 verification for every
  source snapshot.
- Compare-and-delete acknowledgement: successful native reconciliation can
  remove only the exact sequence/checksum it processed, never a newer edit.
- Automatic outbox resumption after KOReader restart and manual recovery from
  the existing receipt menu.
- Deterministic tests for 1,000 rapid replacements, note edits/removals,
  interrupted temporary files, corrupt snapshots, stale sequence state, and
  acknowledgement races.

### Changed

- Translated inactive-book snapshots now persist under root-only
  `/var/local` storage. Existing `/mnt/us` pending snapshots migrate on replay.
- Annotation success now requires acknowledged deletion of the matching source
  outbox snapshot in addition to native readback and upload-queue acceptance.

## [0.5.0] - 2026-08-16

### Added

- Durable, text-free per-book annotation receipts that survive KOReader
  restarts and distinguish local save, native-reader wait, Amazon queue, and
  independently verified cloud states.
- Receipt diagnostics for counts, timestamps, retry reason, agent generation,
  active native lane, local readback, upload request, and system queue.
- Manual retry and confirmation-gated discard actions for the selected book's
  pending annotation snapshot.
- A support-summary export that substitutes anonymous book numbers for ASINs
  and never reads annotation payload text.

### Changed

- Annotation payloads now carry bounded retry and trigger metadata so durable
  receipts remain meaningful after native-reader replay.
- Upload acceptance is explicitly reported as queued, never as cloud-observed
  without independent readback.

## [0.4.1] - 2026-08-16

### Fixed

- Exact and endpoint-reversed duplicate KOReader annotation ranges are now
  collapsed before translation and native reconciliation. If only one copy has
  a note, that note is retained. Rapid create/delete sequences can therefore
  coalesce to their latest state without the native agent rejecting the batch.
- Annotation validation failures now report their ASIN and request ID as soon
  as those fields are validated, allowing the queue to correlate failures
  immediately instead of waiting for the native-agent timeout.

## [0.4.0] - 2026-08-16

### Fixed

- KFX short PIDs are now preserved alongside long positions. Reconstructing a
  position from its long form alone could produce an end PID of zero, turning a
  short selection into an apparent highlight from the beginning of the book.
- Annotation writes now select the cloud path that the running firmware has
  actually enabled. On legacy-journal firmware they create native
  `JournalingService` entries and request `WhisperSyncV1`; on KSDK firmware
  they use the KSDK annotation proxy. The disabled WhisperStore bridge is no
  longer treated as evidence that an upload was accepted.
- Annotation reconciliation now requires the exact active local KFX path;
  same-ASIN cloud placeholders and detached handles are never mutated or
  reported as synced. Inactive snapshots coalesce in a root-only pending queue
  and a single LIPC watcher replays them automatically when Kindle starts the
  native reader for that book.
- Existing malformed zero-endpoint records are removed locally and from
  WhisperStore once, then the corrected highlights and notes are replayed.
- Color-highlight metadata is normalized only for the cloud call, working
  around firmware that casts Kindle's color map directly to a string while
  leaving the native highlight and its color unchanged.
- Success now requires local close/reopen readback, native notification, a
  firmware-supported native journal write, an upload request, and acceptance
  by the system annotation/WhisperSync queues. Each stage is reported
  separately in redacted diagnostics.
- Terminal KFX endpoints are normalized through Kindle's native position
  factory. This prevents persisted highlights from expanding to location 1.

## [0.3.2] - 2026-08-16

### Changed

- Use the GitHub identity `soloipd` in the MIT license attribution.

## [0.3.1] - 2026-08-16

### Fixed

- Native highlight and note reconciliation now uses Kindle ReaderSDK's
  high-level create/update/delete methods. These methods also write through the
  KSDK annotation proxy; the lower-level methods used in 0.3.0 only changed an
  in-memory annotation cache and could report success without a durable native
  annotation.
- Annotation sync now closes and reopens the native book and verifies every
  desired create, edit, and deletion before reporting success or asking
  Amazon's annotation service to enqueue a cloud sync.
- Diagnostics distinguish a verified durable native write from an unverified
  or failed attempt, preventing cache-only false-positive results.

## [0.3.0] - 2026-08-15

### Added

- Live percentage checkpoints shortly after opening a book, periodically while
  reading, on suspend/resume, on close, and through the existing manual action.
- A configurable 2, 5, 10, or 15 minute periodic-sync interval (5 minutes by
  default).
- An opt-in, 128 KiB rotating diagnostics log containing only redacted sync
  metadata and native success/failure fields.
- An in-device **Show sync diagnostics** view comparing the live percentage,
  last accepted percentage, and latest native service result.
- Exact, text-free KFX-to-EPUB position mapping and batched normalized-XPointer
  translation for converted Kindle books.
- Native highlight create/delete and private note create/edit/delete
  reconciliation on open, annotation changes, suspend, close, and manual sync.
- Annotation diagnostics containing counts and sanitized native result fields;
  note and highlight text is never logged or retained in plugin state.
- Lua behavior tests for live-progress precedence and active-hook settings.

### Fixed

- Automatic sync now reads `ReaderPaging`/`ReaderRolling` live progress instead
  of a stale `percent_finished` sidecar value while a document is open.
- The global close hook now resolves the active ReaderUI plugin instance, so
  automatic hooks honor settings changed from the reader menu.
- Already accepted percentages are suppressed before a Java-agent attachment.
- Interval-menu changes now invalidate the previous timer, apply immediately,
  and emit an explicit redacted diagnostics event.
- Native annotation ranges are matched independent of endpoint direction, and
  notes reuse the persisted highlight's native endpoint order. This prevents a
  duplicate-highlight rejection when firmware reverses a saved range.

## [0.2.0] - 2026-08-15

### Added

- Native Goodreads rating updates through `com.lab126.grokservice` and its
  authenticated `rateABook` hash property.
- A one-time 1–5 star chooser after book completion, with no inferred rating.
- Manual actions to rate the current or last completed ASIN-backed book.
- Rating removal through the native zero-rating operation.
- Persistent prompt suppression and local display of the last submitted
  rating per ASIN.

## [0.1.3] - 2026-08-15

### Fixed

- The Goodreads submenu now declares KOReader's `more_tools` sorting hint, so
  it reliably appears under **Tools → More tools** instead of as an orphaned
  `NEW:` item in the first menu tab.

## [0.1.2] - 2026-08-15

### Fixed

- Agent-manifest validation now accepts both LF and JAR-specification CRLF line
  endings, so clean JDK builds validate consistently across environments.
- Archive checks now print the exact missing invariant when they fail.

## [0.1.1] - 2026-08-15

### Fixed

- CI no longer fails on ShellCheck informational false positives for trap-only
  cleanup code and literal JVM inner-class filenames.
- GitHub workflows use current Node.js 24-compatible action releases.

## [0.1.0] - 2026-08-15

### Added

- Automatic Goodreads `Currently Reading` and `Read` shelf updates through the
  Kindle's native KAF action.
- Silent whole-number reading-percentage updates through the native Grok
  `PostShareProgressRequest` service.
- Successful-percentage persistence and duplicate suppression per ASIN.
- Independent KOReader menu toggles for shelf and percentage synchronization.
- Input validation, serialized agent attachment, and sanitized result logging.
- Reproducible JDK build, package checks, CI, and release archive tooling.
