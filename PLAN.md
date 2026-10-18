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

Build:
- **Open the card:** a global mouse monitor notices a click on an underline. The click still reaches the host app, and the overlay stays click-through. The card is a non-activating panel under the word: the message, before → after, 1–3 replacement buttons, Dismiss, Ignore rule, Add to dictionary (spelling only). It closes on a click elsewhere, on typing, or on a focus change.
- **Accept:** set the AX selection to the span, then set the selected text. If the field didn't change, fall back to paste: select the span, put the replacement on the pasteboard, send ⌘V, then put the old pasteboard back. Before writing, check that the text at the span still equals `original`; if not, do nothing.
- **⌥⏎** accepts the first replacement of the suggestion under the caret, or of the open card. An event tap swallows the key only in that case, so ⌥⏎ works normally everywhere else.
- **Persistence:** dismissed ids, ignored rules and dictionary words go to `~/Library/Application Support/WritingAssistant/ignore.json`.
- **Mistake log:** each accept writes one row. A menu toggle "Save accepted fixes" (default on) turns it off.

Unit tests (`swift test`, Core):

| Area | Test |
| --- | --- |
| Ignore list in document | `placed(ignoring:)` hides dismissed ids, ignored rules and dictionary words (spelling only); other suggestions stay |
| Ignore list file | Save → load gives the same lists; a missing or corrupt file gives an empty list without throwing |
| Apply plan | Replacing a span gives the expected new text and caret position (end of the replacement), with Hebrew/emoji before the span; a span whose current text isn't `original` → refused |

Integration (`scripts/m3-check.py`, installed debug app + FixtureApp). Clicks and keys can't be sent from the shell, so the harness calls the same accept/dismiss code the card buttons call, through the debug socket:

| # | Scenario | Pass |
| --- | --- | --- |
| 1 | Accept "recieve" → "receive" (AX path) | Field text is exactly the fixed sentence; the underline is gone |
| 2 | Undo in the fixture | Original text back |
| 3 | Accept a whole-sentence replacement (decision 0007) | Field text as expected; caret right after the new sentence |
| 4 | Accept through the paste fallback | Field text fixed; pasteboard text identical before and after |
| 5 | Dismiss, then type more | The dismissed item stays gone |
| 6 | Add to dictionary, then type the word again in a new sentence | Never flagged; still gone after an app restart |
| 7 | Ignore rule | No suggestion with that rule id anywhere in the text |
| 8 | Mistake log | Accept → exactly one new row with the sentence **before** the fix, original, replacement, category, bundle id; dismiss / ignore / dictionary → no row; log turned off → no row; log file read-only → fix still applied, app still running |
| 9 | Text changed under a stale suggestion | Accept refused, field unchanged |

Real-app check (`scripts/real-app-check.py <bundle id>`, installed debug app; the app posts the clicks and ⌥⏎ itself as hardware events through the debug socket, so the mouse monitor and the event tap are exercised): underlines on "I recieve the mail every day. She dont like teh rain." → click underline opens the card → click the first fix fixes it → caret at the end of "teh" + ⌥⏎ fixes it → ⌥⏎ with nothing flagged reaches the app (skipped in Messages: a stray Return could send) → card closed. Run in TextEdit, Notes, Mail (compose body is a WebKit web area, read through text markers, decision 0009; fixes go through paste) and Messages (a new message with no recipient).

Manual (real apps, installed app): click an underline → the card opens under the word; click a replacement → fixed; ⌥⏎ with the caret in a flagged word → fixed; ⌥⏎ elsewhere → normal behaviour. Do this in TextEdit, Notes, Mail, Messages; each accept shows up in `mistakes.sqlite`. Verified manually only: clicks and keys can't be sent from the shell without granting the terminal Accessibility.

Exit: unit + `m3-check.py` green, manual check done.

