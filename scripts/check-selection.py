#!/usr/bin/env python3
"""Check on demand (decision 0019, PLAN.md → M5), through the installed app with real key presses and clicks.

TextEdit (a new, unsaved document) and the Writing window. Fixes go to a temp mistake log, never the real one.
Calls OpenRouter for real (a few on-demand checks, a fraction of a cent). Takes over the screen for ~1.5 min.
Usage: scripts/check-selection.py
"""
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_helpers import app, state  # noqa: E402

LINES = ["I think it work on your machine.", "She dont like the rain.", "The meeting is at noon tomorrow."]
TEXTEDIT = "com.apple.TextEdit"
results = []


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


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))


def manual():
    return app(cmd="manual")


def ask_check():
    until(manual, lambda m: not m["visible"], 2)
    key(5, "control", "option")  # ⌃⌥G
    return until(manual, lambda m: m["phase"] in ("result", "failed"), 30)


def lines():
    return state().get("text", "").split("\n")


def rows(db):
    con = sqlite3.connect(db)
    try:
        return con.execute("SELECT original, replacement, category, appName FROM mistakes").fetchall()
    except sqlite3.OperationalError:
        return []
    finally:
        con.close()


def click_choice(text):
    """Clicks the card button for `text`. The card's buttons, read through Accessibility, are in the choices' order."""
    index = next((i for i, c in enumerate(manual()["choices"]) if c["text"] == text), None)
    script = ('const p = Application("System Events").processes.byName("WritingAssistant"); let out = [];'
              'p.windows().forEach(w => w.entireContents().forEach(e => { try { if (e.role() === "AXButton")'
              ' out.push([e.position(), e.size()].join("|")) } catch (x) {} })); out.join("\\n")')
    out = subprocess.run(["osascript", "-l", "JavaScript", "-e", script], capture_output=True, text=True).stdout
    buttons = [line.split("|") for line in out.splitlines() if line.count("|") == 1]
    if index is None or index >= len(buttons):
        return False
    x, y = map(float, buttons[index][0].split(","))
    w, h = map(float, buttons[index][1].split(","))
    app(cmd="click", x=x + w / 2, y=y + h / 2)
    return True


def select_line(n):
    key(126, "command")  # document start
    for _ in range(n):
        key(125)
    key(124, "command", "shift")  # select to line end
    until(state, lambda s: s.get("selection", [0, 0])[1] > 0, 3)


