# 0007 — Whole-sentence fixes and "more natural" rewrites, in M4

- **Date:** 2026-10-15
- **Status:** accepted
- **Supersedes:** DESIGN.md → "Sentence rewrite: Rewrite chip on wordy/unclear sentences" (planned for M5)

## Context

The user asked for more than word-level underlines:

1. Mark a **whole sentence** and suggest a fix when the problem isn't one word. Example: "Is it work?" → "Does it work?"; Harper misses it (decision 0005).
2. Suggest **better, more natural wording** for a sentence, even when nothing is strictly wrong.

DESIGN.md had a rewrite chip only for "wordy/unclear" sentences, built in M5. The LLM contract already has a `rewrite` field.

## Decision

The tier-2 model (M4) returns, per finished sentence:

- `edits`: span-level fixes, as before.
- `rewrite`: either `null` or `{text, kind, reason}`. `kind` is `fix` (the sentence is wrong as a whole) or `natural` (correct, but a native speaker would say it differently).

The app shows a rewrite as a sentence-wide mark: a thin dashed line under the whole sentence, red for `fix` and blue for `natural`. Clicking the mark opens the same suggestion card (M3), with the before → after sentence. Accepting a rewrite replaces the whole sentence and logs one mistake-log row (category `clarity` for natural, `grammar` for fix).

This is built in M4, not M5. The M3 card already supports a whole-sentence replacement.

## Why

- Only the model can judge whole-sentence grammar and naturalness. Harper works rule by rule.
- The contract and the call stay the same: one request per finished sentence. Cost doesn't grow.
- Showing the sentence-wide mark separately keeps word-level squiggles readable.

## Consequences

- When a sentence has both word fixes and a rewrite, both show up. Accepting the rewrite clears the word fixes for that sentence.
- "Natural" rewrites are a matter of taste, so the eval (M4) adds a check for this: on clean, natural sentences, the model should return `rewrite: null` ≥ 90% of the time. Otherwise it would nag on every sentence.
- Settings gets an on/off switch for "natural wording" suggestions (M5).
