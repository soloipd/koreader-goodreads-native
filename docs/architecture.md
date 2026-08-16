# Architecture

The plugin uses three native Kindle paths because Goodreads shelf state,
reading percentage, and ratings are not handled by one service.

```mermaid
flowchart LR
    A["KOReader opens, reads, suspends, resumes, or closes an ASIN-backed book"] --> B["Read live ReaderPaging or ReaderRolling percentage"]
    B --> C["KAF LIPC shelf action"]
    C --> D["Currently Reading or Read"]
    B --> E["Delayed sync-progress helper"]
    E --> F["AttachLauncher via jdk.attach"]
    F --> G["GoodreadsProgressAgentV2 in Kindle framework"]
    G --> H["Authenticated GrokService"]
    H --> I["Goodreads whole-number percentage"]
    I --> J["Persist last successful percent per ASIN"]
    B --> K["Completion detected"]
    K --> L["Explicit 1–5 star chooser"]
    L --> M["Grok rateABook LIPC property"]
    M --> N["Goodreads rating"]
```

## KOReader hook

`goodreads.koplugin/main.lua` uses normal ReaderUI events for periodic,
suspend/resume, and annotation telemetry. It also wraps `ReaderUI.onClose` so it
can capture the document path and live progress before the original close
handler unloads the document, then queues:

- the shelf action after one second;
- the percentage helper after three seconds;
- a one-time rating chooser after returning to the file browser when the book
  is complete.

The close hook resolves `reader.goodreads_native`, the active ReaderUI plugin
instance, rather than retaining the FileManager instance that installed the
global wrapper. This makes automatic behavior honor current menu settings.

Shell-level delays survive a complete KOReader exit and allow other close hooks
to finish writing the Kindle content database first. While a document is open,
`ReaderPaging:getLastPercent()` or `ReaderRolling:getLastPercent()` is the
authoritative source; persisted `percent_finished` is only a fallback.

## Shelf synchronization

The shelf path invokes `lipc-hash-prop` on the Kindle publisher
`com.lab126.kppkaf`, property `kppAddToGoodreadShelf`. Inputs are selected from
fixed actions and a strict ASIN allowlist.

## Rating synchronization

Ratings use `lipc-hash-prop` with publisher `com.lab126.grokservice` and
property `rateABook`. The payload contains a validated ASIN, a whole-number
rating from 0–5, `updateGoodreads = 1`, and a fixed origin. Rating 0 clears the
existing rating.

Completion only triggers the chooser. No rating is submitted until the reader
selects a value. Successful choices are stored in KOReader settings to suppress
repeat prompts; they can be changed or cleared manually at any time.

## Percentage synchronization

The percentage path cannot use that shelf property. `sync-progress` locates the
running Kindle framework JVM, serializes attachment with an atomic lock, and
loads a small Java agent through the JDK Attach API.

Inside the already-authenticated framework, the agent constructs a native
`PostShareProgressRequest`, sets the same headers as Amazon's reader-sharing
code, and invokes `GrokService.b(...)`. It logs only stage, HTTP status,
validity, and success—not the response body or session material.

HTTP 200 and 202 without a native error envelope count as success. Only then is
the integer written to
`/mnt/us/koreader/settings/goodreads_native_progress/<ASIN>`.

Before attachment, the plugin checks that state file and suppresses an already
accepted whole-number percentage.

## Diagnostics and annotations

The opt-in debug logger writes a strict allowlist of metadata fields to a
128 KiB rotating file. It does not accept arbitrary response or annotation
content. The on-device diagnostics view compares live reader progress, the
persisted success state, and the latest native agent result.

The KFX-to-EPUB converter preserves a text-free map of KFX PID, EID, EID
offset, length, and section metadata. Converted content elements carry their
EID and unambiguous base PID as `data-kfx-*` attributes. A batched helper walks
KOReader's normalized EPUB XPointer, counts Unicode characters from the nearest
KFX anchor, and emits the exact native short and long positions.

The annotation agent opens the explicit native KFX book, reconciles highlight
and note objects through `AnnotationManager`, notifies the KPP proxy, and
journals cloud edits through `com.lab126.whisperstore`. A direct KSDK dual-write
is conditional because some firmware does not export that controller method. A transient
mode-0600 payload carries note text. Ownership is transferred from KOReader's
root process to the framework JVM's dynamically resolved UID/GID, then the versioned agent removes it
immediately after loading, with bounded fallback cleanup by the helper; persistent plugin
state contains coordinate keys only. Diagnostics expose only counts and
sanitized success/failure stages. The agent closes and reopens the book before
reporting local verification. Before the agent write, the shell enables both
the legacy journal and KSDK shadow-mode lanes. After local, proxy, and
WhisperStore stages succeed, it invokes `KSDKAnnotationsEnqueueForSync` and
starts `com.lab126.whispersync`; a failed trigger is retryable and is not
reported as end-to-end success. The optional direct KSDK write is reported as
`unavailable` when its LIPC property is absent. Only one native annotation request runs at a
time. Rapid edits for the same ASIN coalesce to the newest immutable snapshot,
while snapshots for other books remain queued. Transient native failures retry
up to three times; a newer same-book snapshot cancels an older retry. Because
snapshots capture paths, coordinates, and notes before close, retrying does not
depend on ReaderUI still having the document open.

## Upgrade behavior

The JVM may retain a previously loaded agent class and JAR path. Release agents
therefore use both a versioned class name and a versioned JAR filename.
Increment both whenever changing agent behavior that must take effect without
rebooting the Kindle framework.
