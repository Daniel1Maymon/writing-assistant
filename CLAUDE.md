# Writing Assistant — standing rules

A personal Grammarly replacement for macOS, plus a local log of accepted fixes for learning. Read `DESIGN.md` (what and why) and `PLAN.md` (milestones, tests, exit checks) before changing anything.

## Rules for every change

1. **Test plan first.** For every feature, behaviour change or bug fix: update `PLAN.md` (the test list of the relevant milestone) **before** writing code, then implement, then add/update the automated test. If something can only be checked by hand (for example AX behaviour in a real app, or LLM output quality), write it in `PLAN.md` as "verified manually only" with the reason. That still counts as an entry, not an exemption.
2. **Decisions are written when they're made.** Non-obvious choices go in `docs/decisions/NNNN-title.md` (Context / Decision / Why / Consequences / Supersedes). The log is append-only: to change a decision, add a new file that names what it supersedes, and don't rewrite the old one.
3. **Milestones are gated.** Don't start a milestone until the previous milestone's exit check in `PLAN.md` passes.
4. **Real path beats green tests.** Something is "working" only after it's been seen working in a real app (TextEdit/Mail/…) through the installed `.app`. When reporting, say which path verified it: unit test, XCUITest on FixtureApp, or manual in a real app.

## Project facts

- `Core/` is a SwiftPM package with no AppKit and no network. Run its tests with `swift test --package-path Core`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- Text offsets are UTF-16 (`NSRange`) everywhere, to match Accessibility and `NSString`.
- `.env` holds the OpenRouter key. It's git-ignored and only read by debug builds. Never print or log its contents.
- Diagnostic logs never contain user text. The mistake log (`mistakes.sqlite`) is the one deliberate, user-controllable exception.
