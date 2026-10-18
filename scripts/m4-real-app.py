#!/usr/bin/env python3
"""M4 real-app check, automated (PLAN.md → M4): tier-2 fixes in TextEdit with real clicks and ⌥⏎.

Opens a new TextEdit document, waits for the model's answers, then accepts a word fix (⌥⏎) and a
sentence-wide fix (click the dashed line, click the card's fix). Closes the document without saving.
Makes two real OpenRouter calls. Needs: scripts/install.sh run, a key in .env.
Usage: scripts/m4-real-app.py
"""
import os
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_helpers import app, card_buttons, state  # noqa: E402

BUNDLE = "com.apple.TextEdit"
TEXT = "She dont know. Is it work?"  # the last character is typed as a real key press (decision 0014)
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))


def wait(predicate, timeout):
    end = time.monotonic() + timeout
    s = None
    while time.monotonic() < end:
        s = state()
        if s.get("app") == BUNDLE and predicate(s):
            return s, True
        time.sleep(0.05)
    return s, False


def find(s, pick):
    return next((x for x in s["suggestions"] if pick(x)), None)


def word(s):
    return find(s, lambda x: x["original"] == "dont" and x["source"] == "llm")


def sentence(s):
    return find(s, lambda x: x["rewrite"] == "fix")


def osascript(script):
    subprocess.run(["osascript", "-e", script], check=True, capture_output=True)


def main():
    app(cmd="setTierTwo", enabled=True)
    app(cmd="setLog", path=os.path.join(tempfile.mkdtemp(prefix="wa-m4-real-"), "mistakes.sqlite"))  # keep the real log clean
    osascript(f'tell application "TextEdit"\nactivate\nmake new document with properties {{text:"{TEXT[:-1]}"}}\nend tell')
    _, front = wait(lambda s: s.get("text") == TEXT[:-1], 5)
    if not front:  # never press keys into another app (a person may be using it)
        osascript('tell application "TextEdit" to close front document saving no')
        app(cmd="setLog", path="")
        raise SystemExit(f"TextEdit's document isn't focused (app={state().get('app')}); nothing typed")
    osascript('tell application "System Events" to key code 125 using command down')  # caret to the end
    app(cmd="type", text=TEXT[-1])
    try:
        s, ok = wait(lambda s: word(s) and sentence(s), 25)
        dont = word(s) if s else None
        check("model answers shown", ok, f"words={[(x['original'], x['replacements']) for x in (s or {}).get('suggestions', [])]}")
        check("dont → doesn't first", bool(dont) and dont["replacements"][:1] == ["doesn't"],
              f"{dont and dont['replacements']}")

        if dont:
            x, y, w, h = dont["rect"]
            app(cmd="click", x=x + w + 1.3, y=y + h / 2)  # caret at the end of the word
            wait(lambda s: s["atCaret"] == dont["id"], 1.5)
            app(cmd="optionReturn")
        s, ok = wait(lambda s: s.get("text", "").startswith("She doesn't know."), 3)
        check("⌥⏎ → She doesn't know.", ok, f"text={s.get('text')!r}")

        s, _ = wait(sentence, 5)
        rewrite = sentence(s)
        opened = False
        if rewrite:
            x, y, w, h = rewrite["rect"]
            app(cmd="click", x=x + w / 2, y=y + h - 1)
            s, opened = wait(lambda s: s["card"] == rewrite["id"], 2)
        buttons = card_buttons() if opened else []
        if buttons:
            bx, by, bw, bh = buttons[0]
            app(cmd="click", x=bx + bw / 2, y=by + bh / 2)
        s, ok = wait(lambda s: s.get("text", "") == "She doesn't know. Does it work?", 3)
        check("click dashed line → card → click fix → Does it work?", opened and ok,
              f"card opened={opened}, text={s.get('text')!r}")
    finally:
        osascript('tell application "TextEdit" to close front document saving no')
        app(cmd="setLog", path="")
    print(f"\n{sum(results)}/{len(results)} passed in TextEdit")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
