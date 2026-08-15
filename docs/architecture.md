# Architecture

The plugin uses two independent native Kindle paths because Goodreads shelf
state and reading percentage are not handled by the same service.

```mermaid
flowchart LR
    A["KOReader closes an ASIN-backed book"] --> B["Read percent_finished and completion state"]
    B --> C["KAF LIPC shelf action"]
    C --> D["Currently Reading or Read"]
    B --> E["Delayed sync-progress helper"]
    E --> F["AttachLauncher via jdk.attach"]
    F --> G["GoodreadsProgressAgentV2 in Kindle framework"]
    G --> H["Authenticated GrokService"]
    H --> I["Goodreads whole-number percentage"]
    I --> J["Persist last successful percent per ASIN"]
```

## KOReader hook

`goodreads.koplugin/main.lua` wraps `ReaderUI.onClose`. It captures the document
path and progress before the original close handler runs, then queues:

- the shelf action after one second;
- the percentage helper after three seconds.

Shell-level delays survive a complete KOReader exit and allow other close hooks
to finish writing the Kindle content database first.

## Shelf synchronization

The shelf path invokes `lipc-hash-prop` on the Kindle publisher
`com.lab126.kppkaf`, property `kppAddToGoodreadShelf`. Inputs are selected from
fixed actions and a strict ASIN allowlist.

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

## Upgrade behavior

The JVM may retain a previously loaded agent class and JAR path. Release agents
therefore use both a versioned class name and a versioned JAR filename.
Increment both whenever changing agent behavior that must take effect without
rebooting the Kindle framework.
