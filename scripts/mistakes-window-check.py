#!/usr/bin/env python3
""""My mistakes…" window check (PLAN.md → M5, decision 0015), through the installed app with a temp log.

Opens the window from the real menu, accepts a real ⌥⏎ fix in FixtureApp while it's open, types a search with
real key presses, then filters, deletes and exports through the debug socket. Never touches the real log.
Needs: scripts/install.sh run. Takes over the screen for ~20 s.
Usage: scripts/mistakes-window-check.py
"""
import csv
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_helpers import app, fixture, launch_fixture, state  # noqa: E402

results = []
SEED = [  # (createdAt, app, sentence, original, replacement, category)
    ("2026-10-01T09:00:00.000Z", "Mail", "They has a dog.", "has", "have", "grammar"),
    ("2026-10-02T09:00:00.000Z", "Notes", "I recieve mail.", "recieve", "receive", "spelling"),
    ("2026-10-03T09:00:00.000Z", "Mail", "She has two dog.", "dog", "dogs", "grammar"),
    ("2026-10-04T09:00:00.000Z", "Notes", "I recieve it.", "Recieve", "Receive", "spelling"),
]


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
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True)


def window():
    return app(cmd="mistakes")


def seed(db):
    con = sqlite3.connect(db)
    con.execute("""CREATE TABLE mistakes (id INTEGER PRIMARY KEY, createdAt TEXT NOT NULL, appBundleId TEXT NOT NULL,
                   appName TEXT NOT NULL, sentence TEXT NOT NULL, original TEXT NOT NULL, replacement TEXT NOT NULL,
                   category TEXT NOT NULL, message TEXT NOT NULL, ruleId TEXT, source TEXT NOT NULL)""")
    for at, name, sentence, original, replacement, category in SEED:
        con.execute("INSERT INTO mistakes (createdAt, appBundleId, appName, sentence, original, replacement, category,"
                    " message, source) VALUES (?, ?, ?, ?, ?, ?, ?, '', 'local')",
                    (at, "test." + name, name, sentence, original, replacement, category))
    con.commit()
    con.close()


def main():
    work = tempfile.mkdtemp(prefix="wa-mistakes-")
    db = os.path.join(work, "mistakes.sqlite")
    seed(db)
    app(cmd="setLog", enabled=True, path=db)
    app(cmd="resetIgnore")
    try:
        # 1. The real menu item opens the window, newest first.
        osascript('tell application "System Events" to tell process "WritingAssistant"\n'
                  'click menu bar item 1 of menu bar 2\n'
                  'delay 0.5\n'
                  'click menu item "My mistakes…" of menu 1 of menu bar item 1 of menu bar 2\nend tell')
        w = until(window, lambda w: w["visible"], 3)
        check(1, "menu → window shows the log newest first", w["visible"] and
              [r["original"] for r in w["rows"]] == ["Recieve", "dog", "recieve", "has"], f"{[r['original'] for r in w['rows']]}")
        shot = app(cmd="mistakes", snapshot=work).get("snapshot")
        check(2, "window drawn", bool(shot), f"{shot}")

        # 3. A real ⌥⏎ fix in FixtureApp, with the window open, appears at the top without reopening.
        launch_fixture()
        fixture(cmd="set", field="text", text="I like teh cat")
        fixture(cmd="select", field="text", location=14)
        app(cmd="type", text=".")
        s = until(state, lambda s: any(x["original"] == "teh" for x in s["suggestions"]), 5)
        fixture(cmd="select", field="text", location=9)
        until(state, lambda s: s["atCaret"], 2)
        app(cmd="optionReturn")
        until(state, lambda s: s.get("text") == "I like the cat.", 3)
        w = until(window, lambda w: w["total"] == 5, 3)
        top = w["rows"][0] if w["rows"] else {}
        check(3, "accepted fix shows at the top while open", w["visible"] and w["total"] == 5
              and (top.get("original"), top.get("replacement")) == ("teh", "the"), f"total={w['total']}, top={top}")
        subprocess.run(["pkill", "-x", "FixtureApp"])

        # 4. Typing in the search box (real keys) narrows the list.
        osascript('tell application "System Events" to tell process "WritingAssistant"\n'
                  'click menu bar item 1 of menu bar 2\ndelay 0.5\n'
                  'click menu item "My mistakes…" of menu 1 of menu bar item 1 of menu bar 2\nend tell')
        time.sleep(0.5)
        out = osascript('tell application "System Events" to tell process "WritingAssistant" to get {position, size} of '
                        '(first UI element of (entire contents of window "My mistakes") whose role is "AXTextField")').stdout
        nums = [float(n) for n in out.replace("{", "").replace("}", "").split(",") if n.strip()]
        if len(nums) == 4:
            app(cmd="click", x=nums[0] + nums[2] / 2, y=nums[1] + nums[3] / 2)
            time.sleep(0.3)
            app(cmd="type", text="RECIEVE")
        w = until(window, lambda w: w["search"] == "RECIEVE", 3)
        check(4, "typed search → only matching rows", sorted(r["original"] for r in w["rows"]) == ["Recieve", "recieve"],
              f"search={w['search']!r}, rows={[r['original'] for r in w['rows']]}, field={nums}")

        # 5. Type filter, combined with no search.
        w = app(cmd="mistakes", search="", category="grammar")
        check(5, "type filter → grammar only", sorted(r["original"] for r in w["rows"]) == ["dog", "has"],
              f"{[r['original'] for r in w['rows']]}")

        # 6. Most repeated groups recieve/Recieve.
        w = app(cmd="mistakes", category="")
        first = w["repeated"][0] if w["repeated"] else {}
        check(6, "most repeated → recieve twice first", first == {"original": "recieve", "replacement": "receive", "count": 2},
              f"{first}")

        # 7. Delete one row → gone from the file too.
        gone = next(r["id"] for r in w["rows"] if r["original"] == "has")
        w = app(cmd="mistakes", delete=[gone])
        con = sqlite3.connect(db)
        left = [r[0] for r in con.execute("SELECT original FROM mistakes ORDER BY id")]
        con.close()
        check(7, "delete one → removed from window and file", w["total"] == 4 and "has" not in left, f"file={left}")

        # 8. Export CSV: header + every row.
        path = os.path.join(work, "export.csv")
        w = app(cmd="mistakes", export=path)
        rows = list(csv.reader(open(path, newline=""))) if w.get("exported") else []
        check(8, "Export CSV → header + 4 rows", len(rows) == 5 and rows[0][0] == "createdAt"
              and rows[-1][4] == "teh", f"{len(rows)} lines")
    finally:
        app(cmd="mistakes", search="", category="", close=True)
        app(cmd="setLog", enabled=True, path="")
        subprocess.run(["pkill", "-x", "FixtureApp"])
    print(f"\n{sum(results)}/{len(results)} passed; files in {work}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
