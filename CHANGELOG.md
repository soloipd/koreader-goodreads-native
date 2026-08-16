# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

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
