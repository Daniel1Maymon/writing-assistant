# Real-Time Writing Assistant — Feature Design (macOS app)

Spec for a personal Grammarly replacement, built as a native macOS app. Main feature: as the user types in any app, each sentence is analysed and problems are underlined with one-click fixes. Side feature: every accepted fix is saved to a local mistake log for learning. Updated 2026-10-15.

## Goal and scope

- **Form factor:** a native macOS menu-bar app (Swift + SwiftUI/AppKit), installed in `/Applications`, launches at login, works system-wide like Grammarly Desktop.
- **Where it works:** any writing surface on the Mac — it is a standalone app, not tied to any browser or editor. Coverage comes in three layers, so nothing is left out:

  | Layer | How | Covers |
  | --- | --- | --- |
  | 1. Inline underlines | Accessibility API gives text + on-screen position | Native apps (Mail, Notes, Messages, Pages, TextEdit), websites in Safari/Chrome/Firefox/Arc (Gmail, LinkedIn, X, forms), Electron apps (Slack, Notion, Discord, VS Code) |
  | 2. Badge list | Text readable, but no on-screen position | Apps with partial accessibility support — issues listed in the badge popover, fix applied the same way |
  | 3. Check-selection hotkey | ⌃⌥G copies the selection, shows fixes in a popover, pastes the fix back | Everything else: Google Docs, canvas editors, Terminal, Java apps, remote desktops |
- **What it catches:** spelling, grammar, punctuation, clarity/conciseness rewrites.
- **Who it serves:** one user. No accounts, billing, App Store, or server.
- **AI provider:** OpenRouter (key in `.env` for development, Keychain at runtime).
- **Success bar:** fixes appear within ~1 s of finishing a sentence, false alarms are rare, AI costs ≈ $1–3/month.
- **Out of scope:** plagiarism, tone detection, AI generation, document editor, writing goals, scores, full-document review, iOS, quizzes/flashcards from the mistake log (the log stores the data; a learning UI beyond the list + CSV is a later idea).

## User-facing features

