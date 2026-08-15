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
- Offers configurable 2, 5, 10, or 15 minute periodic checkpoints.
- Offers a one-time 1–5 star chooser when a book is completed.
- Supports manual rating updates and clearing an existing rating.
- Suppresses duplicate percentage updates per ASIN.
- Keeps shelf and percentage synchronization independently configurable.
- Provides opt-in, redacted, rotating diagnostics and an on-device status view.
- Uses only the Kindle's native authenticated services.
- Never displays the native Goodreads sharing dialog.

## Requirements

- A jailbroken Kindle with KOReader.
- Kindle firmware whose Amazon framework includes Java 21 and `jdk.attach`.
- The Amazon account on the Kindle already linked to Goodreads.
- `kindle.koplugin`; notes/highlights additionally require its
  position-map-enabled converter build.
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

For books converted by a position-map-enabled `kindle.koplugin`, KOReader
highlight and note ranges are translated from normalized EPUB XPointers to the
original KFX EID/offset coordinates. The plugin reconciles creates, note edits,
note removal, and annotation deletion on reader open, annotation changes,
suspend, close, and the manual sync action. The coordinate map contains no book
or annotation text. Rapid changes are serialized: the latest snapshot for each
book replaces stale queued work, transient failures retry up to three times,
and close-time snapshots can retry after the reader UI has unloaded the book.

Annotation text exists only in KOReader's own metadata, a mode-0600 transient
request under `/tmp`, and the native Kindle annotation store. Transient
requests are removed after each attempt. Logs and plugin dedupe state contain
counts and coordinates only.

Goodreads-linked Kindle notes and highlights remain private by default when
they travel through Amazon's native pipeline; sharing visibility should remain
an explicit user choice. This plugin never publishes annotation text.

See [Architecture](docs/architecture.md) and
[Kindle native-service notes](docs/reverse-engineering-notes.md) for details.

## Troubleshooting

Percentage synchronization is intentionally silent. Prefer **Show sync
diagnostics**. These lower-level files remain available over SSH:

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
- Annotation synchronization is from KOReader to the native Kindle store. It
  does not currently import native-only Kindle annotations into KOReader.
- Progress is sent from KOReader to Goodreads; this plugin does not download a
  Goodreads percentage into KOReader.
- Only ASIN-backed books are supported.
- Amazon may break compatibility in future firmware updates.
- This project is not affiliated with Amazon, Goodreads, or KOReader.

## License

[MIT](LICENSE)
