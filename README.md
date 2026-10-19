# Writing Assistant

A personal Grammarly alternative for macOS. It lives in the menu bar, watches what you type in any app, and underlines mistakes as you go. Click an underline (or press ⌥⏎) to fix it. Every fix you accept is saved to a private log on your Mac, so you can see which mistakes you keep making.

## How it works

There are two kinds of fixes:

- **Word fix:** one word is wrong. "recieve" → "receive". A red line goes under the word. Found instantly, on your Mac.
- **Whole-sentence fix:** every word is spelled right, but the sentence is wrong. "Is it work?" → "Does it work?". An orange line goes under the sentence. An AI model finds these.

### Story 1: writing in a normal app (Mail, Notes, Slack, Chrome, TextEdit…)

**Step 1. You type.** Both mistakes get underlined.

![Mistakes underlined](docs/images/1-underlines.png)

**Step 2. Click the red word.** A card shows the fix. Click it (or press ⌥⏎).

![Word fix card](docs/images/2-word-card.png)

**Step 3. Click the orange sentence.** A card shows the whole sentence, fixed. Click it.

![Whole-sentence fix card](docs/images/3-sentence-card.png)

**Step 4. Done.** Both fixes are in your text.

![Text after both fixes](docs/images/4-fixed.png)

### Story 2: writing in a terminal (cmux, Terminal, iTerm)

The app can't check text inside a terminal directly. So you write in the Writing window instead.

**Step 1. Press ⌃⌥Space and type.** A small window opens on top of the terminal. Mistakes get underlined there.

![Writing window over a terminal](docs/images/5-writing-window.png)

**Step 2. Fix them.** Put the cursor in a mistake and press ⌥⏎ (or click the underline).

![Writing window after the fixes](docs/images/6-writing-window-fixed.png)

**Step 3. Press ⌘⏎.** The window closes and the fixed text is pasted at your terminal prompt. Nothing runs until you press Enter. (Or click Copy instead.)

![Fixed text pasted at the terminal prompt](docs/images/7-pasted-in-terminal.png)

### Then: see every fix you accepted

Menu bar icon → "My mistakes…". Every fix is saved: what you wrote, what it changed to, the app, and the sentence. The fixes from both stories are at the top. You can search, filter by type, see your most repeated mistakes, delete rows, and export to CSV.

![My mistakes window](docs/images/8-my-mistakes.png)

## Shortcuts

| Keys | What it does |
| --- | --- |
| ⌥⏎ | Accept the fix under the cursor |
| ⌃⌥Space | Open or close the Writing window |
| ⌘⏎ (in the Writing window) | Paste the text back into the app you came from |
| Esc (in the Writing window) | Close it and keep the draft |

## Architecture

A native macOS menu-bar app (Swift, AppKit + SwiftUI). It reads and edits text in other apps through the **Accessibility API (AX)**, draws underlines in its own click-through window, and runs two checkers: **Harper** locally and an **LLM via OpenRouter**. No server of its own.

### Components

```
 Other apps (Mail, Slack, Chrome, TextEdit…)           Writing window (our own NSWindow, decision 0016)
        │  AXObserver notifications                           │  forwards its own text/selection events
        ▼                                                     ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ FocusTracker            AXKit/FocusTracker.swift                            │
 │   follows the focused text element; emits .focusChanged / .valueChanged /   │
 │   .geometryChanged. AXElement wraps AXUIElement (value, selection, bounds). │
 └─────────────────────────────────────┬───────────────────────────────────────┘
                                       ▼
 ┌─────────────────────────────────────────────────────────────────────────────┐
 │ CheckController (@MainActor)   App/CheckController.swift   — the hub        │
 │   DocumentState (Core): text → [Sentence] (NSRange, hash), diff → dirty     │
 │   debounce 400 ms → tier 1 on dirty sentences; tier 2 near the caret        │
 │   OptionReturnTap (CGEventTap): ⌥⏎ accept, ⌃⌥Space Writing window, key time │
 │   NSEvent mouse monitors: clicks on underlines → card                       │
 └───────┬─────────────────────────┬──────────────────────┬────────────────────┘
         │                         │                      │
         ▼                         ▼                      ▼
 ┌──────────────────┐  ┌──────────────────────────┐  ┌─────────────────────────┐
 │ HarperClient     │  │ TierTwoScheduler (Core)  │  │ OverlayController       │
 │ (actor)          │  │ which sentences, cache,  │  │ borderless NSPanel,     │
 │ harper-ls over   │  │ daily cap, retries,      │  │ click-through;          │
 │ LSP on stdio     │  │ cancels stale requests   │  │ SquiggleView draws      │
 │ → [Suggestion]   │  │ TierTwoRequest builds    │  │ marks at AX bounds,     │
 │ (fallback:       │  │ body / parses JSON       │  │ redrawn every 100 ms    │
 │ NSSpellChecker)  │  │        │                 │  └─────────────────────────┘
 └──────────────────┘  │        ▼                 │  ┌─────────────────────────┐
                       │ OpenRouterTransport      │  │ CardController (SwiftUI)│
                       │ POST /chat/completions   │  │ fixes, Dismiss, Ignore  │
                       │ models: [main, fallback] │  └────────────┬────────────┘
                       └──────────────────────────┘               │ accept
                                                                  ▼
                       ┌──────────────────────────┐  ┌─────────────────────────┐
                       │ MistakeLog (Core, SQLite)│◄─│ Applier                 │
                       │ → MistakesWindow (SwiftUI│  │ AX setSelectedText;     │
                       │   Table, search, CSV)    │  │ ⌘V paste fallback       │
                       └──────────────────────────┘  └─────────────────────────┘
```

