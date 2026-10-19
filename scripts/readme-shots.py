#!/usr/bin/env python3
"""Takes the README screenshots through the installed app, with sample text and a sample mistake log.

TextEdit: 1. underlines  2. the word card  3. the whole-sentence card  4. both fixed
Terminal: 5. the Writing window with underlines  6. fixed  7. pasted at the prompt (not run)
8. "My mistakes", showing the fixes just made
Only the app's own windows and the sample windows are captured (each shot is cropped to them).
Needs: scripts/install.sh run, Screen Recording allowed for the terminal. Takes over the screen for ~1 min.
Usage: scripts/readme-shots.py   (writes docs/images/*.png)
"""
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_helpers import ROOT, app, card_buttons, state  # noqa: E402

OUT = os.path.join(ROOT, "docs", "images")
SENTENCE = "I recieve your mail. Is it work?"
DRAFT = "Plese check my code. Is it work now?"
TEXTEDIT = (160, 140, 860, 520)  # left, top, right, bottom (points, top-left origin)
SAMPLE = [  # (createdAt, app, sentence, original, replacement, category)
    ("2026-10-12T08:14:00.000Z", "Mail", "I recieve the invoice every month.", "recieve", "receive", "spelling"),
    ("2026-10-13T10:02:00.000Z", "Slack", "Their going to merge it today.", "Their", "They're", "grammar"),
    ("2026-10-14T16:40:00.000Z", "Writing window", "Can you looks at the PR?", "looks", "look", "grammar"),
    ("2026-10-15T09:31:00.000Z", "Notes", "Call the bank tomorow.", "tomorow", "tomorrow", "spelling"),
    ("2026-10-16T13:05:00.000Z", "Chrome", "The tests is failing on main.", "is", "are", "grammar"),
    ("2026-10-17T18:22:00.000Z", "Mail", "I will recieve it on Monday.", "recieve", "receive", "spelling"),
    ("2026-10-18T11:47:00.000Z", "Writing window", "Is it work on your machine?", "Is it work", "Does it work", "grammar"),
]


def osascript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def key(code, *modifiers):
    using = f" using {{{', '.join(m + ' down' for m in modifiers)}}}" if modifiers else ""
    osascript(f'tell application "System Events" to key code {code}{using}')


def until(fetch, predicate, timeout):
    end = time.monotonic() + timeout
    value = fetch()
    while not predicate(value) and time.monotonic() < end:
        time.sleep(0.2)
        value = fetch()
    return value


def shot(name, left, top, right, bottom):
    path = os.path.join(OUT, name)
    subprocess.run(["screencapture", "-x", f"-R{left},{top},{right - left},{bottom - top}", path], check=True)
    print("saved", path)


def window_frame(process, title):
    out = osascript(f'tell application "System Events" to tell process "{process}" to get {{position, size}} of window "{title}"')
    x, y, w, h = (float(n) for n in out.replace(" ", "").split(","))
    return x, y, x + w, y + h


def click_first_fix():
    bx, by, bw, bh = card_buttons()[0]
    app(cmd="click", x=bx + bw / 2, y=by + bh / 2)


