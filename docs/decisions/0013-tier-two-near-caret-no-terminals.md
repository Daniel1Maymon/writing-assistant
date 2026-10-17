# 0013 — Tier 2 only checks sentences near the caret, and never in terminals

- **Date:** 2026-10-17
- **Status:** accepted (M5 revisits terminals)
- **Supersedes:** part of 0010 (every ready sentence in the field was sent)

## Context

Two days after M4, tier 2 had made 1,000 requests in one day and hit the daily cap, so the user's own sentences in TextEdit got no model answer ("does it works?" stayed unmarked; Harper doesn't catch it). Almost all focus time was in cmux, where the "text field" is the whole terminal. Its output (Claude Code streaming) keeps adding finished sentences away from the caret, and 0010's ready rule sent every one. Of 2,423 requests, 1,257 were cancelled because the text changed again. Cost was small ($0.014), but the cap blocked real use. The same rule would also send every sentence of a long document as soon as it's opened.

## Decision

1. When the field reports a caret, tier 2 sends only the caret's sentence and up to 2 sentences on each side (Core: `TierTwoScheduler.nearCaret`). With no caret, nothing is sent: after the first fix, Chrome pages being read (focus on `AXWebArea`, no caret) still made 45 requests in a minute.
2. In terminal apps (cmux, Terminal, iTerm2, Ghostty, Warp), tier 2 is off. Tier 1 (Harper, local and free) still runs there.

## Why

- The sentences being written are the ones near the caret. Others get checked when the caret goes near them.
- Terminal output isn't the user's writing. How to handle the terminal prompt line is an M5 question.

## Consequences

- A long document isn't fully checked by the model unless you move through it. Tier 1 still checks all of it.
- Today's wasted requests were reset by hand once (ledger cleared) so the fix could be checked the same day.
