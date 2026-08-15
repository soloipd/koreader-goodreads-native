# Goodreads Native Sync for KOReader on Kindle

An experimental KOReader plugin for jailbroken Kindles that silently syncs
Goodreads shelf state **and reading percentage** through the Kindle's existing
Amazon/Goodreads session.

No Goodreads API key, Goodreads password, Amazon cookie, or manually supplied
account token is required or stored.

> [!WARNING]
> This plugin dynamically attaches a Java agent to Amazon's Kindle framework.
> It is firmware-specific, intended only for devices you own, and should be
> installed only from source or releases you trust.

## Features

- Puts a book on `Currently Reading` after KOReader records progress.
- Marks a book `Read` when KOReader completes it or reaches 99%.
- Silently sends the rounded whole-number percentage to Goodreads on close.
- Suppresses duplicate percentage updates per ASIN.
- Keeps shelf and percentage synchronization independently configurable.
- Uses only the Kindle's native authenticated services.
- Never displays the native Goodreads sharing dialog.

## Requirements

- A jailbroken Kindle with KOReader.
- Kindle firmware whose Amazon framework includes Java 21 and `jdk.attach`.
- The Amazon account on the Kindle already linked to Goodreads.
- Amazon-sourced content whose KOReader path contains its ASIN.
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
4. Open **Main menu → Tools → Goodreads (native Kindle sync)**.
5. Leave **Automatic shelf sync** and **Silent percentage sync** enabled.

For an SSH installation from the repository checkout:

```sh
scp -P PORT -r goodreads.koplugin \
  root@KINDLE_IP:/mnt/us/koreader/plugins/
```

Restart KOReader after an install or upgrade. A full Kindle reboot is normally
unnecessary because the release agent uses a versioned class name.

## Supported books

The plugin intentionally accepts only ten-character Amazon ASINs beginning
with `B`. It discovers them from either:

- a `KINDLE_VIRTUAL://<ASIN>/...` path; or
- a filename ending in `_<ASIN>.<extension>`.

Local EPUBs without an Amazon ASIN are ignored because Goodreads book matching
would otherwise be ambiguous.

## What happens on book close

1. KOReader records the current `percent_finished` and completion state.
2. After one second, the plugin invokes the native KAF shelf action.
3. After three seconds, a helper attaches the release agent to the running
   Kindle framework.
4. The agent sends the same native `PostShareProgressRequest` used by Amazon's
   reader-sharing implementation.
5. HTTP 200 or 202 without a native error envelope counts as success.
6. The accepted integer percentage is saved under:

   ```text
   /mnt/us/koreader/settings/goodreads_native_progress/<ASIN>
   ```

The saved value contains no account information and exists only to prevent an
unchanged percentage from being sent repeatedly.

See [Architecture](docs/architecture.md) and
[Kindle native-service notes](docs/reverse-engineering-notes.md) for details.

## Troubleshooting

Percentage synchronization is intentionally silent. Inspect these files over
SSH when diagnosing it:

```text
/tmp/goodreads-progress-result.log
/tmp/goodreads-progress-attach.log
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
- Progress is sent from KOReader to Goodreads; this plugin does not download a
  Goodreads percentage into KOReader.
- Only ASIN-backed books are supported.
- Amazon may break compatibility in future firmware updates.
- This project is not affiliated with Amazon, Goodreads, or KOReader.

## License

[MIT](LICENSE)
