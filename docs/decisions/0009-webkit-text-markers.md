# 0009 — Read and edit WebKit fields through text markers

- **Date:** 2026-10-15
- **Status:** accepted

## Context

Mail's compose body is a WebKit editable web view. Its focused element is an `AXWebArea`. Checked on 2026-10-15 through the installed app (debug `axdump`):

- Its `AXValue` is empty.
- It has no `AXSelectedTextRange` or `AXSelectedText`.
- It does have WebKit's text-marker API: `AXTextMarkerRangeForUIElement`, `AXStringForTextMarkerRange`, `AXTextMarkerForIndex`, `AXIndexForTextMarker`, `AXBoundsForTextMarkerRange`, and a settable `AXSelectedTextMarkerRange`.

Without these the app sees no text in Mail and draws nothing, but DESIGN.md lists Mail as a layer-1 app.

## Decision

For an element whose role is `AXWebArea`, `AXElement` reads and writes text through text markers:

- **text:** the string for the element's whole marker range.
- **positions:** a UTF-16 index converts to a marker with `AXTextMarkerForIndex`, and back with `AXIndexForTextMarker`.
- **selection:** read and set through `AXSelectedTextMarkerRange`.
- **bounds:** `AXBoundsForTextMarkerRange`.
- **writing:** there is no `AXSelectedText`, so a fix selects the span through markers and then uses the existing paste fallback, which restores the pasteboard.

The rest of the app doesn't change: it still sees one string with UTF-16 offsets.

## Why

- It's the API WebKit itself provides for assistive apps, and it's the only way to read Mail's body.
- Keeping it inside `AXElement` means the checker, overlay, card and ⌥⏎ work unchanged.

## Consequences

- Fixes in WebKit fields always go through paste (⌘V). The pasteboard is put back afterwards.
- Markers are assumed to count characters the same way as the returned string. The real-app check in Mail verifies this, since a mismatch would put underlines under the wrong words.
- Safari pages with contenteditable areas use the same path. Chromium and Electron stay in M5.