def main():
    db = os.path.join(tempfile.mkdtemp(prefix="wa-manual-"), "mistakes.sqlite")
    app(cmd="setLog", enabled=True, path=db)
    app(cmd="setTierTwo", enabled=True)
    s = state()
    cap = s.get("tier2", {}).get("capReached")
    print("tier 2 at the daily cap before starting:", cap)
    try:
        osascript('tell application "TextEdit"\nactivate\nmake new document\nend tell')
        osascript('tell application "TextEdit" to set bounds of front window to {160, 140, 900, 520}')
        text = "\\n".join(LINES)
        osascript(f'tell application "TextEdit" to set text of front document to "{text}"')
        osascript('tell application "TextEdit" to activate')
        s = until(state, lambda s: s.get("app") == TEXTEDIT and s.get("role") == "AXTextArea"
                  and s.get("text") == "\n".join(LINES), 10)
        if s.get("text") != "\n".join(LINES):
            sys.exit(f"TextEdit never got the focus (app={s.get('app')!r}); nothing typed")

        # 1. Select a sentence with a mistake, ⌃⌥G → "Checking…", then the correction and alternatives.
        select_line(0)
        key(5, "control", "option")
        first = until(manual, lambda m: m["phase"] != "hidden", 3)
        check("1a. ⌃⌥G opens the card with Checking…", first["visible"] and first["phase"] in ("checking", "result"),
              first["phase"])
        m = until(manual, lambda m: m["phase"] in ("result", "failed"), 30)
        choices = m["choices"]
        check("1b. corrected + 1-3 alternatives", m["phase"] == "result" and choices and choices[0]["correction"]
              and 1 <= len(choices) - 1 <= 3, str([c["text"] for c in choices]))
        if cap:
            check("10. answers while tier 2 is at its daily cap", m["phase"] == "result")

        # 2. Click the correction → it replaces the selection; one mistake-log row.
        corrected = choices[0]["text"] if choices else ""
        clicked = click_choice(corrected)
        now = until(lines, lambda l: l[0] == corrected, 5)
        logged = rows(db)
        check("2. clicking the correction replaces the selection", clicked and now[0] == corrected, now[0])
        check("2b. one grammar row in the mistake log", len(logged) == 1 and logged[0][2] == "grammar"
              and logged[0][3] == "TextEdit", str(logged))

        # 3. Select again → the button shows after the selection; clicking it opens the same card.
        select_line(0)
        m = until(manual, lambda m: "button" in m, 3)
        button = m.get("button")
        check("3a. the button shows after the selection", button is not None, str(button))
        if button:
            x, y, w, h = button
            app(cmd="click", x=x + w / 2, y=y + h / 2)
            m = until(manual, lambda m: m["phase"] in ("result", "failed"), 30)
            check("3b. clicking the button opens the card", m["phase"] == "result", m["phase"])

            # 4. Click an alternative → replaces the selection, no new mistake-log row.
            alternative = next((c["text"] for c in m["choices"] if not c["correction"]), None)
            clicked = alternative is not None and click_choice(alternative)
            now = until(lines, lambda l: l[0] == alternative, 5)
            check("4a. clicking an alternative replaces the selection", clicked and now[0] == alternative, now[0])
            logged = rows(db)
            check("4b. the alternative is logged as clarity", len(logged) == 2 and logged[1][2] == "clarity"
                  and logged[1][1] == alternative, str(logged))

        # 5. No selection: the caret's sentence is checked. Then Esc closes the card and doesn't reach TextEdit.
        key(126, "command")
        key(125)
        key(124)
        before = state().get("text")
        m = ask_check()
        check("5. no selection → the caret's sentence", m["phase"] == "result" and m["choices"]
              and "doesn't" in m["choices"][0]["text"], str([c["text"] for c in m["choices"]]))
        key(53)  # Esc
        m = until(manual, lambda m: not m["visible"], 2)
        time.sleep(0.5)
        check("7a. Esc closes the card, the text is unchanged", not m["visible"] and state().get("text") == before)

        # 6. A correct sentence → "Looks good" plus alternatives; ⌥⏎ takes the first choice.
        select_line(2)
        m = ask_check()
        check("6. a correct sentence → Looks good", m["phase"] == "result" and m.get("looksGood") is True
              and not any(c["correction"] for c in m["choices"]), str(m.get("choices")))
        first_choice = m["choices"][0]["text"] if m["choices"] else None
        app(cmd="optionReturn")
        now = until(lines, lambda l: l[2] == first_choice, 5)
        check("7b. ⌥⏎ takes the first choice", first_choice is not None and now[2] == first_choice, now[2])
        logged = rows(db)
        check("7c. the ⌥⏎ choice is logged", len(logged) == 3 and logged[2][1] == first_choice, str(logged))

        # 8. Clearing the selection hides the button.
        select_line(1)
        shown = "button" in until(manual, lambda m: "button" in m, 3)
        key(124)  # → collapses the selection
        gone = "button" not in until(manual, lambda m: "button" not in m, 2)
        check("8. the button hides when the selection is cleared", shown and gone)
        osascript('tell application "TextEdit" to close front document saving no')

        # 9. The Writing window.
        key(49, "control", "option")  # ⌃⌥Space
        until(lambda: app(cmd="compose"), lambda c: c["key"], 3)
        app(cmd="compose", text="Is it work on your side?")
        time.sleep(0.5)
        key(0, "command")  # ⌘A
        m = ask_check()
        check("9a. Writing window: ⌃⌥G checks the selection", m["phase"] == "result" and m["choices"],
              str([c["text"] for c in m["choices"]]))
        key(53)
        c = app(cmd="compose")
        check("9b. Esc closes only the card, the Writing window stays", not manual()["visible"] and c["visible"])
    finally:
        app(cmd="compose", text="", close=True)
        app(cmd="setLog", enabled=True, path="")
    s = state().get("tier2", {})
    print("requests today:", s.get("requestsToday"), "cost today: $%.4f" % (s.get("costToday") or 0),
          "on-demand:", s.get("counters", {}).get("manual"))
    print(f"{sum(results)}/{len(results)} passed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
