# 0021 — Don't check read-only web pages

- **Date:** 2026-10-21
- **Status:** accepted
- **Supersedes:** nothing (narrows 0009, which reads every `AXWebArea` through text markers)

## Context

Reading a page in Chrome (the claude-mem viewer), the user got a word card for "claude" in the top-left corner of the screen. After a click on page text, Chrome puts the focus on the page itself: an `AXWebArea` with the whole page's text (22,221 characters) and a caret. The app treated it as a field, underlined the page's words, and since Chrome gives no per-word bounds there, every underline and card fell back to the page's frame.

Measured through the installed app (debug `axdump`, 2026-10-21):

| Focused element | Role | `AXValue` settable | `AXEditableAncestor` |
| --- | --- | --- | --- |
| Chrome, plain page text | `AXWebArea` | no | none |
| Chrome, `<textarea>` | `AXTextArea` | yes | the field |
| Chrome, `contenteditable` | `AXTextArea` | yes | the field |
| Mail compose body | `AXWebArea` | yes | none |

## Decision

An `AXWebArea` is checked only when its `AXValue` is settable. Other roles are unchanged.

## Why

- It's the one signal that separates Mail's body (an editor) from a page you only read. `AXEditableAncestor` doesn't: Mail's body has none.
- Web fields in Chrome are `AXTextArea` / `AXTextField`, so they're not affected.

## Consequences

- One extra AX call when the focus changes.
- A web app that makes its whole page an editor but reports `AXValue` as not settable would stop being checked. None seen so far; ⌃⌥G and the Writing window still work there.
