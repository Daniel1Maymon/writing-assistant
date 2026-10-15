# Writing Assistant — Build & Test Plan (macOS app)

Companion to `DESIGN.md`. Each milestone lists what to build, how to test it, and the exit check. Don't start a milestone until the previous exit check passes.

## Repo layout

```
writing-assistant/
  DESIGN.md
  PLAN.md
  CLAUDE.md                 # standing rules for every session
  docs/decisions/           # append-only decision log (ADRs)
  .env                      # your OpenRouter key (git-ignored)
  .env.example
  .gitignore
  WritingAssistant.xcodeproj
  App/                      # SwiftUI menu-bar app, settings, overlay windows
  Core/                     # Swift package: pure logic (no AppKit)
    Sources/Core/           # env parser, segmenter, hasher, diff, merge, cache, relocate, mistake log, LLM client
    Tests/CoreTests/        # Swift Testing
  AXKit/                    # (part of the app target) focus tracking, value/caret/bounds reading
  Fixtures/FixtureApp/      # tiny app with NSTextView, NSTextField, NSSecureTextField + a command socket (decision 0006)
  scripts/m2-check.py       # integration harness: drives FixtureApp, reads the debug socket
  eval/                     # golden.jsonl + score.py (Python, calls Core via CLI)
  tools/wa-cli/             # command-line target: `wa-cli check "sentence"` for eval/debug
```

## Test strategy