| Target | Contents | Depends on |
| --- | --- | --- |
| `Core/` (SwiftPM) | Pure logic, no AppKit, no network: `Sentence` segmenting + diff, `DocumentState`, `Suggestion`, merge rules, `TierTwoRequest`, `TierTwoScheduler`, `MistakeLog`, LSP framing | Foundation, SQLite3 |
| `AXKit/` | `AXElement`, `FocusTracker` | ApplicationServices |
| `App/` | The app: `CheckController`, `HarperClient`, `OpenRouterTransport`, `OverlayController`, `CardController`, `Applier`, `ComposeWindowController`, `MistakesWindowController`, menu (`WritingAssistantApp`, `AppState`) | Core, AXKit |
| `Shared/` | `LineSocketServer` (debug socket) | |
| `Fixtures/` | `FixtureApp`: a test app with known text fields, driven over its own socket | |

### Flow of one keystroke

Example: the user types the final `?` of `I recieve your mail. Is it work?` in Mail.

```
 user    Mail    FocusTracker      CheckController       HarperClient       TierTwoScheduler      OpenRouter       Overlay
   │       │           │                  │                    │                    │                  │              │
   │─ "?" ►│           │                  │                    │                    │                  │              │
   │       │─ AXValue ►│                  │                    │                    │                  │              │
   │       │           │─ .valueChanged ─►│                    │                    │                  │              │
   │       │           │                  │ DocumentState      │                    │                  │              │
   │       │           │                  │ .update(text)      │                    │                  │              │
   │       │           │                  │──────────────── redraw (kept underlines follow the text) ────────────────►│
   │       │           │                  │ 400 ms, no key     │                    │                  │              │
   │       │           │                  │─ check(sentence) ─►│                    │                  │              │
   │       │           │                  │◄ recieve→receive ──│                    │                  │              │
   │       │           │                  │────────────────────── store + redraw: red underline ─────────────────────►│
   │       │           │                  │─────── update(sentences, caret) ───────►│                  │              │
   │       │           │                  │                    │                    │ finished? near   │              │
   │       │           │                  │                    │                    │ caret? cached?   │              │
   │       │           │                  │                    │                    │ under daily cap? │              │
   │       │           │                  │                    │                    │────── POST ─────►│              │
   │       │           │                  │                    │                    │◄── JSON edits ───│              │
   │       │           │                  │◄──────────── onResult(...) ─────────────│                  │              │
   │       │           │                  │─────────────────── storeLLM + redraw: orange underline ──────────────────►│
   │       │           │                  │                    │                    │                  │              │
```

Then, on accept (click on the card, or ⌥⏎ caught by `OptionReturnTap`):

1. `CheckController.replace` calls `Applier.apply`. It checks that the text at the range is still the original, then sets the AX selection to that range and sets `AXSelectedText`.
2. It waits up to 200 ms for the field's value to change. Some apps accept the AX call and do nothing. In that case it selects the range and pastes with ⌘V, then restores the clipboard.
3. On success, a `MistakeEntry` (app, sentence, original, replacement, category, source) is written to `MistakeLog` and `.mistakeRecorded` is posted, so an open "My mistakes" window reloads.

