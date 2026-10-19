#!/usr/bin/env python3
"""Writing window check (PLAN.md → M5, decision 0016), through the installed app with real key presses.

Opens the window with ⌃⌥Space over TextEdit, types a sentence with mistakes, accepts a fix with ⌥⏎, pastes back
with ⌘⏎, checks Esc keeps the draft and Copy fills the clipboard, then pastes into a new Terminal window.
Uses a temp mistake log; restores the clipboard. Never targets cmux (it would type into a live session).
Needs: scripts/install.sh run. Takes over the screen for ~40 s; makes one or two OpenRouter calls.
Usage: scripts/compose-check.py
"""
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_helpers import app, state  # noqa: E402

SELF = "com.danielmaymon.WritingAssistant"
SENTENCE = "I recieve the mail every days."
results = []


def check(number, name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {number}. {name}" + (f"  ({detail})" if detail else ""))


def until(fetch, predicate, timeout):
    end = time.monotonic() + timeout
    value = fetch()
    while not predicate(value) and time.monotonic() < end:
        time.sleep(0.1)
        value = fetch()
    return value


def osascript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def key(code, *modifiers):
    using = f" using {{{', '.join(m + ' down' for m in modifiers)}}}" if modifiers else ""
    osascript(f'tell application "System Events" to key code {code}{using}')


def hotkey():
    key(49, "control", "option")  # ⌃⌥Space


def compose():
    return app(cmd="compose")


def clipboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def set_clipboard(text):
    subprocess.run(["pbcopy"], input=text, text=True)


def textedit_text():
    return osascript('tell application "TextEdit" to get text of front document')


def main():
    work = tempfile.mkdtemp(prefix="wa-compose-")
    db = os.path.join(work, "mistakes.sqlite")
    saved_clipboard = clipboard()
    app(cmd="setTierTwo", enabled=True)
    app(cmd="setLog", enabled=True, path=db)
    app(cmd="resetIgnore")
    app(cmd="compose", text="", close=True)
    osascript('tell application "TextEdit"\nactivate\nmake new document with properties {text:"Start: "}\nend tell')
    until(state, lambda s: s.get("app") == "com.apple.TextEdit", 5)
    key(125, "command")  # caret to the end
    terminal_opened = False
    try:
        # 1. ⌃⌥Space opens the window in front, and the checker follows its text box.
        hotkey()
        c = until(compose, lambda c: c["key"], 3)
        s = until(state, lambda s: s.get("app") == SELF and s.get("role") == "AXTextArea", 3)
        check(1, "⌃⌥Space → Writing window in front, being checked", c["key"] and s.get("app") == SELF
              and c["previousApp"] == "com.apple.TextEdit", f"compose={c}, app={s.get('app')}, role={s.get('role')}")

        # 2. Real typing there → underlines from both tiers.
        app(cmd="type", text=SENTENCE)
        s = until(state, lambda s: s.get("text") == SENTENCE and any(x["original"] == "recieve" for x in s["suggestions"])
                  and any(x["source"] == "llm" for x in s["suggestions"]), 25)
        check(2, "typed sentence → word and AI underlines", any(x["original"] == "recieve" for x in s["suggestions"])
              and any(x["source"] == "llm" for x in s["suggestions"]),
              f"text={s.get('text')!r}, found={[(x['original'], x['source']) for x in s['suggestions']]}")

        # 3. ⌥⏎ with the caret in "recieve" → fixed and logged as "Writing window".
        key(123, "command")  # line start
        for _ in range(4):
            key(124)  # → into "recieve"
        until(state, lambda s: s["atCaret"], 2)
        app(cmd="optionReturn")
        c = until(compose, lambda c: "receive" in c["text"], 3)
        con = sqlite3.connect(db)
        rows = list(con.execute("SELECT appName, original, replacement FROM mistakes"))
        con.close()
        check(3, "⌥⏎ → fixed in the window, logged as Writing window", "I receive" in c["text"]
              and ("Writing window", "recieve", "receive") in rows, f"text={c['text']!r}, rows={rows}")

        # 4. ⌘⏎ → closes, pastes into TextEdit, gives the clipboard back.
        expected = c["text"]
        set_clipboard("CLIPBOARD-BEFORE")
        key(36, "command")
        text = until(textedit_text, lambda t: t == "Start: " + expected, 3)
        time.sleep(0.8)
        c = compose()
        check(4, "⌘⏎ → pasted into TextEdit, window closed, clipboard restored", text == "Start: " + expected
              and not c["visible"] and clipboard() == "CLIPBOARD-BEFORE" and c["text"] == "",
              f"TextEdit={text!r}, visible={c['visible']}, clipboard={clipboard()!r}, draft={c['text']!r}")

        # 5. Esc closes and keeps the draft.
        hotkey()
        until(compose, lambda c: c["key"], 3)
        app(cmd="type", text="a draft")
        until(compose, lambda c: c["text"] == "a draft", 2)
        key(53)  # Esc
        closed = until(compose, lambda c: not c["visible"], 2)
        hotkey()
        reopened = until(compose, lambda c: c["key"], 3)
        check(5, "Esc → closed, draft still there on reopen", not closed["visible"] and reopened["text"] == "a draft",
              f"closed={not closed['visible']}, draft={reopened['text']!r}")

        # 6. Copy → clipboard holds the text, window closed.
        osascript(f'tell application "System Events" to tell process "WritingAssistant" to click button "Copy" of window "Writing window"')
        c = until(compose, lambda c: not c["visible"], 2)
        check(6, "Copy → text on the clipboard, window closed", clipboard() == "a draft" and not c["visible"],
              f"clipboard={clipboard()!r}")
        app(cmd="compose", text="")

        # 7. Paste back into a terminal prompt (a new Terminal window, never cmux).
        osascript('tell application "Terminal"\nactivate\ndo script ""\nend tell')
        terminal_opened = True
        until(lambda: osascript('tell application "System Events" to get bundle identifier of first process whose frontmost is true'),
              lambda b: b == "com.apple.Terminal", 5)
        # Wait for the shell's prompt: text pasted while the shell is still starting is thrown away.
        until(lambda: osascript('tell application "Terminal" to get contents of selected tab of front window'),
              lambda t: t.rstrip().endswith(("%", "$")), 10)
        time.sleep(0.5)
        hotkey()
        until(compose, lambda c: c["key"], 3)
        app(cmd="type", text="echo hello from the writing window")
        until(compose, lambda c: c["text"].endswith("window"), 3)
        key(36, "command")
        contents = until(lambda: osascript('tell application "Terminal" to get contents of selected tab of front window'),
                         lambda t: "echo hello from the writing window" in t, 3)
        check(7, "⌘⏎ → pasted at the Terminal prompt (not run)", "echo hello from the writing window" in contents
              and "\nhello from the writing window" not in contents, f"last line={contents.strip().splitlines()[-1:]!r}")
    finally:
        if terminal_opened:
            key(32, "control")  # ⌃U clears the prompt line
            osascript('tell application "Terminal" to close front window')
        osascript('tell application "TextEdit" to close front document saving no')
        app(cmd="compose", text="", close=True)
        app(cmd="setLog", enabled=True, path="")
        set_clipboard(saved_clipboard)
    print(f"\n{sum(results)}/{len(results)} passed; files in {work}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
