# 0014 — Tier 2 only after the user's own input; terminals not checked at all

- **Date:** 2026-10-18
- **Status:** accepted (M5 revisits terminals and read-only web pages)
- **Supersedes:** part 2 of 0013 (terminals: tier 1 still ran)

## Context

A day after 0013, the daily cap was hit again: 1,000 requests, 1,161 of 1,492 cancelled. Terminals sent nothing, but Chrome pages being read (a live dashboard on localhost) kept changing, and Chrome reports a caret inside some pages, so sentences "near the caret" kept changing and being sent. At the same time Harper underlined iTerm's log output (for example the extra spaces in `INFO:     Will`).

## Decision

1. Tier 2 starts a request only if the user pressed a key or clicked the mouse in the last 10 seconds. The existing ⌥⏎ key tap and global mouse monitor record the time; no new permission is needed.
2. In terminal apps (cmux, Terminal, iTerm2, Ghostty, Warp) the app doesn't check or draw anything.
3. The debug socket gets `type {text}`, which posts real key presses, so integration scripts go through the same path as a person typing.

## Why

- Text that changes without the user typing (logs, dashboards, chat streams) isn't being written by the user. A recent key press or click is a simple, reliable signal that needs no per-app rules.
- In terminals, underlines on output are pure noise. Checking the shell prompt line is an M5 question.

## Consequences

- If you finish a sentence and stop typing, the request still goes out: it's within 10 s of the "." key press.
- Opening a document and only reading it sends nothing to the model. Tier 1 still underlines it.
- Read-only web pages still get tier-1 underlines; that's M5 (Chrome support).
