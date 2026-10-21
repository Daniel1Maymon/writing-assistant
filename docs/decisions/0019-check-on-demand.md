# 0019 — Check on demand: ⌃⌥G or a button next to the selection

- **Date:** 2026-10-21
- **Status:** accepted
- **Supersedes:** nothing (builds the "check selection" hotkey planned in M5, with a different shape)

## Context

Tier 2 only looks at finished sentences near the caret, shortly after a key press, and stops at the daily cap (decisions 0010, 0013, 0014). The user wants to point at a piece of text and ask "is this right, and how else could I say it?", at any time.

## Decision

1. Two ways in: the global shortcut **⌃⌥G**, and a small button that appears just after the last selected character while text is selected in a checked field.
2. The text checked is the selection; with no selection (shortcut only), the sentence the caret is in.
3. A separate request with its own prompt and schema: `{"corrected": string, "alternatives": [string], "reason": string}`. Up to 3 alternatives, same meaning and tone. The sentence before and after go along as context, as in tier 2.
4. A separate card opens under the selection: "Checking…", then the corrected text (if it differs) and the alternatives. Click one, or ⌥⏎ for the first, to replace the selection. Esc closes it.
5. On-demand checks ignore the "finished sentence", "near the caret", "recent input" rules and the daily cap. They still count as a request and their cost goes into today's total.
6. Every choice accepted from the card is saved in the mistake log: the correction as `grammar` (rule `llm.manual.correction`), an alternative as `clarity` (rule `llm.manual.alternative`), like a "more natural" rewrite (decision 0007).
7. The button is a borderless non-activating panel, like the card, so clicking it doesn't take the focus or the selection from the app. It's placed with `AXBoundsForRange` on the last selected character; where that fails (WhatsApp, VS Code today) there's no button, but ⌃⌥G still works and the card opens at the mouse.

## Why

- The user asked for something explicit, so the automatic rules (which exist to save requests) and the cap shouldn't block it; one request per key press or click can't run away.
- A separate prompt keeps the tier-2 prompt and its eval (`eval/score.py`) unchanged.
- ⌃⌥G: next to ⌃⌥Space (Writing window), and G for grammar. Not taken by macOS or the common apps tested.

## Consequences

- One more AX call (the selection) every 100 ms in the redraw timer, and one more (the last character's rect) only while text is selected.
- Esc and ⌥⏎ are swallowed only while this card is open.
- Apps without per-character rects get the shortcut but not the button.
