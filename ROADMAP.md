# Product roadmap

The goal is one reliable reading system across KOReader, Kindle's native
reader, Amazon/Goodreads, and explicitly connected knowledge services.
Reliability, reversibility, privacy, and device testing are release gates.

Status labels describe `main`, not unreleased experiments:

- **Done** — implemented with deterministic tests.
- **Device gate** — implemented but awaiting the stated Kindle UAT.
- **Next** — prioritized for active development.
- **Later** — retained scope, not yet scheduled.
- **Rejected** — evidence showed that the approach does not satisfy the product
  contract; it remains documented so it is not accidentally repeated.

## Product invariants

1. Never report cloud success without independent readback; distinguish local
   save, native queue acceptance, and cloud observation.
2. Preserve newest user intent with snapshots, provenance, and tombstones.
3. Keep book, highlight, note, account, and device-identifying data out of
   ordinary diagnostics and support artifacts.
4. Keep firmware-specific experiments opt-in, reversible, and remotely
   disableable.
5. Prefer low-power events to polling and never leave KOReader alive behind the
   native reader on firmware where that causes a power-event loop.
6. Every release must pass deterministic behavior tests, fault injection,
   stress, package inspection, and proportionate on-device UAT.

## Reliability foundation

### Done — crash-safe annotation outbox

- Atomic, checksummed, sequence-numbered per-book snapshots.
- Latest-state coalescing and bounded retries across close, process exit, lock
  contention, and native-reader handoff.
- Explicit acknowledgement only after local verification and native queue
  evidence.
- Text-free durable receipts and redacted support summaries.

### Done — lifecycle and single-instance safety

- Singleton native watcher and exact main-reader PID identity checks.
- Graceful handoff only; no force-kill path.
- Periodic progress does not republish unchanged shelf actions.
- Release stress covers 1,000 handoffs, 50 watcher contenders, 1,000 helper
  decoys, and 1,000 progress checkpoints.

### Done — SSH-safe device doctor

- Read-only, fixed-schema health report that never launches either reader.
- Detect duplicate reader roots, missing Java/framework prerequisites, stale or
  duplicate agents, watcher state, and queue counts.
- Print counts and capability states only—never ASINs, paths, process arguments,
  credentials, annotation text, or device identifiers.
- Add privacy fixtures, fault injection, and a 1,003-process tree stress case.

### Done — Bookshelf completion and rating bridge

- Observe KOReader's successful long-press summary saves without modifying
  KOReader core files.
- Observe the separate in-reader **Book status** flush, while distinguishing a
  real star/status edit from KOReader's unchanged initial star rendering.
- Publish Finished ASIN-backed books as Read and activate the one-time chooser.
- Synchronize explicit star creation, edits, and clears with per-book
  serialization and unchanged-value dedupe. Completion shelf writes wait for
  the rating lane to drain, preventing two native Goodreads requests from
  racing; unfinished, non-ASIN, and free-form review data remains local.

### Next — reading-position source of truth (companion `kindle.koplugin`)

- Model live KOReader, persisted KOReader, native page, shelf badge, Goodreads
  percentage, and last acknowledged values separately.
- Resolve conflicts with session identity, timestamp, direction, and explicit
  user intent—not highest-percentage-wins.
- Make shelf badge and opened page agree after normal close, crash, handoff,
  rewind, and reboot.
- Track rereads separately from first completion.

## Seamless bidirectional reading

### Device gate — native-to-KOReader annotation reconciliation

- Repair stale converted-book source paths from the current Kindle catalog;
  accept only one readable, complete local row and fail closed on ambiguity.

- v0.7 imports native ranges through the position-map-enabled companion plugin.
- v0.8 adds component provenance, native note edits/removal, safe highlight
  deletion, local-edit protection, and coordinate-only deletion tombstones.
- v0.11.2 adds canonical outbound KFX identity receipts, endpoint-spelling echo
  suppression, safe native-owned duplicate collapse, and tombstones for deleted
  KOReader-owned exports.
- Destructive merge requires the v2 exporter's explicit complete-snapshot
  attestation; incomplete payloads are additive-only.
- Plugin-origin persistence events are guarded so native imports cannot echo
  themselves into a redundant outbound reconciliation.
- Remaining gate: real-device create/edit/delete/note/reboot/sleep round trip
  with an exact active local KFX book.

### Next — richer annotation fidelity

