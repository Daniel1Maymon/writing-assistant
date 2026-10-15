# 0005 — Tier 1 = Harper, run as a bundled `harper-ls` helper

- **Date:** 2026-10-15
- **Status:** accepted
- **Supersedes:** DESIGN.md → Open decision's default ("NSSpellChecker first, Harper only if the eval shows gaps")

## Context

The M0 in-app probe showed `NSSpellChecker` catches spelling but almost no grammar: it flagged "I has a apple." as one whole-sentence span, with no fix, and missed everything else. DESIGN.md planned Harper "via C FFI later", which would need a Rust toolchain and a hand-written C wrapper.

The same samples, run through Harper 2.12.0 (`brew install harper`) on 2026-10-15:

| Sample | NSSpellChecker | Harper |
| --- | --- | --- |
| I has a apple. | whole sentence, no fix | has → have, a → an |
| We was there / he go home | — | → were / → goes |
| This is is a test | — | repeated word |
| recieve, definately, hav, dont, itt, teh | 4 of 6 | 6 of 6 |
| "the car are", "Is it work?" | — | — |

## Decision

Tier 1 is Harper, via `harper-ls --stdio` (its language server), started once by the app and spoken to over stdin/stdout with the Language Server Protocol. The binary is copied from Homebrew into `WritingAssistant.app/Contents/Helpers/` at build time and signed with the app. If it can't start, tier 1 falls back to `NSSpellChecker` spelling.

## Why

- **Much better grammar,** with word-level ranges and ready-made replacements.
- **Fast:** about 5 ms per sentence after a ~0.4 s first check (measured over stdio).
- **Offsets match.** LSP positions default to UTF-16, the same as AX and `NSString`. Verified with an emoji + Hebrew sample.
- **No Rust toolchain, no FFI code.** The `harper-ls` binary links only macOS system libraries.
- **Local and offline,** so the privacy rule for tier 1 still holds.

## Consequences

- The app grows by about 55 MB.
- One extra process, kept alive and restarted if it dies.
- Harper's dialect defaults to American English.
- Updating Harper = `brew upgrade harper` + rebuild. The LSP format is stable, but the rule names (`code`) may change between versions.
- Harper still misses some grammar ("the car are"), which stays tier 2's job.