- **Unit (Swift Testing, `swift test`):** all of `Core` is pure Swift — no AppKit, no network. Target ≥90% coverage. Swift Testing (`import Testing`) runs with or without full Xcode; XCUITest still needs Xcode.
- **LLM client:** `URLProtocol` stub returns canned OpenRouter responses; one opt-in live test (`LIVE_OPENROUTER=1`) reads `.env`.
- **AX integration:** `scripts/m2-check.py` drives `FixtureApp` over `/tmp/wa-fixture.sock` and reads the installed app's state (suggestions, rects, counters) from `/tmp/wa-debug.sock`. Not XCUITest: that needs an admin password for UI automation (decision 0006).
- **Manual matrix (any writing platform):** native — TextEdit, Notes, Mail, Messages, Pages; web in any browser — Gmail, LinkedIn, X, a plain form; Electron — Slack, Notion, VS Code; hotkey layer — Google Docs, Terminal.
- **Quality eval:** `eval/golden.jsonl` — ~100 sentences with known errors + ~50 clean ones. `python eval/score.py --model <id>` reports recall, false-positive rate, p95 latency and cost per tier.
- **CI:** GitHub Actions macOS runner: `swift test` + `xcodebuild test` (UI tests can't get Accessibility permission on CI → run locally only).

## M0 — Shell (½ day)

Prerequisite: full Xcode installed, with its license accepted. Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` instead of `sudo xcode-select`. Builds are signed with the local self-signed certificate "WritingAssistant Local Signing", a stable identity that stops macOS from forgetting the Accessibility permission after every rebuild. Build + sign + install + launch: `scripts/install.sh` (add `--probe` to run the probe at launch). Decisions: [0001](docs/decisions/0001-build-with-xcode.md), [0003](docs/decisions/0003-self-signed-signing.md).

Build: Xcode project, menu-bar app (`MenuBarExtra`, `LSUIElement = YES`), no sandbox, Accessibility permission check with "Open System Settings" button (`AXIsProcessTrustedWithOptions`), launch at login, `.env` loader for debug builds. The `.env` parser lives in `Core` so it's testable with `swift test`; it was built first, before Xcode was installed.
Test: unit test for `.env` parser (comments, quotes, empty values, missing file); manual: fresh install prompts for permission, icon appears in menu bar; **re-probe tier 1 inside the real app** (debug menu item "Probe spell checker" runs the sentences from DESIGN.md → Open decision and logs counts). If grammar is still empty → record it and decide on Harper before M2.
Exit: app installs in `/Applications`, shows in menu bar, permission granted, permission survives one rebuild, tier-1 probe result recorded.

M0 test list (written before the app code, 2026-10-15). All checked against the installed `/Applications/WritingAssistant.app`, built by `scripts/install.sh`:

| # | Check | How | Why not automated |
| --- | --- | --- | --- |
| 1 | `.env` parser | unit tests, `swift test --package-path Core` | — |
| 2 | App runs with no Dock icon and one menu-bar icon | look at the menu bar (screenshot) | verified manually only: on macOS 27 the menu bar is drawn by a system process, so the window list doesn't show per-app icons, and screen capture needs Screen Recording permission |
| 3 | Fresh install, no permission → system Accessibility prompt appears on launch | reset with `tccutil reset Accessibility <bundle id>`, launch, look for the system prompt window | verified manually only: system UI |
| 4 | Menu shows "Accessibility: not granted" plus "Open System Settings…", and the button opens Privacy & Security → Accessibility | click in the menu | verified manually only: system UI |
| 5 | After the user grants it, the menu shows "granted" without a relaunch | menu | needs the user's toggle |
| 6 | Permission still granted after one rebuild + reinstall | `install.sh` again, relaunch, menu still says "granted" | needs a real signature |
| 7 | Launch at login is registered on first run and can be toggled off/on | menu toggle; `SMAppService.mainApp.status` shown in the menu | system service |
| 8 | Debug build loads `.env`: menu shows the number of keys loaded, never values | menu | verified manually only |
| 9 | "Probe spell checker" runs inside the app and writes counts to `~/Library/Application Support/WritingAssistant/probe.json` (fixed probe sentences only, no user text) | menu item, or launch with `--probe` | needs a real `.app` process; result goes into DESIGN.md → Open decision |

**M0 result (2026-10-15): exit check passed** (test 4 is still open; see below). All checks were run against the installed Xcode build in `/Applications`.
- 1: 13/13 unit tests pass.
- 2, 5, 7, 8: the user's screenshot shows the pencil icon in the menu bar, "Accessibility: granted", "Launch at Login" ticked and ".env: 5 keys loaded". The app log shows the login item is enabled.
- 3: the macOS prompt window (`universalAccessAuthWarn`) appeared after the first launch. After `tccutil reset` and a relaunch, the user granted access again. I didn't see the prompt myself.
- 4: **not yet checked.** The "Open System Settings…" button only shows while access is not granted, and nobody has clicked it yet. Recheck with `tccutil reset Accessibility com.danielmaymon.WritingAssistant` at the start of M2.
- 6: rebuilt with a new build number. The code signature hash changed, and the log still says "Accessibility trusted at launch: true".
- 9: the probe ran from the app; the result is in DESIGN.md → Open decision.

## M1 — Core logic (1–2 days)

Build in `Core`:
- `segment(text) → [Sentence(range, text, hash)]` via `NLTokenizer`.
- `diff(prev, next) → (dirty, kept)` by hash.
- `relocate(edit, in: sentence) → NSRange?`.
- `merge(local, llm, ignore) → [Suggestion]` (local wins on overlap).
- LRU cache keyed by `sentenceHash + ignoreVersion`.
- `MistakeLog` store (SQLite via the system `SQLite3` module): `record(entry)`, `recent(limit, category?)`, `mostRepeated(limit)`, `exportCSV()`, `deleteAll()`.

Unit tests (must include):
- MistakeLog: record → read back identical fields (incl. Hebrew + emoji sentence); `mostRepeated` groups "Teh→The" and "teh→the" together; CSV escapes commas, quotes and newlines; `deleteAll` empties it; a missing folder is created; an unwritable path throws without crashing.
- "Dr. Smith arrived." is one sentence; "e.g. this" not split.
- Editing one of three sentences marks only that one dirty.
- Same text twice → cache hit.
- `relocate`: substring missing → nil; repeated substring → nearest to hint.
- Merge drops overlapping LLM edit, keeps others, honours ignore list + dictionary.
- Emoji and Hebrew don't break offsets (UTF-16 throughout, matching AX).

Detailed M1 test list (written before the code, 2026-10-15). All are unit tests in `Core/Tests/CoreTests`:

| Area | Test |
| --- | --- |
| segment | "Dr. Smith arrived. He sat down." → 2 sentences, the first is "Dr. Smith arrived." |
| segment | "Use a tool, e.g. this one. Then stop." → 2 sentences ("e.g." doesn't split) |
| segment | Ranges exclude trailing spaces/newlines; whitespace-only chunks (blank lines) are skipped; `(text as NSString).substring(with: range) == sentence.text` |
| segment | Hebrew + emoji text: ranges are UTF-16 and round-trip through `NSString` |
| segment | Text without final punctuation → one sentence; empty text → none |
| hash | Same text → same hash; one changed letter → different hash; the hash ignores the sentence's position |
| diff | Edit one of three sentences → exactly that one is dirty, the other two are kept |
| diff | Same text again → nothing dirty; a sentence moved to another position stays kept |
| relocate | Substring missing → nil; empty substring → nil |
| relocate | Repeated substring → the occurrence nearest to the hint; no hint → the first |
| relocate | Works after emoji/Hebrew (UTF-16 offsets) |
| llm edits → suggestions | An edit whose `original` isn't in the sentence is dropped; two edits on the same repeated word get two different occurrences |
| merge | An LLM suggestion overlapping a local one is dropped; a non-overlapping one is kept; the result is sorted by position |
| merge | Ignored rule ids, dismissed suggestion ids and dictionary words (case-insensitive, spelling only) are removed |
| suggestion id | Same sentence hash + range + replacement → same id; a different replacement → a different id |
| cache | Same sentence text twice → cache hit; a different ignore version → miss; over capacity → the least recently used entry is evicted |
| MistakeLog | record → read back identical fields, including a Hebrew + emoji sentence |
| MistakeLog | `recent(limit:category:)` is newest first and filters by category |
| MistakeLog | `mostRepeated` groups "Teh→The" and "teh→the" into one row with count 2 |
| MistakeLog | CSV: header row; commas, quotes and newlines escaped (RFC 4180) |
| MistakeLog | `deleteAll` empties it; a missing folder is created; an unwritable path throws (no crash) |

Exit: `swift test` green, coverage ≥90%.

**M1 result (2026-10-15): exit check passed.** 43/43 tests pass (13 `.env` + 30 new). Line coverage is 95.8% (regions 91.3%), measured with `swift test --enable-code-coverage` + `llvm-cov report`. The uncovered lines are SQLite error branches. `NLTokenizer` handles "Dr.", "e.g.", "p.m.", Hebrew and emoji without custom rules.

## M2 — Read text + local checks + underlines (3 days)

Build: AX focus tracking (AXObserver on the frontmost app: focus, value and selection changes), read value + caret, skip secure fields. Tier 1 = Harper over LSP (decision 0005), only on changed sentences, 400 ms after typing stops; `NSSpellChecker` spelling if Harper can't start. Overlay `NSPanel` (click-through for now) draws squiggles from `kAXBoundsForRangeParameterizedAttribute`. Debug socket + `FixtureApp` + `scripts/m2-check.py` (decision 0006).

Unit tests (`swift test`, Core):

| Area | Test |
| --- | --- |
| LSP framing | Encode adds the right `Content-Length` (bytes, not characters, with Hebrew/emoji); the decoder handles a message split across reads, two messages in one read, and a header without a body yet |
| Harper mapping | LSP line/character → UTF-16 offset for single line, multiple lines, `\r\n`, emoji before the span |
| Harper mapping | Diagnostic + quickfixes → `Suggestion`: `SpellCheck` → spelling, other rules → grammar; replacements deduped, at most 3; ruleId `harper.<code>`; out-of-range diagnostic dropped |
| Document state | First text → every sentence dirty; edit sentence 2 → only sentence 2 dirty, sentence 1 suggestions keep the same ids |
| Document state | Sentence-relative ranges → absolute ranges; still right after text is inserted before the sentence; a deleted sentence's suggestions disappear |

Integration (`scripts/m2-check.py`, installed debug app + FixtureApp):

| # | Scenario | Pass |
| --- | --- | --- |
| 1 | Type "I recieve the mail. I has a apple." in the text view | Within 1 s: suggestions for "recieve" (spelling), "has" and "a" (grammar), each with a non-empty rect inside the window |
| 2 | Then change sentence 2 only | Sentence-1 suggestion ids unchanged; only 1 sentence re-checked (counter) |
| 3 | Type into the secure field | Zero checks (counter unchanged), no suggestions |
| 4 | Move the window 120 pt | Rects move by 120 pt within 100 ms |
| 5 | 2,000-word document, change one word | Re-check time (read → suggestions ready, not counting the 400 ms wait) < 100 ms |
| 6 | Kill the `harper-ls` helper | Next check restarts it and still returns suggestions |

Manual (real apps, installed app): underlines sit under the right words in TextEdit, Notes and Mail, and follow scrolling. Verified manually only, because alignment is visual and screenshots are blocked on this machine.

Exit: unit tests green, `m2-check.py` all pass, manual check done.

**M2 result (2026-10-15): exit passed for TextEdit; Notes and Mail still to check.**
- Unit: 59/59 (`swift test`).
- `m2-check.py`: 6/6, three runs in a row. Underlines in 0.04–0.24 s; rects follow a window move in 5 ms; 2,000-word one-word edit re-checked in 43 ms; a killed `harper-ls` restarts.
- Manual, real app: TextEdit through the installed app. The debug socket listed itt, has, a, dont, teh with replacements, and the user's screenshot shows the squiggles exactly under those words.
- Not yet: Notes and Mail. A `mailto:` draft focuses the To field, and only a click puts focus in the body, which can't be done from the shell.
- Bug found by the harness, fixed: apps re-announce focus on the same field, which wiped its results. Now a refocus of the same field keeps them.

## M3 — Suggestion card, accept, dismiss (2 days)

Build: click on underline → popover; accept via AX set-selected-text, fallback paste (restore pasteboard after); ⌥⏎ shortcut; dismiss / ignore rule / add to dictionary (persisted in `~/Library/Application Support/WritingAssistant`).
Tests:
- XCUITest: accept → field text equals expected; Cmd+Z in the host app restores original.
- Accept a whole-sentence replacement (needed by M4 rewrites, decision 0007) → field text equals expected, caret ends after the sentence.
- Pasteboard contents identical before and after a paste-fallback accept.
- Dismissed item stays gone after more typing; dictionary word never flagged again.
- Mistake log: accept → exactly one new row with the sentence **before** the fix, original, replacement, category, app bundle id; dismiss / ignore rule / add to dictionary → no row; log turned off in Settings → no row; log file made unwritable → fix still applied, no crash.
Exit: green; manual accept works in TextEdit, Notes, Mail, Messages, and each manual accept shows up in `mistakes.sqlite`.

## M4 — OpenRouter tier 2 (2 days)

Build: `OpenRouterClient` (URLSession, async/await), reads `OPENROUTER_API_KEY`, `OPENROUTER_MODEL`, `OPENROUTER_FALLBACK_MODEL` from `.env` (debug) or Keychain (release); JSON-schema response format; models fallback list; `provider.sort = latency`; cancellation on sentence change; daily cap; cost tracking from `usage` in responses; Settings field to paste the key into Keychain.
Tests (stubbed):
- Valid JSON → edits; malformed JSON / HTTP 5xx → no edits, no crash, falls back next time.
- Edit with `original` not in sentence → dropped.
- Sentence without terminal punctuation while caret inside → no request; add "." and move caret → exactly one request.
- Change sentence mid-request → request cancelled, stale result never shown.
- Cap reached → no more requests that day; menu shows warning.
- Request body never logged (capture `os_log` in test).
- Rewrite (decision 0007): `rewrite` with kind `fix` → one sentence-wide suggestion (red); kind `natural` → one sentence-wide suggestion (blue); `null` → none; a rewrite equal to the sentence → dropped; malformed `rewrite` → edits still used.
- Accepting a rewrite replaces the whole sentence, removes that sentence's word-level suggestions, and logs exactly one mistake-log row (`grammar` for fix, `clarity` for natural).
Manual (real app): type "Is it work?" in TextEdit → a red dashed line under the whole sentence; card offers "Does it work?"; accept → the sentence is replaced. Type a correct but stiff sentence → blue dashed line with a more natural version.
Live test (`LIVE_OPENROUTER=1 swift test --filter Live`): 5 sample sentences return sensible edits.
Eval: run `score.py` (including: on clean, natural sentences `rewrite` is `null` ≥ 90% of the time, decision 0007) for Haiku 5.5, GPT-6 Luna, DeepSeek V4 Flash → pick the main model.
Exit: green + eval done.

## M5 — Wider app support + polish (3 days)

Build: `AXManualAccessibility` / `AXEnhancedUserInterface` for Electron/Chromium; badge-only mode when bounds unavailable; global hotkey "check selection" for Google Docs; per-app exclusions; on/off switch for "natural wording" rewrites; cost display; app icon; release build reading key from Keychain only; "My mistakes…" window (list, filter by category, most-repeated view, Export CSV) + Settings toggle and "Delete all".
Tests: full manual matrix above — every app gets layer 1, 2 or 3 and none gets nothing; excluded app → zero checks and zero mistake-log rows; accepting a fix via the hotkey popover and accepting a sentence rewrite both log a row; the exported CSV opens cleanly in Numbers.
Exit: one week of daily use; every false positive / miss logged into `eval/golden.jsonl`.

## Go / no-go for cancelling Grammarly

Targets (from `score.py` + a week of use): error recall ≥ 80%, false positives ≤ 5% on clean sentences, p95 local ≤ 100 ms, p95 tier 2 ≤ 2 s, cost ≤ $3/month, works in your top 5 apps.