### Key rules in the flow

- **Offsets are UTF-16 `NSRange` everywhere**, to match AX and `NSString`.
- **Sentences are the unit of work.** Results are stored by sentence hash, so editing one sentence only re-checks that one. Underlines on the others are kept and moved.
- **Tier 2 is gated** (decisions 0010, 0013, 0014). A sentence is sent only when:
  - it looks finished: it ends in `.?!` and the caret has left it,
  - it is within 2 sentences of the caret,
  - there was a real key press or click in the last 10 s,
  - and the daily request cap is not reached.
  Results are cached (500 sentences). A request whose sentence changed is cancelled.
- **Merge** (decision 0008): on the same word, the model's fix comes first and Harper's are alternatives. Model edits that only partly overlap a Harper fix are dropped.
- **Terminals are not checked** (cmux, Terminal, iTerm2, Ghostty, Warp). Use the Writing window there.
- **Never touched:** secure (password) fields. Diagnostic logs never contain user text.

### Threading

| What | Where it runs |
| --- | --- |
| `CheckController`, `FocusTracker`, overlay, card, windows | Main actor. AX callbacks arrive on the main run loop. |
| `HarperClient` | Swift `actor`. Owns the `harper-ls` process and reads its stdout on a background reader. |
| `TierTwoScheduler` | Main actor. Each request is a `Task`; the network call is `URLSession` async. |
| `OptionReturnTap` | `CGEventTap` on the session event tap. Swallows ⌥⏎ only when there's a suggestion at the caret, and ⌃⌥Space always. |
| Timers | 100 ms redraw (catches scrolling, which has no AX event); 1 s tier-2 re-check (catches the caret leaving a sentence by a click). |

### The Writing window (decision 0016)

Terminals don't expose a usable text element, so the app hosts its own: `ComposeWindowController`. It's a floating `NSWindow` with an `NSTextView`, shown on all Spaces (decision 0017).

- `FocusTracker.allowsOwnApp` lets the tracker attach to our own process while the window is key.
- macOS sends no AX notifications to a process about its own elements. So the window forwards its own text and selection changes to `FocusTracker.forward`, which feeds the normal pipeline.
- Those events are forwarded **asynchronously**. Accepting a fix sets the selection through AX on our own process, and reading AX again from inside that call deadlocks.
- ⌘⏎ saves the clipboard, activates the previous app, waits until it's frontmost, posts ⌘V, then restores the clipboard.

### Testing

| Level | How | Run |
| --- | --- | --- |
| Unit | Swift Testing on `Core` (sentences, merge, LLM request/parse, scheduler, mistake log) | `swift test --package-path Core` |
| Integration | `FixtureApp` + debug socket `/tmp/wa-debug.sock` (debug builds only): `state`, `type` (real key events), `click`, `optionReturn`, `compose`, `mistakes`… | `scripts/*-check.py` |
| Real app | The same scripts against the **installed** app in TextEdit and Terminal, with real key presses | e.g. `scripts/compose-check.py` |

Rules for changes (see `CLAUDE.md`): update the test list in `PLAN.md` first, write non-obvious choices to `docs/decisions/`, and only call something working once it's been seen working in a real app.

### Configuration

Debug builds read `.env` (git-ignored) first. The key falls back to the Keychain in every build.

| Key | In `.env` (what runs today) | Default in code if not set |
| --- | --- | --- |
| `OPENROUTER_API_KEY` | your key | Keychain, set from the menu ("Set OpenRouter Key…") |
| `OPENROUTER_MODEL` | `deepseek/deepseek-v4-flash` (decision 0011) | `anthropic/claude-haiku-5.5` |
| `OPENROUTER_FALLBACK_MODEL` | `minimax/minimax-m3` (decision 0012) | `openai/gpt-6-luna` |
| `DAILY_REQUEST_CAP` | `1000` | `1000` |

## Build and install

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
scripts/install.sh            # builds and installs /Applications/WritingAssistant.app
```

The first time it runs, allow it in System Settings → Privacy & Security → Accessibility. Add your OpenRouter key from the menu ("Set OpenRouter Key…").

## More

- [DESIGN.md](DESIGN.md): what it does and why.
- [PLAN.md](PLAN.md): milestones and the test list for each one.
- [docs/decisions/](docs/decisions/): every non-obvious choice, one file each.
- The screenshots are made by `scripts/readme-shots.py` with sample text.