**M3 result (2026-10-15):** unit 63/63; `m3-check.py` 12/12 (test 8 split into 8a–8d); `m2-check.py` still 6/6. Real app, installed `.app`, through the debug socket (not a click): accept in TextEdit fixed "recieve" → "receive" via the AX path and wrote one `mistakes.sqlite` row. Real clicks and keys in TextEdit, posted as hardware events by the app itself (debug `click` / `optionReturn` commands): click on underline → card opened; click on the card's first fix → fixed; caret at the end of "teh" + ⌥⏎ → "the"; ⌥⏎ with no flagged word under the caret → a normal new line. The stale guard also refused one accept whose span had changed. Then the same real-click check in other real apps (`real-app-check.py`): Notes 6/6, Mail 6/6 (after adding WebKit text markers, decision 0009, and a guard so ⌥⏎ never acts on a stale position after a paste fix), Messages 5/5 (passthrough skipped). Final rerun on the last build: TextEdit 6/6, `m3-check.py` 12/12, `m2-check.py` 6/6, unit 63/63. One earlier rerun had a flaky TextEdit 5/6 and one m3-check crash (a suggestion not yet re-checked when the script looked); both passed on the next run. **M3 exit check: passed.** Harness note: FixtureApp needs an Edit menu, or ⌘V (paste fallback) and ⌘Z do nothing.

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
- Merge, same word (decision 0008): Harper `dont` → [don't, dent, don] plus model `dont` → doesn't → one suggestion [doesn't, don't, dent], model category and reason, Harper's rule id. A model span containing the Harper span → same. Partial overlap → model edit dropped.
- Accepting a rewrite replaces the whole sentence, removes that sentence's word-level suggestions, and logs exactly one mistake-log row (`grammar` for fix, `clarity` for natural).
- When a sentence is ready (decision 0010): ends in `.?!` and the caret is not inside it (caret right after the final `.` counts as outside) → ready; no final punctuation → ready only when the caret is outside the sentence and not touching it.
- Same sentence seen again (typed, deleted, retyped) → no second request (in-memory cache by sentence hash).
- A failed request is retried at most twice per sentence; the next request after a failure puts the fallback model first.
- Cost: `usage.cost` from each response is added to today's total; a new day resets the count and the cost.
- Code-fenced JSON (```json … ```) from the model is still read.
- Hit-testing and ⌥⏎ prefer a word-level suggestion over the sentence-wide one when both cover the caret or click.
- Near the caret only (decision 0013): with a caret, only the caret's sentence and up to 2 sentences on each side are sent; a 20-sentence text with the caret at the end → at most 3 requests; moving the caret to the top → the top sentences are sent. No caret (a web page being read, not a field being written in) → nothing is sent.
- Terminals (decision 0013): in cmux, Terminal, iTerm2, Ghostty and Warp tier 2 sends nothing (checked through the installed app: focus cmux → `tier2.counters.requests` doesn't move while its output changes).
- Only after the user's own input (decision 0014): tier 2 sends nothing unless a key was pressed or the mouse clicked in the last 10 s. Through the installed app: text set without a key press → 0 requests; the final "." typed as a real key press (debug `type`) → 1 request. A Chrome page that keeps changing while nobody types → 0 requests.
- Terminals (decision 0014): in cmux, Terminal, iTerm2, Ghostty and Warp nothing is checked or drawn (`state` shows no element).
- Keychain: the debug socket `keychainSelfTest` saves, reads back and deletes a dummy item under a test account (never the real key).
Real app, automated (`scripts/m4-real-app.py`, TextEdit, real clicks and ⌥⏎ posted by the debug app): "She dont know. Is it work?" → "dont" offers doesn't first; ⌥⏎ → "She doesn't know."; click the dashed line → card → click the fix → "Does it work?".
Manual (real app): type "She dont know." → the card offers "doesn't" first and "don't" second; ⌥⏎ → "She doesn't know." Type "Is it work?" in TextEdit → a red dashed line under the whole sentence; card offers "Does it work?"; accept → the sentence is replaced. Type a correct but stiff sentence → blue dashed line with a more natural version.
Live test: replaced by the real calls in `scripts/m4-check.py`, `scripts/m4-real-app.py` and `eval/score.py` (decision 0011).
Eval: run `score.py` (including: on clean, natural sentences `rewrite` is `null` ≥ 90% of the time, decision 0007) for Haiku 5.5, GPT-6 Luna, DeepSeek V4 Flash → pick the main model.
Exit: green + eval done.

**M4 result (2026-10-15):**
- Core tests 87/87 (unit tests).
- `scripts/m4-check.py` 11/11 on FixtureApp, through the installed app with real OpenRouter calls. Three of the last four runs passed; one run missed check 7 (a slow answer). The script now waits until the app is watching the text view, because after a restart the app could miss the first focus event.
- `scripts/m4-real-app.py` 4/4 in TextEdit, with real clicks and ⌥⏎: "dont" → "doesn't" first; clicking the dashed line and then the fix → "Does it work?".
- M2/M3 regression: `m2-check` 6/6, `m3-check` 12/12.
- Overlay and card rendered to PNG (`snapshot`) and inspected: red dashed line under the sentence; card shows "Fix the whole sentence", the struck-through original and the fix.
- Prompt: "She dont know." first gave "don't" in the app; after "fix the agreement, not only the spelling", 18/18 direct calls gave "doesn't" (grammar).
- Eval: DeepSeek V4 Flash only. Haiku 5.5 and GPT-6 Luna are blocked by the account's OpenRouter guardrail. Results and choice are in decision 0011: 98% fixed, 0% false positives, rewrite null 100% on clean sentences, p95 3.9 s (misses the 2 s target), ≈ $0.05 per 1,000 sentences.
- Fix after M4 (2026-10-17, decision 0013): cmux's terminal output and Chrome pages used up the 1,000-request daily cap, so TextEdit got no model answers. Now only sentences near the caret are sent, nothing with no caret, and nothing in terminals. Checked through the installed app: 10 s each in cmux and Chrome → 0 requests; TextEdit "does it works? / is it works?" → "does it work" / "does it work?"; `m4-real-app` 4/4; `m4-check` 11/11. Earlier runs failed only while the user was typing on the same machine.
- Not done: the manual stiff-sentence → blue line check. DeepSeek almost never suggests natural rewrites (0 of 50 clean sentences), so it's only covered by unit tests.

## M5 — Wider app support + polish (3 days)

Build: `AXManualAccessibility` / `AXEnhancedUserInterface` for Electron/Chromium; badge-only mode when bounds unavailable; global hotkey "check selection" for Google Docs; per-app exclusions; on/off switch for "natural wording" rewrites; cost display; app icon; release build reading key from Keychain only; "My mistakes…" window (list, filter by category, most-repeated view, Export CSV) + Settings toggle and "Delete all".
Tests: full manual matrix above — every app gets layer 1, 2 or 3 and none gets nothing; excluded app → zero checks and zero mistake-log rows; accepting a fix via the hotkey popover and accepting a sentence rewrite both log a row; the exported CSV opens cleanly in Numbers.
Exit: one week of daily use; every false positive / miss logged into `eval/golden.jsonl`.

## Go / no-go for cancelling Grammarly

Targets (from `score.py` + a week of use): error recall ≥ 80%, false positives ≤ 5% on clean sentences, p95 local ≤ 100 ms, p95 tier 2 ≤ 2 s, cost ≤ $3/month, works in your top 5 apps.
