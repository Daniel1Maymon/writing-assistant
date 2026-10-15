# Handoff — Writing Assistant (as of 2026-10-15, after M4)

Read this first, then `CLAUDE.md` (standing rules), `DESIGN.md` (what/why), `PLAN.md` (milestones + tests), and `docs/decisions/`.

## What the project is

A personal Grammarly replacement: a native macOS menu-bar app (Swift) that underlines spelling, grammar and clarity problems in **any** app and applies one-click fixes. Checks are free and local where possible (`NSSpellChecker`), with an AI model via OpenRouter for the rest. It also has a **mistake log**: a local SQLite file of every accepted fix, which the user wants for learning. One user, no server, no App Store.

## Done so far

| Item | Where | Verified by |
| --- | --- | --- |
| Design + build/test plan | `DESIGN.md`, `PLAN.md` | — |
| Mistake log designed | `DESIGN.md` → Mistake log; decision 0002 | — |
| `Core/` package + `.env` parser | `Core/Sources/Core/EnvFile.swift` | 13/13 tests (`swift test --package-path Core`) |
| **M0 shell app: done** | `App/`, `project.yml`, `scripts/install.sh` | Installed Xcode build in `/Applications`; see PLAN.md → M0 result |
| Signing with a local self-signed certificate | decision 0003 | Permission survived a rebuild with a different code hash |
| Tier-1 probe inside the real app | `DESIGN.md` → Open decision | Grammar is weak but present (caught "I has a apple."). Harper should be evaluated at the start of M2 |
| Dev model = DeepSeek V4 Flash | decision 0004 | User's choice; M4 eval decides the final model |
| **M1 core logic: done** | `Core/Sources/Core/` (Sentence, Suggestion, LRUCache, MistakeLog) | 43/43 tests, 95.8% line coverage |
| **M2 Harper + underlines: done** | `App/`, `AXKit/`, decisions 0005–0006 | `scripts/m2-check.py` 6/6 + manual in TextEdit |
| **M3 card, accept, ⌥⏎, ignore, dictionary: done** | `App/Card.swift`, `App/Applier.swift`, decisions 0008–0009 | `scripts/m3-check.py` 12/12; real clicks/⌥⏎ via `scripts/real-app-check.py` in TextEdit, Notes, Mail, Messages |
| **M4 OpenRouter tier 2: done** | `Core/Sources/Core/TierTwo*.swift`, `App/OpenRouterTransport.swift`, `eval/`, decisions 0010–0011 | `scripts/m4-check.py` 11/11, `scripts/m4-real-app.py` 4/4 in TextEdit, `eval/score.py` (DeepSeek: 98% fixed, 0% false positives) |
| Git repo | `.gitignore` | Committed per milestone (M0–M4) |

## How to build

```bash
scripts/install.sh            # xcodegen → xcodebuild → sign → /Applications → launch
scripts/install.sh --probe    # same, and run the spell-checker probe at launch
```

- `WritingAssistant.xcodeproj` is generated from `project.yml` and git-ignored. Edit `project.yml`, not the project.
- **Don't sign in the Xcode IDE.** `install.sh` signs with "WritingAssistant Local Signing" from the login keychain, which is what keeps the Accessibility permission. Running from the IDE gives an ad-hoc build (decision 0003).
- DerivedData lives in `~/Library/Developer/Xcode/DerivedData/WritingAssistant-local`; under Desktop, `codesign` fails.
- App logs: `log show --last 5m --info --predicate 'subsystem == "com.danielmaymon.WritingAssistant"'`.

## Machine state

- The Xcode license is accepted (2026-10-15). Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; `xcode-select` still points to the Command Line Tools, and that's fine.
- Accessibility is granted to `com.danielmaymon.WritingAssistant`, and launch at login is on.
- On macOS 27, `CGWindowListCopyWindowInfo` doesn't show per-app menu-bar icons (`MenuBarAgent` draws them), and `screencapture` is blocked. Confirming the menu-bar icon needs a screenshot from the user.

## Next steps

1. M5: wider app support + polish (PLAN.md).
2. Waiting on the user: allow Haiku 5.5 and GPT-6 Luna in the OpenRouter guardrail, then rerun `eval/score.py` for all three (decision 0011). Until then the `.env` fallback model fails.
3. Open: tier-2 p95 latency is 3.9 s against a 2 s target.
4. Open item from M0: test 4 (the "Open System Settings…" button).

## Working with this user

- **Do the work yourself.** Only hand over steps that truly need the user (password, license, Apple ID), and batch them into one short list, not one at a time. Look for a no-sudo route first; `DEVELOPER_DIR` is an example of one that was missed.
- Plain English, short and scannable; give one topic per message.
- Never print `.env` values. To check the key, print only whether it's set and its length.

- **Never hand him test steps.** The debug build drives real apps itself: the `click` / `optionReturn` socket commands post real hardware events. Test in Messages only in a new message with no recipient.
- The terminal (cmux) grabs focus between shell commands. Activate the target app inside the same command before any keystroke.

## Tool quirks on this machine

There's an `rtk` hook that rewrites shell commands:

- `cat a b` (several files) failed; use the Read tool.
- `find` with `-prune`/`-o` is refused.
- `ls` of a single path can print nothing; use `test -d`.
- `cat` of a source file can hide comment lines; read with the Read tool before an exact replacement.
- `swift test` output gets trimmed. Prefix commands with `rtk proxy` to get raw output.
