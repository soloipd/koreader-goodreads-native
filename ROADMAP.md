# Product roadmap

This roadmap aims to make a jailbroken Kindle feel like one reading system even
when a book is alternated between KOReader, Kindle's native reader, Amazon's
cloud, Goodreads, and optional knowledge services. Reliability, reversibility,
and private-by-default behavior are release gates rather than later polish.

## Product principles

1. Never report a sync as successful without a durable readback or a native
   queue acknowledgement.
2. Preserve the newest user intent with per-book snapshots and deletion
   tombstones; never merge by blindly taking the largest percentage.
3. Keep book, highlight, and note text out of diagnostics.
4. Make experimental firmware-specific behavior opt-in, reversible, and easy
   to disable over SSH.
5. Prefer low-power event-driven work over polling.

## Now: reliability foundation

### P0 — Crash-safe annotation outbox

- Persist every coalesced annotation snapshot before starting translation or
  Java attachment.
- Use atomic replace, per-ASIN sequence numbers, checksums, and acknowledged
  deletion of delivered snapshots.
- Resume after KOReader exit, framework restart, sleep, or reboot.
- Add deterministic tests for rapid create/edit/delete sequences and process
  termination at every handoff stage.

Success: no lost final state across 1,000 fault-injected transitions.

### P0 — Reading-position source of truth

- Define separate values for live KOReader position, persisted KOReader
  position, native Kindle position, shelf badge, Goodreads percentage, and last
  acknowledged cloud value.
- Add explicit conflict rules using timestamps, session identity, and user
  direction instead of highest-percentage-wins.
- Refresh the KOReader bookshelf badge from the same committed position used
  when opening the book.
- Detect and repair stale 38%-badge/52%-open mismatches.

Success: shelf badge and opened page agree after every normal close, crash,
reader switch, and reboot test.

### P0 — Single-instance and lifecycle guard

- Add an idempotent launch lock and PID identity validation.
- Detect a stale shell-integration launcher and recover without starting a
  second KOReader.
- Restore power-management state in all exit paths.
- Provide an SSH-safe `doctor` command that never launches a reader.

Success: repeated launch requests cannot produce two independent reader trees.

### P1 — Sync receipts and health dashboard

- Show four states per book: saved locally, waiting for native reader, queued
  to Amazon, and cloud-observed where verification is available.
- Display counts, timestamps, retry reason, agent generation, and firmware
  capability profile without annotation text.
- Add “retry now,” “discard pending,” and “export redacted support bundle.”

## Next: seamless bidirectional reading

### P1 — Background native-journal experiment

- Determine whether an exact `JournaledBook` can be constructed from content
  catalog metadata while the native reader is inactive.
- Submit a canary in an isolated test book only after dry-run capability checks
  pass.
- Require native journal acknowledgement, WhisperSync enqueue acknowledgement,
  and later native/cloud observation before treating the path as supported.
- Maintain a firmware capability allowlist and an immediate kill switch.

The experiment and stop conditions are documented in
`experiments/background-annotation-sync/README.md`.

### P1 — Native-to-KOReader annotation import

- Read native highlights, notes, colors, and deletion tombstones.
- Translate KFX coordinates back to normalized EPUB XPointers.
- Track origin IDs so an imported annotation is not exported back as a new
  duplicate.
- Offer conflict policies: newest edit, KOReader wins, Kindle wins, or ask.
- Preserve Kindle visibility metadata without making private notes public.

### P1 — True two-way reading position

- Import the native position before KOReader opens a converted book.
- Export KOReader position with a confirmed native readback.
- Treat rewinds as intentional when they occur in the current session.
- Track rereads independently from first-read completion.

### P2 — Zero-friction handoff

- “Continue in Kindle” and “Continue in KOReader” actions that resolve the exact
  mapped copy and verify the destination page before dismissing the source.
- Optional automatic handoff when leaving a book, with a visible cancellation
  window and no hidden reader launches.
- Remove duplicate library entries by presenting one logical book with two
  available engines.

## Then: annotation and knowledge workflows

### P1 — Readwise integration

- Incremental export with stable annotation IDs, edit/delete propagation, and
  explicit account-token storage permissions.
