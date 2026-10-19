# 0017 — The Writing window stays on top of every window

## Context
The Writing window (0016) was a normal window: clicking into cmux or any other app hid it behind that app, and you had to press ⌃⌥Space again to get the draft back. The user wants it always in front, like a sticky note over the terminal.

## Decision
- The window floats above normal windows (`NSWindow.Level.floating`), even when another app is active.
- It shows on every desktop (Space) and over full-screen apps (`canJoinAllSpaces`, `fullScreenAuxiliary`), since terminals are often full screen.
- It does not hide when the app is deactivated (`hidesOnDeactivate = false`).
- Esc, Copy and Paste back still close it; ⌃⌥Space still toggles it. Clicking another app only moves the keyboard there.

## Why
A floating level is the standard macOS way (like Notes' "Float on top"). A higher level (status bar, screen saver) would cover menus and system alerts.

## Consequences
- While open, the window can cover part of the app beneath it; the user moves or closes it. Its position is remembered.
- The checker follows it only while it has the keyboard (unchanged from 0016).

## Supersedes
Nothing; adds to 0016.
