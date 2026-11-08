# AI recap v2 acceptance — 2026-11-08

- Deployed to Kindle and passed 52 ARM LuaJIT checks: 30 policy, 17 lifecycle, 5 summary-pipeline tests.
- Observed a genuine AI-written recap of the current book on the framebuffer: 220,973 source bytes processed in three chunks, then synthesized into 253 words.
- Saved cache version is 2; its anchor equals the saved reading position. Normal restart reopened the cached recap successfully, with automatic recap enabled.
- Final deployment disables draft streaming. Only completed, validated prose is displayed.
- Input stops at the current KOReader XPointer. No whole-book lookup or web search is used. Old cache versions, mismatched books, changed source and rewound positions are rejected.
- Source IDs are checked against bounded source passages. This establishes source provenance, not semantic proof of every paraphrase; AI factual mistakes remain possible.
- Initial quotation-based evidence validation rejected paraphrased quotations. Numbered source references replaced that approach; there is no unchecked fallback.
- Full uncached generation took approximately 80 seconds in the observed run. Cached reopening does not require another model request.

This records tested behavior, not a guarantee against all device or model failures. These results concern the AI-prose implementation, not the earlier excerpt-only prototype.
