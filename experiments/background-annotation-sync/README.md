# Background annotation sync experiment

## Question

Can this Kindle firmware durably journal and upload an annotation while
KOReader is active and the exact native book is not open?

The production agent deliberately answers “not proven” and waits for the native
book. Previous detached-handle tests accepted method calls but did not create a
visible native annotation or a confirmed upload.

## Safety model

The first-stage probe is read-only. It does not create, edit, delete, journal,
or upload annotations. It reports only allowlisted capability booleans and
counts; it never logs book paths, ASINs, highlight text, note text, credentials,
or arbitrary reflected values.

The write stage is intentionally not implemented yet. It must remain blocked
until all read-only gates pass and a dedicated disposable canary book is chosen.

## Read-only gates

The probe checks:

1. ReaderSDK and JournalingService are available in the framework JVM.
2. WhisperSyncV1 is available.
3. The legacy and KSDK annotation feature flags are readable.
4. JournalingService exposes a six-argument journal-book factory and an
   eleven-argument journal-entry factory.
5. ReaderSDK exposes an active-book method, allowing the experiment to prove
   it is running while no native book is active.

Passing these gates proves only that a background experiment is structurally
possible. It does not prove that Kindle will persist, display, or upload a
journal entry.

### Observed result on firmware 5.19.5

The read-only probe passed while KOReader was active and no native book was
open:

```text
instrumentation_present=true
reader_sdk_present=true
journaling_service_present=true
whispersync_service_present=true
journal_book_factory_present=true
journal_entry_factory_present=true
reader_active_book_method_present=true
native_book_active=false
ksdk_enabled=false
whisperstore_enabled=false
mutation_attempted=false
probe_ok=true
```

This supports advancing to an isolated legacy-journal canary. It does not
justify enabling background writes in the production plugin.

## Canary write design

The next stage should use a disposable test book and a synthetic one-character
highlight at a verified mapped position. It must:

- snapshot native and KOReader annotation state first;
- use a unique experiment ID in metadata;
- create exactly one journal entry without touching ReaderSDK's detached local
  annotation manager;
- request WhisperSync through the firmware's enabled lane;
- require queue acknowledgement;
- open the native book and verify exactly one visible canary;
- verify cloud appearance separately;
- delete the canary through the same path and verify disappearance;
- automatically restore the snapshots on any mismatch.

## Stop conditions

Stop immediately and keep production queue-only behavior if any of these occur:

- no exact content-catalog identity can be constructed;
- a journal call lacks a durable acknowledgement;
- a canary is uploaded but not visible locally, or vice versa;
- opening the native book duplicates or expands the canary range;
- deletion cannot be verified locally and in the cloud;
- the framework, reader, or power state becomes unstable;
- battery or CPU remains materially elevated after the probe.

## Build

```sh
JAVAC=/path/to/javac JAR=/path/to/jar ./experiments/background-annotation-sync/build.sh
```

The generated JAR is placed under `agent/build/experiments/` and is not included
in release packages.

## Device run

Copy the JAR and existing `AttachLauncher.class` to `/tmp`, then attach it to
the Kindle framework JVM. The agent writes
`/tmp/goodreads-background-capabilities.log`. The repository's runner performs
those steps and prints only the allowlisted report:

```sh
./experiments/background-annotation-sync/run-readonly-probe.sh KINDLE_IP PORT
```

The runner requires passwordless SSH for the short test window. It does not
restart applications or alter annotations.
