# 0006 — AX integration tests: fixture harness instead of XCUITest

- **Date:** 2026-10-15
- **Status:** accepted
- **Supersedes:** PLAN.md → Test strategy → "AX integration: XCUITest launches FixtureApp, types text…"

## Context

PLAN.md planned XCUITest to type into `FixtureApp` and then read the app's state from a debug socket. On macOS, a UI-test runner needs UI-automation permission, and turning that on asks for an admin password (and asks again after resets). The user's standing rule is to find a route with no password where one exists. XCUITest also only drives the fixture: the thing being tested is still `WritingAssistant` watching another app through Accessibility.

## Decision

- `FixtureApp` is a tiny AppKit app with an `NSTextView`, an `NSTextField` and an `NSSecureTextField`. It takes commands on a local socket, `/tmp/wa-fixture.sock` (set text, type at a position, focus a field, move the window), and makes each change the way typing does (`insertText`), so the normal Accessibility notifications fire.
- The installed `WritingAssistant.app` (debug build) answers on `/tmp/wa-debug.sock` with JSON: the focused app, the suggestions, their screen rects and counters.
- `scripts/m2-check.py` (Python, standard library only) launches both apps, runs the scenarios and asserts. It is run by hand or by Claude, not in CI. CI can't grant Accessibility.

## Why

- No admin password, no UI-automation prompt.
- It tests the real path: the installed app reading another process over Accessibility, the same as TextEdit.
- The checks are plain JSON assertions, so the script is easy to read and extend.

## Consequences

- No real keystrokes. `insertText` takes the same text-system path as typing, but key-event handling isn't covered. The manual checks in TextEdit/Notes/Mail cover that.
- The debug socket exists only in Debug builds and never sends user text over anything but a local socket that the same user owns. Its JSON does contain the flagged words, but it isn't a log, so the "no user text in logs" rule still holds.
- `UITests/` from the repo layout is not created.
