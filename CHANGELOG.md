# Changelog

All notable changes to this project are documented here. The project follows
[Semantic Versioning](https://semver.org/).

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
