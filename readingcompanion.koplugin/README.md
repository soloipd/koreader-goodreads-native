# Quiet reading companion

A small companion to KOReader and KOAssistant v0.24.1. It does not replace or modify Goodreads/Kindle synchronization, annotations, or book files.

## Reading screen

The Quiet top bar shows the Kindle's local time, a tappable **Recap** shortcut with the current TOC heading, and battery percentage. `↯` means charging. The heading is clipped to fit, not converted to a guessed chapter number. The native header reserves space; the plugin paints only within that area. Normal KOReader header refresh scheduling is reused. No separate battery polling or screen-refresh loop is installed.

Tap the centre of the header, or use **Tools → Quiet reading companion → Show spoiler-safe recap**. Choose **Continue reading** to dismiss it. Automatic recap on book open can be toggled in the same submenu. First-page books are skipped. Reopening is distinct from a brief screen wake; the latter does not trigger another recap.

## AI recap and spoiler boundary

### What happens when you tap Recap

1. Capture the book's current KOReader text position (XPointer), not its percentage or the native Kindle percentage.
2. Select the chapter-aware scope described below and extract only text before that boundary, without turning pages or moving your position.
3. Reuse a matching local recap, or ask your configured KOAssistant model to summarize that bounded text. Longer inputs are processed sequentially, then combined into one coherent recap.
4. Validate the returned structure and supporting source references, and recheck that you are still at the same book and position.
5. Show the finished AI-written prose. Draft responses and intermediate chunk summaries are never streamed onto the screen. Choose **Continue reading** to return to the book.

An uncached recap requires an internet connection and may take a minute or more for long scopes. Reopening at the exact same position with the same settings uses the cache without another AI request.

### Defaults and configuration

Open **Tools → Quiet reading companion → Recap scope / Recap length** (the Tools menu may group plugins under More tools).

- **Chapter-aware (default):** mid-chapter, summarize only the current chapter up to your position, emphasizing recent developments. At the exact chapter start, use the previous chapter. During the first 500 whitespace-delimited words of the new chapter, include the previous chapter and only the already-read opening of the new one. At 500 words, the previous chapter drops out.
- **Recent text:** use up to the last 2,500 whitespace-delimited words before your position.
- **Everything read so far:** explicitly opt into the earlier whole-prefix behavior.

All lengths use **exactly two paragraphs**. Standard, the default, targets **100–150 words**; Brief targets 60–90 and Detailed 180–250. Validation allows small variation (80–160, 40–100, and 150–270 respectively). Wrong paragraph counts or excessive length get one correction attempt, then no recap is displayed. Paragraph one restores the situation or argument; paragraph two covers recent developments without predicting what comes next.

Chapter boundaries come from EPUB TOC XPointers, not screen pages or guessed chapter numbers. The current TOC entry's depth defines the chapter/section level; in nested TOCs this can mean a subsection, with the preceding same-depth entry used for transition context. Missing usable headings fall back to the recent-text window. Words are whitespace-delimited, so the threshold is approximate and less suitable for languages without word spaces. Unread TOC titles are not supplied to the model; headings inside the selected read text may be included. Settings are global and changing scope or length invalidates the cached recap.

### Input cutoff and validation

Version 3 produces an **AI-written refresher in its own words**, scoped to the selected chapter-aware, recent-text, or whole-prefix mode. The current EPUB XPointer remains the exclusive upper boundary, excluding the unread remainder of the current page. Extraction does not navigate the book. Selected text over 100,000 bytes is processed in chronological chunks, then synthesized into one recap. Above a 2,000,000-byte extraction safety limit, generation fails closed; this also applies to the prefix extracted before trimming a recent-text fallback.

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
luajit readingcompanion-tests/chapter_spec.lua
```

Tests cover chapter boundaries and transitions, scope/length settings, exclusive cutoffs, output-length enforcement, paraphrased output, invalid evidence rejection, old-cache migration, lossless bounded chunking, sequential synthesis, failed-chunk cancellation, wrong-book and rewind caches, offline behavior, stale responses, timeout recovery, and header initialization ordering. These are bounded acceptance tests, not a guarantee against every model, firmware, or third-party-plugin interaction. See the [version-3 device acceptance record](../readingcompanion-tests/ACCEPTANCE-v3.md) for the 73 passing checks and observed live chapter recap. The version-2 record is historical.
