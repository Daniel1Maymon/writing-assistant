# 0016 — A writing window (⌃⌥Space) for terminals and other apps the checker can't follow

- **Date:** 2026-10-19
- **Status:** accepted
- **Supersedes:** nothing (an M5 item; terminals stay unchecked per 0014)

## Context

The user writes long prompts in cmux (Claude Code). A terminal shows one block of text with the prompt mixed into the output, and the app doesn't check terminals at all (0014). Checking the prompt line directly would mean guessing where it starts and fixing words by sending key presses.

## Decision

1. ⌃⌥Space opens a small "Writing window" from anywhere. You write there with full checking (both tiers, card, ⌥⏎, mistake log), then:
   - **Paste back** (⌘⏎): the window closes, the app that was in front comes back and the text is pasted at its cursor. The clipboard is restored afterwards.
   - **Copy**: the text goes on the clipboard and stays there.
   - **Esc**: the window closes and the draft is kept.
2. The window is part of the main app, not a separate process. The checker follows it like any other app's text field, through Accessibility on its own process. A test showed that reading, bounds and setting the selection work on our own process, but change notifications are not delivered, so the window forwards its own "text changed", "selection changed" and "moved" events to the focus tracker. It forwards them on the next run-loop turn, never synchronously: accepting a fix sets the selection through AX, the text view reports the change from inside that AX call, and an AX read on our own process from there deadlocks (seen in the first build: the app froze on the first accepted fix).
3. Clicks inside the window are seen with a local mouse monitor; the global monitor doesn't see clicks in our own windows.
4. The shortcut is caught by the existing key tap, as ⌥⏎ is. No new permission.

## Why

- One mechanism that works everywhere (terminals, chat apps, web forms where underlines don't show), with no per-terminal rules.
- In-process keeps one permission grant (pasting needs Accessibility, which only the main app has).

## Consequences

- The mistake log records fixes made there with the app name "Writing window".
- Claude Code's Ctrl+G (edit the prompt in an external editor) could open this window directly. That's a possible next step.
- The shortcut isn't configurable yet.
