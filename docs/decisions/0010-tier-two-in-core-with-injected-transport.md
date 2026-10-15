# 0010 — Tier-2 logic lives in Core; the app only supplies the network call

- **Date:** 2026-10-15
- **Status:** accepted
- **Supersedes:** —

## Context

M4 adds the OpenRouter call. CLAUDE.md says `Core/` has no network. Most of M4 (when to ask, what to send, how to read the answer, cancelling, the daily cap, cost, merging) still needs fast unit tests.

## Decision

- `Core` holds everything except the HTTP call: the prompt and JSON schema, the request body, the response parser, rewrite suggestions, the 0008 merge, the "is this sentence ready" rule, the daily ledger, and a `TierTwoScheduler` that starts, caches and cancels requests.
- The scheduler gets a `send: (Data) async throws -> Data` function. The app passes one that uses `URLSession`; tests pass stubs.
- **Ready rule:** a sentence that ends in `.?!` is ready unless the caret is strictly inside it. The caret right after the final `.` counts as outside, so typing the period is enough. A sentence with no final punctuation is ready only when the caret is elsewhere.
- **Failures:** no suggestions are stored, so the sentence is tried again on a later check, at most twice. The next request after a failure lists the fallback model first.
- **Cache:** answers are kept in memory by sentence hash (LRU, 500). Retyping a sentence costs nothing.
- **Rewrites get a rule id** (`llm.rewrite.fix`, `llm.rewrite.natural`), so "Ignore rule" on a natural rewrite turns those off. That's the on/off switch decision 0007 asked for, until Settings exists.
- **Logs:** the scheduler logs only through a function it's given, and only counts and outcomes. A test captures every line and checks the sentence never appears.

## Why

- Network-free Core stays true, and the parts that can go wrong are tested without a real call.
- The prompt is in one place. `eval/score.py` reads it from the Swift source, so the eval tests the same prompt the app sends.

## Consequences

- The app file `OpenRouterTransport.swift` is thin and is only checked live and in the real app.
- A sentence-wide mark is drawn under the bounding box of the sentence. For a sentence that wraps onto two lines, the line is drawn under the bottom line only (good enough for now; revisit in M5).
