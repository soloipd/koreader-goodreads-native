# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

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
