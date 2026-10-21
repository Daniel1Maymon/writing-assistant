# 0020 — In a terminal, Paste back replaces the prompt line

- **Date:** 2026-10-21
- **Status:** accepted
- **Supersedes:** part of 0016, point 1 ("the text is pasted at its cursor"), for terminals only

## Context

The usual way to use the Writing window from a terminal: you've typed a prompt, you copy it into the window, fix it there and press ⌘⏎. Paste back pasted at the cursor, so the prompt ended up holding the old text followed by the fixed one (seen in tmux).

## Decision

1. When the app Paste back goes to is a terminal (the same list that's never checked, decisions 0013 and 0014), it first sends ⌃E (end of line) and ⌃U (delete the line), then ⌘V.
2. Other apps are unchanged: the text is pasted at the cursor.

## Why

- ⌃E ⌃U is the same in bash, zsh and Claude Code's input, and tmux passes it through. No need to know which shell or program is running.
- The app can't read where a terminal prompt starts (one block of screen text), so clearing it with keys is the only general way.
- If the line was empty, the two keys do nothing.

## Consequences

- With a prompt longer than one line (Claude Code, Shift+⏎), only the line the cursor is on is cleared.
- Text that was on the line and wasn't copied into the window is lost from the line. In bash and zsh ⌃Y brings it back.
- A tmux prefix set to ⌃E or ⌃U would catch the key instead.