| Feature | What the user sees | Notes |
| --- | --- | --- |
| Inline underlines | Coloured squiggle under the problem span, in whatever app you're typing in | Red = correctness, blue = clarity/style. Drawn in a transparent click-through overlay window over the text; the app's text is never touched until you accept. |
| Suggestion card | Click an underline → small popover with explanation + 1–3 replacements | Before → after diff. |
| Accept | Click a replacement or press ⌥⏎ | Writes the fix into the field via Accessibility; falls back to select-range + paste. |
| Dismiss / ignore always | "Dismiss", "Ignore rule", "Add to dictionary" | Stored locally; also sent to the checkers. |
| Sentence rewrite | "Rewrite" chip on wordy/unclear sentences | One tighter version of the whole sentence. |
| Floating badge | Small circle at the field's corner with issue count | Click to pause for this app. |
| Menu-bar icon | On/off, per-app exclusions, dictionary, today's AI cost, My mistakes, Settings, Quit | Settings: API key (saved to Keychain), models, launch at login, mistake-log on/off + delete all. |
| Mistake log | Every fix you accept is saved, so you can review your own mistakes later | See [Mistake log](#mistake-log). Local only. |
| My mistakes window | List of past mistakes, newest first; filter by type; "most repeated" view; export to CSV | Built in M5. |

## Architecture

Everything runs in one Mac app process. There is no backend: the app calls OpenRouter directly over HTTPS.

```
[WritingAssistant.app — menu-bar app, runs locally]

 Any app's text field
        │  AXObserver: focus changed / value changed
        ▼
 AX Reader ──────────► Sentence engine ──────► Scheduler
 (focused element,      (NLTokenizer split,     (400 ms idle → tier 1,
  value, caret,          hash + diff)            sentence done → tier 2)
  bounds for range)                                │              │
        ▲                                          ▼              ▼
        │ accept fix                         Tier 1: local   Tier 2: OpenRouter
        │                                    NSSpellChecker  (Haiku 5.5, fallback
 Overlay window ◄──── Merge + cache ◄──────── (+ Harper opt.)  GPT-6 Luna), JSON edits
 (underlines, card,   (offsets, dedupe,
  badge)               ignore list)
```

Only changed sentences reach the checkers.

### Key macOS building blocks

| Need | API |
| --- | --- |
| Find the field being typed in | `AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute`; `AXObserver` on `kAXFocusedUIElementChangedNotification`, `kAXValueChangedNotification`, `kAXSelectedTextChangedNotification` |
| Read text and caret | `kAXValueAttribute`, `kAXSelectedTextRangeAttribute` |
| Where to draw the underline | `kAXBoundsForRangeParameterizedAttribute` (screen rect of a character range) |
| Draw on top of other apps | Borderless `NSPanel`, `.nonactivatingPanel`, level `.floating`, mouse passes through except on underlines/card |
| Apply a fix | Set `kAXSelectedTextRangeAttribute` to the span, then set `kAXSelectedTextAttribute` to the replacement; fallback: select span → pasteboard → synthesize ⌘V → restore pasteboard |
| Electron / Chrome web content | Set `AXManualAccessibility` (Electron) / `AXEnhancedUserInterface` (Chromium) on the app element so it exposes its text |
| Sentence splitting | `NLTokenizer(unit: .sentence)` (NaturalLanguage framework) |
| Tier 1 checks | `NSSpellChecker` with spelling + grammar — free, offline, built into macOS; optional Harper (Rust) via C FFI later |
| Secrets | `.env` in debug builds; Keychain in the installed app |
| Launch at login | `SMAppService.mainApp.register()` |

**Permission:** the app needs Accessibility access (System Settings → Privacy & Security → Accessibility). It must run outside the App Sandbox, so it's built locally (or signed + notarized) rather than shipped via the App Store.

## Analysis pipeline

1. **Capture.** AXObserver fires on value change in the focused element. Read full value + caret. Skip secure text fields and excluded apps.
2. **Segment.** `NLTokenizer` splits into sentences; hash each.
3. **Diff.** Unchanged hashes keep suggestions; changed ones are dirty and their old suggestions dropped.
4. **Debounce.** Tier 1 on dirty sentences after ~400 ms idle. Tier 2 only when a sentence looks finished (ends in `.?!` and caret left it) or after ~1.5 s idle.
5. **Tier 1 – local.** `NSSpellChecker` spelling + grammar. Deterministic, free, exact ranges.
6. **Tier 2 – OpenRouter.** Dirty sentence + one sentence of context either side. Asks for clarity, conciseness, and grammar the local checker misses. Structured JSON out.
7. **Merge.** Map to absolute offsets, drop LLM edits overlapping a tier-1 fix, drop ignored items, render.
8. **Cache.** Keyed by sentence hash (+ ignore-list version), in memory + small on-disk SQLite.

### LLM output contract

Never trust the model with character offsets. It quotes the exact original substring and the replacement; the app locates it in the sentence and discards edits it can't find.

```json
{"edits": [
  {"original": "in order to", "replacement": "to",
   "category": "concise", "reason": "Shorter, same meaning"}
],
 "rewrite": null}
```

### OpenRouter call

- `POST https://openrouter.ai/api/v1/chat/completions` (OpenAI-compatible) via `URLSession`.
- Body: `models: [OPENROUTER_MODEL, OPENROUTER_FALLBACK_MODEL]`, `provider: {sort: "latency"}`, `response_format: {type: "json_schema", ...}`, `max_tokens: 300`, temperature 0. For GPT-6 Luna use the lowest reasoning effort.
- Short fixed system prompt (cacheable).
- Cancel the in-flight request if its sentence changes again.

| Role | Model | Price / 1M tokens in / out |
| --- | --- | --- |
| Main | `anthropic/claude-haiku-5.5` | $0.10 / $0.50 |
| Fallback | `openai/gpt-6-luna` | $0.10 / $0.50 |
| Budget experiment | `deepseek/deepseek-v4-flash` | $0.09 / $0.18 |

During development, `.env` uses DeepSeek V4 Flash ([0004](docs/decisions/0004-dev-model-deepseek.md)). The M4 eval picks the final main model.

### Suggestion record

| Field | Type | Meaning |
| --- | --- | --- |
| id | String | Hash of sentence hash + span + replacement |
| sentenceHash | String | Ties suggestion to its sentence |
| range | NSRange | UTF-16 offsets within the sentence (matches AX + NSString) |
| category | enum | spelling · grammar · punctuation · clarity · concise |
| message | String | One-line explanation |
| replacements | [String] | 1–3 options, best first |
| source | enum | local · llm |
| ruleId | String? | For "ignore this rule" |

## Mistake log

A personal record of your mistakes, for learning. Decision: [0002](docs/decisions/0002-mistake-log.md).

- **What gets saved:** one row per fix you **accept** (a suggestion card replacement, ⌥⏎, or an accepted rewrite). Dismissed or ignored suggestions are not saved, because you said they weren't mistakes.
- **Where:** `~/Library/Application Support/WritingAssistant/mistakes.sqlite`. This is a separate file from the suggestion cache, so clearing the cache never deletes your history.
- **Never saved:** text from secure fields or excluded apps. Those are never checked in the first place, so nothing can be accepted there.
- **Failure rule:** if writing the row fails, the fix is still applied. Logging must never block or slow down an accept.
- **Undo:** if you press ⌘Z in the host app after accepting, the row stays. You did make the mistake.

| Column | Type | Meaning |
| --- | --- | --- |
| id | INTEGER | Primary key |
| createdAt | TEXT | ISO-8601 time of the accept |
| appBundleId | TEXT | e.g. `com.apple.mail` |
| appName | TEXT | e.g. "Mail" |
| sentence | TEXT | The full sentence **before** the fix |
| original | TEXT | The wrong part |
| replacement | TEXT | The fix you chose |
| category | TEXT | spelling · grammar · punctuation · clarity · concise |
| message | TEXT | The one-line explanation that was shown |
| ruleId | TEXT? | Checker rule, if any |
| source | TEXT | local · llm |

**Reviewing:** the menu-bar "My mistakes…" window lists the rows and shows a "most repeated" view, grouped by lower-cased `original → replacement`. It can also export everything to CSV.

## Latency, cost, privacy

- **Latency.** Tier 1 local and instant. Tier 2 ~0.5–2 s; underlines appear when ready, never block tier 1.
- **Cost.** ~$1/month at ~300 checked sentences/day (estimate). Set a credit limit on the OpenRouter key; the app also enforces `DAILY_REQUEST_CAP` and shows today's spend in the menu.
- **Privacy.** Never reads secure fields. Per-app exclusion list (default: Terminal, password managers, banking apps). Tier 1 never leaves the Mac; tier 2 sends only the sentence + neighbours. No text in diagnostic logs. The [mistake log](#mistake-log) is the one deliberate exception: a local file of accepted fixes that you can switch off or delete in Settings.
- **Key handling.** `.env` is git-ignored and only read by debug builds; release builds read the key from Keychain (entered once in Settings).

## Known hard cases

- **Google Docs / canvas-drawn editors:** text isn't exposed via AX → layer 3 (check-selection hotkey).
- **Apps with poor AX support** (some Electron, Java, terminals): bounds may be missing → layer 2 (badge list), or layer 3 if text isn't readable at all.
- **Scrolling / window moves:** re-query bounds on move/resize/scroll; hide overlay while moving.

## Open decision

Tier 1: built-in `NSSpellChecker` (zero setup) vs adding Harper (stronger grammar rules, needs Rust FFI). Default: NSSpellChecker first, Harper only if the eval shows gaps.

**Probe result (2026-10-15, macOS 27.0.1, from a `swift test` process, not an app):**
- **Spelling works but is lenient.** It flags "recieve" and "definately", but accepts "teh" and "hav" (it treats them as slang).
- **Grammar returned nothing.** "I has a apple." and "She dont know where teh car are." produced zero grammar results. Only "dont" was flagged, and as spelling.

If the M0 re-probe inside a real `.app` gives the same result, tier 1 is spelling-only. Grammar would then fall entirely to tier 2 or Harper, so the Harper decision moves up to M2 instead of waiting for the eval.

**M0 re-probe inside the real app (2026-10-15, macOS 27.0.1, installed Xcode debug build, "Probe spell checker" / `--probe`; raw output in `~/Library/Application Support/WritingAssistant/probe.json`):**

| Sample | Spelling flags | Grammar flags |
| --- | --- | --- |
| recieve | recieve | — |
| definately | definately | — |
| teh (alone) | — | — |
| hav | — | — |
| I has a apple. | — | **the whole sentence** (1 flag) |
| She dont know where teh car are. | dont, teh | — |

- **Grammar is not absent inside a real app, but it is weak.** It caught "I has a apple." (the `swift test` process got nothing), but missed "where … the car are". It marks the whole sentence, not the wrong word.
- **"teh" is caught in a sentence but not alone.** The checker uses its context.
- Checker language was `en_GB` with automatic language detection on. Forcing `"en"` in `checkGrammar(of:…)` returned nothing for any sample.

**Conclusion:** tier 1 = spelling plus a little grammar. It can't be the main grammar checker. Grammar falls mainly to tier 2 (LLM), and Harper should be evaluated at the start of M2 rather than waiting for the M4 eval. M2's first XCUITest stays the spelling example.
