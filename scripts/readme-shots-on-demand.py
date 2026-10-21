#!/usr/bin/env python3
"""Takes the README screenshots for "check on demand" (decision 0019) through the installed app.

TextEdit: 9. a selected sentence with the button  10. the card with the correction and other ways to say it
11. the text after picking one. Fixes go to a temp mistake log. Makes one OpenRouter call.
Needs: scripts/install.sh run, Screen Recording allowed for the terminal. Takes over the screen for ~20 s.
Usage: scripts/readme-shots-on-demand.py   (writes docs/images/9-*.png … 11-*.png)
"""
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_helpers import ROOT, app, state  # noqa: E402

OUT = os.path.join(ROOT, "docs", "images")
SENTENCE = "I think it work on your machine."
TEXTEDIT = (160, 140, 860, 520)  # left, top, right, bottom (points, top-left origin)


def osascript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def key(code, *modifiers):
    using = f" using {{{', '.join(m + ' down' for m in modifiers)}}}" if modifiers else ""
    osascript(f'tell application "System Events" to key code {code}{using}')
    time.sleep(0.15)


def until(fetch, predicate, timeout):
    end = time.monotonic() + timeout
    value = fetch()
    while not predicate(value) and time.monotonic() < end:
        time.sleep(0.1)
        value = fetch()
    return value


def shot(name):
    left, top, right, bottom = TEXTEDIT
    path = os.path.join(OUT, name)
    subprocess.run(["screencapture", "-x", f"-R{left},{top},{right - left},{bottom - top}", path], check=True)
    print("saved", path)


def manual():
    return app(cmd="manual")


def click_choice(index):
    """Clicks the card's choice at `index`. The card's buttons, read through Accessibility, are in the choices' order."""
    script = ('const p = Application("System Events").processes.byName("WritingAssistant"); let out = [];'
              'p.windows().forEach(w => w.entireContents().forEach(e => { try { if (e.role() === "AXButton")'
              ' out.push([e.position(), e.size()].join("|")) } catch (x) {} })); out.join("\\n")')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True).stdout
    x, y = map(float, out.splitlines()[index].split("|")[0].split(","))
    w, h = map(float, out.splitlines()[index].split("|")[1].split(","))
    app(cmd="click", x=x + w / 2, y=y + h / 2)


def main():
    os.makedirs(OUT, exist_ok=True)
    app(cmd="setLog", enabled=True, path=os.path.join(tempfile.mkdtemp(prefix="wa-shots-"), "mistakes.sqlite"))
    app(cmd="setTierTwo", enabled=True)
    try:
        osascript('tell application "TextEdit"\nactivate\nmake new document\nend tell')
        osascript(f'tell application "TextEdit" to set bounds of front window to {{{", ".join(map(str, TEXTEDIT))}}}')
        osascript(f'tell application "TextEdit" to set text of front document to "{SENTENCE}"')
        osascript('tell application "TextEdit" to set size of text of front document to 24')
        osascript('tell application "TextEdit" to activate')
        s = until(state, lambda s: s.get("app") == "com.apple.TextEdit" and s.get("text") == SENTENCE, 10)
        if s.get("text") != SENTENCE:
            sys.exit(f"TextEdit never got the focus (app={s.get('app')!r})")
        key(126, "command")
        key(124, "command", "shift")  # select the line
        m = until(manual, lambda m: "button" in m, 3)
        if "button" not in m:
            sys.exit("no button after the selection")
        time.sleep(0.5)
        shot("9-selection-button.png")

        x, y, w, h = m["button"]
        app(cmd="click", x=x + w / 2, y=y + h / 2)
        m = until(manual, lambda m: m["phase"] in ("result", "failed"), 30)
        if m["phase"] != "result":
            sys.exit(f"the check failed: {m.get('message')}")
        print("choices:", [c["text"] for c in m["choices"]])
        time.sleep(0.6)
        shot("10-check-card.png")

        click_choice(0)
        until(state, lambda s: s.get("text") == m["choices"][0]["text"], 5)
        key(124)  # clear the selection
        time.sleep(1)
        shot("11-check-fixed.png")
        osascript('tell application "TextEdit" to close front document saving no')
    finally:
        app(cmd="setLog", enabled=True, path="")


if __name__ == "__main__":
    main()
