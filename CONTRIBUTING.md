# Contributing

Contributions are welcome, especially compatibility reports from other Kindle
firmware versions.

## Development setup

Requirements:

- Bash, ZIP, and a JDK with `javac` and `jar`;
- Lua 5.1 or LuaJIT for syntax checks;
- ShellCheck for shell linting.

Run:

```sh
make build
make check
make stress
make package
```

`make stress` is a mandatory CI and release gate. It exercises 1,000 native
handoffs, 50 simultaneous watcher contenders, 1,000 inherited KOReader helper
processes, and 1,000 periodic progress checkpoints. A release is not published
if any handoff is duplicated, the wrong process is selected, a periodic shelf
action leaks through, or the singleton watcher guarantee fails.

The release plugin is generated in `goodreads.koplugin/`; install that entire
directory on a test Kindle. Never test with account credentials embedded in
source or command-line arguments—the implementation must continue to use only
the Kindle framework's existing authenticated service.

## Compatibility changes

Amazon's classes and methods are obfuscated and may change between firmware
versions. A compatibility pull request should include:

- Kindle firmware and KOReader versions;
- the failed stage from `/tmp/goodreads-progress-result.log`;
- sanitized HTTP status or exception class;
- updated reverse-engineering notes and tests.

Do not attach Amazon cookies, access tokens, device serial numbers, account
identifiers, or unredacted framework logs.

## Java agent changes

The Kindle JVM may cache a loaded agent class and JAR path for the life of the
framework process. When behavior changes materially, increment the class suffix
(`GoodreadsProgressAgentV2` to `V3`), the JAR filename, the helper path, and
`Agent-Class` in the manifest.