- Retry with exponential backoff and a per-book export receipt.
- Preserve source URL, book identity, location, color, note, and reread date.

### P2 — Open export hub

- First-class Markdown/JSON export plus adapters for Obsidian, Joplin, Calibre,
  Zotero, and a local WebDAV endpoint.
- User-defined templates and folders without running arbitrary templates as
  shell code.
- Append-only event export for personal automation.

### P2 — Better annotations

- Highlight colors and tags shared between engines where representable.
- Nested notes, bookmark synchronization, and “highlight plus surrounding
  paragraph” export with an explicit privacy toggle.
- Undo-aware deletion grace period and a trash/recovery view.
- Merge adjacent highlights only when the user requests it.

### P3 — On-device review

- Daily highlight review, spaced repetition, vocabulary cards, and random
  resurfacing from the current book or collection.
- Reading-session summaries generated locally when possible, with opt-in remote
  providers and a preview before any text leaves the device.
- Cross-book concept links and “where have I seen this idea before?” search.

## Goodreads and social reading

### P1 — Complete lifecycle metadata

- Start/finish dates, rereads, shelves, rating changes, and explicit DNF state.
- Distinguish 99% from completed; never infer a rating.
- Confirm native service acceptance and expose retryable errors.

### P2 — Reading goals and insights

- Local reading streaks, time-per-book, pace, projected finish date, and annual
  goal progress.
- Private-by-default session history with CSV/JSON export.
- Optional Goodreads shelf suggestions based on local tags—not uploaded text.

Goodreads should remain responsible for shelves, percentage, dates, and
ratings. Highlight text belongs to Kindle/Amazon Notebook or an explicitly
connected export service.

## Kindle-native enhancements

### P2 — Unified library card

- One logical card per ASIN showing native/KOReader availability, conversion
  status, DRM extraction health, position-map version, sync status, and last
  opened engine.
- Repair or regenerate stale converted copies without losing KOReader sidecars.

### P2 — Device operations

- Battery-aware Wi-Fi windows for queued sync.
- Scheduled backups of sidecars, mappings, plugin settings, and annotation
  outbox with restore preview.
- Firmware compatibility scanner and warning before upgrades.
- Automatic log rotation and storage-budget enforcement.

### P3 — Delightful experiments

- A book-aware lock-screen card with current title, progress, and next reading
  goal, with a privacy-off switch.
- Page-turn remote, reading timer, focus sessions, and ambient progress display.
- Personal “reading map” connecting authors, places, concepts, and saved notes.
- Local semantic search over opted-in highlights using a compact on-device
  index; remote embeddings only with explicit consent.

## Engineering program

### Compatibility matrix

Record Kindle model, firmware, Java runtime, KSDK/WhisperStore flags, journal
lane, converter version, and verified features. Unknown profiles default to
safe queue-only behavior.

### Test layers

1. Pure Lua state-machine and conflict tests.
2. Java agent tests with fake ReaderSDK, journal, and cloud services.
3. Shell fault injection at every file/lock/process boundary.
4. Golden position-map fixtures covering Unicode, images, footnotes, RTL, and
   terminal ranges.
5. On-device canary-book UAT with create/edit/delete/reboot/sleep matrices.
6. Long-running soak tests measuring battery, memory, queue convergence, and
   duplicate suppression.

### Release gates

- No production write path without rollback and a kill switch.
- No success state without local verification and native queue evidence.
- No book or annotation text in ordinary logs or support bundles.
- CI, package integrity, clean-install, upgrade, and downgrade tests pass.
- Experimental features remain disabled by default until two firmware profiles
  complete the UAT matrix.

## Suggested sequence

1. Crash-safe outbox, single-instance guard, and shelf-position consistency.
2. Sync receipts and automated canary-book UAT.
3. Read-only background-journal capability probe.
4. Isolated canary write, then an opt-in firmware allowlist if verified.
5. Native-to-KOReader import and loop-free bidirectional reconciliation.
6. Readwise/export hub, richer Goodreads lifecycle, and unified library UX.
7. Review, insights, semantic search, and other delight features.
