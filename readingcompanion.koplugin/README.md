# Quiet reading companion

A small companion to KOReader and KOAssistant v0.24.1. It does not replace or modify Goodreads/Kindle synchronization, annotations, or book files.

## Reading screen

The Quiet top bar shows the Kindle's local time, a tappable **Recap** shortcut with the current TOC heading, and battery percentage. `↯` means charging. The heading is clipped to fit, not converted to a guessed chapter number. The native header reserves space; the plugin paints only within that area. Normal KOReader header refresh scheduling is reused. No separate battery polling or screen-refresh loop is installed.

Tap the centre of the header, or use **Tools → Quiet reading companion → Show spoiler-safe recap**. Choose **Continue reading** to dismiss it. Automatic recap on book open can be toggled in the same submenu. First-page books are skipped. Reopening is distinct from a brief screen wake; the latter does not trigger another recap.

## AI recap and spoiler boundary

### What happens when you tap Recap

1. Capture the book's current KOReader text position (XPointer), not its percentage or the native Kindle percentage.
2. Extract only the text before that boundary, without turning pages or moving your position.
3. Reuse a matching local recap, or ask your configured KOAssistant model to summarize that bounded text. Longer inputs are processed sequentially, then combined into one coherent recap.
4. Validate the returned structure and supporting source references, and recheck that you are still at the same book and position.
5. Show the finished AI-written prose. Draft responses and intermediate chunk summaries are never streamed onto the screen. Choose **Continue reading** to return to the book.

An uncached recap requires an internet connection and may take a minute or more: one observed three-chunk run took approximately 80 seconds. Reopening at the exact same position uses the cache without another AI request. The 150–220-word length is a prompt target, not a strict output limit.

### Input cutoff and validation

Version 2 produces an **AI-written summary in its own words**, aiming for 150–220 words. It extracts the complete text from the beginning to the current EPUB XPointer, excluding the unread remainder of the current page. Extraction does not navigate the book. Text over 100,000 bytes is processed in chronological chunks, then synthesized into one recap. No earlier chapters are silently dropped. Above a 2,000,000-byte safety limit, generation fails closed rather than substituting a partial recap.

The model must attach supporting source IDs to every summary paragraph. IDs resolve to numbered passages from the bounded source and are kept out of the displayed recap. Unknown IDs, references outside the source, or malformed results cause the run to fail, not a partial summary to appear. During synthesis, references resolve to original source passages, not merely earlier generated notes. Prompts forbid external knowledge, predictions, unread events, and using contents lists or future-chapter previews as narrative. No title, author, external full-book summary, later highlights, web results, or book-search tools are supplied. **Reference validation proves that cited passages occur in the source, not that every AI paraphrase is logically correct.** Hallucinations cannot be categorically ruled out. The cutoff also cannot distinguish text the reader skipped earlier.

A local cache is reused only when the book path, exact position, extracted source, and policy version all match. A later-position cache is never displayed after rewinding. Late responses are discarded after closing, switching books, moving position, or timeout. Missing text and page-based documents fail closed. Offline use requires an exact matching cache.

Source preparation normalizes presentation-only characters such as EPUB soft hyphens, typographic quotation marks, and ligatures. References are exact lookups, not fuzzy semantic matches. A malformed or unsupported model response gets at most one correction attempt using the same bounded source; a second failure displays no recap. Partial chunks are never shown as the final summary.

## Privacy and reliability

Generation sends the bounded read-so-far text through the provider/model already configured in KOAssistant. Long prefixes require one request per chunk plus a synthesis request; normal provider charges and data handling apply. No API keys are duplicated. The source and final AI recap are cached in the book's KOReader metadata; the companion does not log either. Exact-position cache hits make no API calls. Version-1 excerpt caches are invalidated. Generation uses KOAssistant's asynchronous transport with one request at a time, checks the active position between chunks, and applies a 120-second watchdog per request. It does not keep Wi-Fi or the Kindle awake.

The header supports flowing books in page mode. PDF and scroll-mode header support are not implemented. No changes are made to existing KOAssistant actions: its ordinary Recap remains a separate feature with different source-selection rules.

## Install and rollback

Copy this directory to `koreader/plugins/readingcompanion.koplugin` and restart KOReader normally. KOAssistant must be enabled. The tested deployment also enables the native header clock, battery percentage, and automatic header refresh, while hiding native title/author/page counters. Disable or remove this plugin and restore the backed-up header settings to revert.

## Tests

From the parent workspace:

```
luajit readingcompanion-tests/policy_spec.lua
luajit readingcompanion-tests/lifecycle_spec.lua
luajit readingcompanion-tests/summary_spec.lua
```

Tests cover full-prefix exclusive boundaries, paraphrased output, invalid evidence rejection, old-cache migration, lossless bounded chunking, sequential synthesis, failed-chunk cancellation, wrong-book and rewind caches, offline behavior, stale responses, timeout recovery, and header initialization ordering. These are bounded acceptance tests, not a guarantee against every model, firmware, or third-party-plugin interaction. See the [version-2 device acceptance record](../readingcompanion-tests/ACCEPTANCE-v2.md) for the 52 passing checks and observed live AI recap.