def idle_seconds():
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    return next(int(line.split()[-1]) // 1_000_000_000 for line in out.splitlines() if "HIDIdleTime" in line)


def seed(db):
    con = sqlite3.connect(db)
    con.execute("""CREATE TABLE mistakes (id INTEGER PRIMARY KEY, createdAt TEXT NOT NULL, appBundleId TEXT NOT NULL,
                   appName TEXT NOT NULL, sentence TEXT NOT NULL, original TEXT NOT NULL, replacement TEXT NOT NULL,
                   category TEXT NOT NULL, message TEXT NOT NULL, ruleId TEXT, source TEXT NOT NULL)""")
    for at, name, sentence, original, replacement, category in SAMPLE:
        con.execute("INSERT INTO mistakes (createdAt, appBundleId, appName, sentence, original, replacement, category,"
                    " message, source) VALUES (?, ?, ?, ?, ?, ?, ?, '', 'local')",
                    (at, "sample." + name, name, sentence, original, replacement, category))
    con.commit()
    con.close()


def main():
    os.makedirs(OUT, exist_ok=True)
    db = os.path.join(tempfile.mkdtemp(prefix="wa-shots-"), "mistakes.sqlite")
    seed(db)
    app(cmd="setTierTwo", enabled=True)
    app(cmd="setLog", enabled=True, path=db)
    app(cmd="resetIgnore")
    try:
        # 1 + 2. TextEdit: underlines, then the card for one of them.
        osascript('tell application "TextEdit"\nactivate\nmake new document\nend tell')
        osascript(f'tell application "TextEdit" to set bounds of front window to {{{", ".join(map(str, TEXTEDIT))}}}')
        osascript(f'tell application "TextEdit" to set text of front document to "{SENTENCE[:-1]}"')
        osascript('tell application "TextEdit" to set size of text of front document to 32')
        # Never type until TextEdit's text box has the focus: keys would land in whatever app is in front.
        osascript('tell application "TextEdit" to activate')
        s = until(state, lambda s: s.get("app") == "com.apple.TextEdit" and s.get("role") == "AXTextArea"
                  and s.get("text") == SENTENCE[:-1], 10)
        if s.get("text") != SENTENCE[:-1]:
            sys.exit(f"TextEdit never got the focus (app={s.get('app')!r}); nothing typed")
        key(125, "command")
        if state().get("app") != "com.apple.TextEdit":
            sys.exit("TextEdit lost the focus; nothing typed")
        app(cmd="type", text=SENTENCE[-1])
        s = until(state, lambda s: s.get("text") == SENTENCE and {"recieve", "Is it work?"} <= {x["original"] for x in s["suggestions"]}, 30)
        print("found:", [(x["original"], x["source"]) for x in s["suggestions"]])
        osascript('tell application "TextEdit" to set size of text of front document to 32')  # the typed "?" too
        time.sleep(1.5)
        s = state()
        shot("1-underlines.png", *TEXTEDIT)
        word = next(x for x in s["suggestions"] if x["original"] == "recieve")
        x, y, w, h = word["rect"]
        app(cmd="click", x=x + w / 2, y=y + h - 1)
        until(state, lambda s: s["card"] == word["id"], 3)
        time.sleep(0.6)
        shot("2-word-card.png", *TEXTEDIT)
        click_first_fix()
        until(state, lambda s: s.get("text") == "I receive your mail. Is it work?", 5)

        # 3 + 4. The whole-sentence card, then the text with both fixes in.
        s = until(state, lambda s: any(x["original"] == "Is it work?" for x in s["suggestions"]), 30)
        whole = next(x for x in s["suggestions"] if x["original"] == "Is it work?")
        x, y, w, h = whole["rect"]
        app(cmd="click", x=x + w / 2, y=y + h - 1)
        until(state, lambda s: s["card"] == whole["id"], 3)
        time.sleep(0.6)
        shot("3-sentence-card.png", *TEXTEDIT)
        click_first_fix()
        until(state, lambda s: s.get("text") == "I receive your mail. Does it work?", 5)
        osascript('tell application "TextEdit" to set size of text of front document to 32')
        time.sleep(1.5)
        until(state, lambda s: not s["suggestions"], 10)
        time.sleep(0.5)
        shot("4-fixed.png", *TEXTEDIT)
        osascript('tell application "TextEdit" to close front document saving no')

        # 5-7. A terminal: the Writing window with underlines, fixed with ⌥⏎, pasted back with ⌘⏎. No mouse clicks.
        osascript('tell application "Terminal"\nactivate\ndo script "clear"\nend tell')
        time.sleep(1.5)
        key(49, "control", "option")
        until(lambda: app(cmd="compose"), lambda c: c["key"], 3)
        left, top, right, bottom = window_frame("WritingAssistant", "Writing window")
        key(53)  # Esc: hide it, then put the terminal behind where it opens
        until(lambda: app(cmd="compose"), lambda c: not c["visible"], 3)
        frame = (int(left) - 120, int(top) - 110, int(right) + 120, int(bottom) + 110)
        osascript(f'tell application "Terminal" to set bounds of front window to {{{", ".join(map(str, frame))}}}')
        time.sleep(0.5)
        app(cmd="compose", text="")
        key(49, "control", "option")
        if not until(lambda: app(cmd="compose"), lambda c: c["key"], 3)["key"]:
            sys.exit("Writing window didn't get the focus; nothing typed")
        app(cmd="type", text=DRAFT)
        s = until(state, lambda s: s.get("text") == DRAFT and "Plese" in {x["original"] for x in s["suggestions"]}
                  and any(x["original"].startswith("Is it work") for x in s["suggestions"]), 30)
        print("found:", [(x["original"], x["source"]) for x in s["suggestions"]])
        time.sleep(1)
        shot("5-writing-window.png", *frame)
        key(124, "command")  # line end, then back into "work"
        for _ in range(6):
            key(123)
        until(state, lambda s: s["atCaret"], 3)
        app(cmd="optionReturn")
        until(lambda: app(cmd="compose"), lambda c: "Is it work" not in c["text"], 5)
        key(123, "command")  # line start, then into "Plese"
        for _ in range(2):
            key(124)
        until(state, lambda s: s["atCaret"], 3)
        app(cmd="optionReturn")
        fixed = until(lambda: app(cmd="compose"), lambda c: c["text"].startswith("Please"), 5)["text"]
        until(state, lambda s: not s["suggestions"], 10)
        time.sleep(1)
        shot("6-writing-window-fixed.png", *frame)
        key(36, "command")  # ⌘⏎ paste back
        until(lambda: osascript('tell application "Terminal" to get contents of selected tab of front window'),
              lambda t: fixed in t, 5)
        time.sleep(0.8)
        shot("7-pasted-in-terminal.png", *frame)
        key(32, "control")  # ⌃U clears the prompt line, nothing is run
        osascript('tell application "Terminal" to close front window')

        # 8. "My mistakes": the sample log plus the four fixes just made, newest first.
        osascript('tell application "System Events" to tell process "WritingAssistant"\n'
                  'click menu bar item 1 of menu bar 2\ndelay 0.5\n'
                  'click menu item "My mistakes…" of menu 1 of menu bar item 1 of menu bar 2\nend tell')
        until(lambda: app(cmd="mistakes"), lambda w: w["visible"], 3)
        time.sleep(0.8)
        shot("8-my-mistakes.png", *map(int, window_frame("WritingAssistant", "My mistakes")))
    finally:
        app(cmd="mistakes", close=True)
        app(cmd="compose", text="", close=True)
        app(cmd="setLog", enabled=True, path="")
    print("idle now:", idle_seconds(), "s")


if __name__ == "__main__":
    main()
