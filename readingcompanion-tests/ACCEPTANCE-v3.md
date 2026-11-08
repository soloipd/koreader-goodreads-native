# Chapter-aware recap acceptance — 2026-11-08

- Passed 73 checks locally and on Kindle ARM LuaJIT: 30 policy, 21 lifecycle/settings, 6 pipeline, 16 chapter/length checks.
- Covered exact chapter start, the first 499 words versus the 500-word boundary, mid-chapter exclusion, first chapter, missing TOC, nested-section reset, recent-text cap, all-read scope, length/scope cache invalidation, settings changes in flight, and bounded output retries.
- Inspected framebuffer screenshots before and after normal KOReader restart. Observed a real AI recap at the existing chapter-opening position, sourced from 38,698 bytes rather than the earlier 220,973-byte whole prefix.
- Read-only saved-cache verification confirmed policy version 3, `chapter:standard`, exactly two paragraphs, 148 words, and the same saved reading anchor. Normal restart reopened the cached recap.
- Initial live output did not satisfy the format limits and was withheld. Clarified that the JSON array must contain two objects and the word target applies across both, then reran successfully.
- Scope and length callbacks are tested with mocked settings; the live acceptance covers default chapter-aware/standard behavior, not every provider and configuration combination.
- Source provenance validation is not proof of semantic entailment. AI mistakes remain possible. TOC quality and language-dependent whitespace tokenization constrain chapter/transition behavior.

The on-device `check_cache.lua BOOK_PATH` helper is read-only and outputs counts and settings, not book text. Backups were retained before deployment. No Goodreads/native annotation changes were part of this work.