- Import and reconcile representable Kindle colors and visibility metadata.
- Stable cross-engine origin IDs where firmware exposes them.
- Configurable conflict policy: newest edit, KOReader wins, Kindle wins, or ask.
- Undo-aware deletion grace period and a local recovery view.
- Bookmarks and tags where both engines can represent them without loss.

### Next — true two-way reading position

- Import native position before opening the converted KOReader copy.
- Export KOReader position and require confirmed native readback.
- Preserve intentional rewinds and distinguish reread sessions.
- Repair stale bookshelf-badge/open-page mismatches automatically.

### Later — zero-friction engine handoff

- “Continue in Kindle” and “Continue in KOReader” actions resolving the exact
  mapped copy and verifying the destination page before dismissing the source.
- Optional handoff with a visible cancellation window and no hidden launches.
- One logical library card with native and KOReader engine choices.

### Rejected — detached background native journal

Firmware 5.19.5 exposed ReaderSDK, JournalingService, WhisperSyncV1, and legacy
journal factories while no native book was active. Detached create/delete calls
reported success, but the canary never appeared in the local native store after
opening the exact book. Production therefore retains queue-on-native-open. This
approach may be revisited only with a supported notification path plus verified
local and Amazon Notebook create/delete readback and a firmware allowlist.

## Annotation and knowledge workflows

### Next — Readwise integration

- Explicit token storage consent and revocation.
- Incremental export with stable IDs, edit/delete propagation, exponential
  backoff, and per-book receipts.
- Preserve source identity, location, color, note, and reread date.
- Never infer successful delivery without Readwise API readback.

### Later — open export hub

- First-class Markdown and JSON export.
- Adapters for Obsidian, Joplin, Calibre, Zotero, and local WebDAV.
- User templates without arbitrary shell execution.
- Append-only event export for personal automation.

### Later — on-device review

- Daily highlight review, spaced repetition, vocabulary cards, and resurfacing.
- Local-first summaries with explicit preview before remote text transfer.
- Cross-book links and opted-in local semantic search.

## Goodreads lifecycle

### Done

- Currently Reading/Read shelf transitions.
- Silent live percentage checkpoints with deduplication.
- Explicit 1–5-star rating and rating removal.
- Native queue acceptance diagnostics and retryable errors.
- Exact-readback native selection for Want to Read, Currently Reading, and
  Read.

### Done — private local reading lifecycle

- Checksummed local start/finish dates, rereads, explicit undoable DNF, and
  idempotent manual completion.
- Ninety-nine percent remains active; only explicit completion can mark Read
  or offer a rating.
- Local streaks, pace, projected finish, annual goals, and constrained CSV/JSON
  session-history export.
- v0.11 passed host behavior, privacy, package, fault-injection, 64-writer, and
  1,000-process release stress, followed by a graceful on-device upgrade,
  isolated ARM/BusyBox contention smoke test, framebuffer inspection, and a
  sustained single-reader/watcher health watch without a freeze or power-event
  regression.

Goodreads remains responsible for cloud shelves, progress, and ratings. The
tested native bridge exposes no DNF, lifecycle-date, or reread write surface,
so those facts remain local and are never reported as cloud-synced.
Highlight text belongs to Amazon Notebook or an explicitly connected export.

## Kindle-native operations

### Later — unified library card

- One card per ASIN with engine availability, conversion/DRM health,
  position-map generation, sync state, and last engine.
- Regenerate stale converted copies without losing KOReader sidecars.

### Later — device operations

- Battery-aware Wi-Fi windows for queued work.
- Scheduled sidecar/mapping/settings/outbox backups with restore preview.
- Firmware compatibility scanner and pre-upgrade warnings.
- Log rotation and enforceable storage budgets.

### Later — delightful experiments

- Privacy-controlled book-aware lock screen.
- Page-turn remote, focus timer, ambient progress, and reading map.
- Compact local semantic index over explicitly opted-in highlights.

## Engineering program

Every feature advances through these layers as applicable:

1. Pure Lua state-machine and conflict tests.
2. Java agent tests with fake native services.
3. Shell fault injection at file, lock, process, and handoff boundaries.
4. Golden position fixtures for Unicode, images, footnotes, RTL, and terminal
   ranges in the companion plugin.
5. On-device canary UAT across create/edit/delete/reboot/sleep.
6. Soak tests for battery, memory, queue convergence, and duplicate suppression.

Release gates require rollback, kill switches for experimental writes, no
private text in diagnostics, CI and package integrity, upgrade/downgrade tests,
and on-device validation proportional to the changed path. Experimental
features remain disabled by default until verified firmware profiles exist.
