# Writing Assistant

A personal Grammarly replacement for macOS. It lives in the menu bar, watches what you type in any app, and underlines mistakes as you go. Click an underline (or press ⌥⏎) to fix it. Every fix you accept is saved to a private log on your Mac, so you can see which mistakes you keep making.

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

## What's under the hood

- **Tier 1, on your Mac:** [Harper](https://writewithharper.com) checks spelling and grammar locally, in milliseconds, for free.
- **Tier 2, AI:** sentences go to an AI model via OpenRouter (`deepseek/deepseek-v4-flash`, falling back to `minimax/minimax-m3`). This happens only right after you type, so it costs a few dollars a month at most.
- **Mistake log:** a SQLite file on your Mac (`mistakes.sqlite`). It can be turned off in the menu ("Save accepted fixes").
- **Privacy:** no accounts, no server of its own. Diagnostic logs never contain your text.

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
