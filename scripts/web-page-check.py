#!/usr/bin/env python3
"""Read-only web pages are not checked; web fields and Mail's body still are (decision 0021, PLAN.md).

Chrome: a local test page (plain text, a <textarea>, a contenteditable block) in a new window, closed after.
Mail: a new compose window, closed without saving. Fixes go nowhere (nothing is accepted). Takes the screen ~15 s.
Usage: scripts/web-page-check.py
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_helpers import app, state  # noqa: E402

PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "web-page.html")
BOUNDS = (100, 100, 1100, 900)
results = []


def osascript(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))


def until(fetch, predicate, timeout):
    end = time.monotonic() + timeout
    value = fetch()
    while not predicate(value) and time.monotonic() < end:
        time.sleep(0.2)
        value = fetch()
    return value


def words(s):
    return [x["original"] for x in s.get("suggestions", [])]


def click_and_read(x, y, wanted_app, checked):
    app(cmd="click", x=x, y=y)
    return until(state, lambda s: s.get("app") == wanted_app and (("recieve" in words(s)) == checked), 4)


def main():
    osascript('tell application "Google Chrome"\nmake new window\n'
              f'set URL of active tab of front window to "file://{PAGE}"\n'
              f'set bounds of front window to {{{", ".join(map(str, BOUNDS))}}}\nactivate\nend tell')
    time.sleep(2.5)
    top = BOUNDS[1] + 87  # the page starts under Chrome's toolbar
    try:
        s = click_and_read(500, top + 100, "com.google.Chrome", checked=False)
        check("1. plain page text → not checked", s.get("app") == "com.google.Chrome" and not s.get("role")
              and not s.get("suggestions") and not s.get("card"), f"role={s.get('role')!r}, words={words(s)}")
        s = click_and_read(500, top + 320, "com.google.Chrome", checked=True)
        check("2. <textarea> → checked", s.get("role") == "AXTextArea" and "recieve" in words(s), f"role={s.get('role')!r}, words={words(s)}")
        s = click_and_read(500, top + 540, "com.google.Chrome", checked=True)
        check("3. contenteditable → checked", s.get("role") == "AXTextArea" and "recieve" in words(s), f"role={s.get('role')!r}, words={words(s)}")
    finally:
        osascript('tell application "Google Chrome" to close front window')

    before = osascript('tell application "Mail" to get name of every window')
    osascript('tell application "Mail"\nactivate\n'
              'make new outgoing message with properties {visible:true, content:"Mail body with recieve here."}\nend tell')
    time.sleep(3)
    try:
        out = osascript('tell application "System Events" to tell process "Mail" to get {position, size} of front window')
        x, y, w, h = (float(n) for n in out.replace(" ", "").split(","))
        s = click_and_read(x + w / 2, y + h * 0.75, "com.apple.mail", checked=True)
        check("4. Mail compose body → still checked", s.get("role") == "AXWebArea" and "recieve" in words(s),
              f"role={s.get('role')!r}, words={words(s)}")
    finally:
        osascript('tell application "Mail" to close front window saving no')
        time.sleep(1)
        after = osascript('tell application "Mail" to get name of every window')
        if after != before:
            print("NOTE Mail windows before:", before, "after:", after)
    print(f"{sum(results)}/{len(results)} passed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
