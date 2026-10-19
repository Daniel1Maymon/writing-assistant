# 0018 — Slack and other Electron apps: turn on full accessibility, measure words on the text pieces

- **Date:** 2026-10-19
- **Status:** accepted
- **Supersedes:** nothing (builds the `AXManualAccessibility` item planned in M5)

## Context

In Slack (Electron) the app read and checked the text but drew no underlines. A probe with the same AX calls showed why:

- `AXBoundsForRange` on the message box (`AXTextArea`) returns `(0, 1080, 0, 0)` for every range: an empty rect at the bottom of the screen.
- Text markers (`AXBoundsForTextMarkerRange`) return the whole box for any range.
- The `AXStaticText` inside the box also returned an empty rect, until `AXManualAccessibility` was set on the app and the text changed once. After that, it returned real rects for character ranges (e.g. "I r" → 13×19 at the start of the box).

Chromium only builds the per-character layout ("inline text boxes") in full accessibility mode, which Electron turns on when an assistive app sets `AXManualAccessibility`. `AXEnhancedUserInterface` was refused by Slack (error -25208) and is known to slow window animations, so it isn't used.

## Decision

1. When the focus tracker attaches to an app, it sets `AXManualAccessibility = true` on the app element. Apps that don't know the attribute return an error, which is ignored.
2. `AXElement.bounds(for:)`: if the field's own rect is missing or has no height, it finds the `AXStaticText` pieces inside the field, locates each piece's text in the field's value (in order), and asks the piece(s) that cover the range for their rect. Several pieces → the union.

## Why

- It's the attribute Electron provides for assistive apps; no private API, no app-specific code.
- The fallback only runs when the field's own answer is unusable, so TextEdit, Mail, Chrome and Safari keep the path they already pass on.

## Consequences

- Electron apps run with full accessibility while we watch them; this costs them some CPU, as with any screen reader.
- The first underline in an Electron app may appear only after the next edit (the layout is built after the mode is turned on).
- The tree walk is capped (200 elements) so a huge document can't stall a redraw; past the cap, words are not underlined.
