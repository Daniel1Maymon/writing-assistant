#!/usr/bin/env python3
"""M4 integration checks (PLAN.md → M4): real OpenRouter calls through the installed debug app.

Uses FixtureApp as the text field. The app posts real ⌥⏎ and clicks itself (debug socket), as in
real-app-check.py. Costs a few hundredths of a cent per run. Needs: scripts/install.sh run, a key in .env.
Usage: scripts/m4-check.py
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m3_helpers import FIXTURE_ID, app, card_buttons, fixture, launch_fixture, restart_app, state  # noqa: E402

results = []


def check(number, name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {number}. {name}" + (f"  ({detail})" if detail else ""))


def wait_for(predicate, timeout):
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            last = state()
        except OSError:
            last = None
        if last and last.get("app") == FIXTURE_ID and predicate(last):
            return last, True
        time.sleep(0.05)
    return last, False


def answered(before):
    """True once tier 2 has answered (or served from cache) more often than `before`."""
    return lambda s: answers(s) > before


def answers(s):
    c = (s.get("tier2") or {}).get("counters") or {}
    return c.get("answers", 0) + c.get("cacheHits", 0)


def focus_text():
    """After a restart the app can miss the first focus event: refocus until it watches the fixture's text view."""
    for _ in range(20):
        fixture(cmd="focus", field="text")
        _, ok = wait_for(lambda s: s.get("role") == "AXTextArea", 0.5)
        if ok:
            return
    raise SystemExit("the app never saw the fixture's text view")


def show(text, caret=None):
    before = answers(state())
    fixture(cmd="set", field="text", text=text)
    if caret is not None:
        fixture(cmd="select", field="text", location=caret)
    return before


def rows(db):
    if not os.path.exists(db):
        return []
    con = sqlite3.connect(db)
    con.row_factory = sqlite3.Row
    out = [dict(r) for r in con.execute("SELECT * FROM mistakes ORDER BY id")]
    con.close()
    return out


def main():
    started = time.time()
    work = tempfile.mkdtemp(prefix="wa-m4-")
    db = os.path.join(work, "mistakes.sqlite")
    restart_app()  # empty answer cache: the first checks make real requests
    launch_fixture()
    app(cmd="resetIgnore")
    app(cmd="setTierTwo", enabled=True)
    app(cmd="setLog", enabled=True, path=db)
    focus_text()

    # 1. "She dont know." → the model's "doesn't" first, Harper's "don't" after (decision 0008).
    before = show("She dont know.")
    s, ok = wait_for(lambda s: answers(s) > before and any(x["original"] == "dont" and x["source"] == "llm"
                                                           for x in s["suggestions"]), 20)
    dont = next((x for x in s["suggestions"] if x["original"] == "dont"), {}) if s else {}
    reps = dont.get("replacements", [])
    check(1, "She dont know. → doesn't first, don't after", ok and reps[:1] == ["doesn't"] and "don't" in reps[1:],
          f"replacements={reps}, tier2={s.get('tier2') if s else None}")

    # 2. Caret inside "dont" + real ⌥⏎ → "She doesn't know.", one log row from the model.
    fixture(cmd="select", field="text", location=6)
    wait_for(lambda s: s["atCaret"] == dont.get("id"), 2)
    app(cmd="optionReturn")
    s, ok = wait_for(lambda s: s.get("text") == "She doesn't know.", 3)
    log = rows(db)
    row = log[-1] if log else {}
    check(2, "⌥⏎ → She doesn't know., logged as a model fix", ok and len(log) == 1 and row.get("replacement") == "doesn't"
          and row.get("source") == "llm" and row.get("sentence") == "She dont know.",
          f"text={s.get('text')!r}, rows={[(r['original'], r['replacement'], r['category'], r['source']) for r in log]}")

    # 3. "Is it work?" → one red sentence-wide suggestion.
    before = show("Is it work?")
    s, ok = wait_for(lambda s: answers(s) > before and any(x["rewrite"] for x in s["suggestions"]), 20)
    rewrite = next((x for x in s["suggestions"] if x["rewrite"]), {}) if s else {}
    check(3, "Is it work? → sentence-wide fix", ok and rewrite.get("rewrite") == "fix"
          and rewrite.get("replacements") == ["Does it work?"] and rewrite.get("range") == [0, 11],
          f"{({k: rewrite.get(k) for k in ('rewrite', 'replacements', 'range', 'message')})}")

    # 4. The overlay draws it (rendered to a PNG, since screen capture is blocked).
    shots = app(cmd="snapshot", dir=work).get("files", [])
    check(4, "overlay drawn", any(f.endswith("overlay.png") for f in shots), f"{shots}")

    # 5. A real click on the dashed line opens the card; clicking its fix replaces the whole sentence.
    if rewrite:
        x, y, w, h = rewrite["rect"]
        app(cmd="click", x=x + w / 2, y=y + h - 1)
    s, opened = wait_for(lambda s: s["card"] == rewrite.get("id"), 2)
    shots = app(cmd="snapshot", dir=work).get("files", [])
    buttons = card_buttons() if opened else []
    if buttons:
        bx, by, bw, bh = buttons[0]
        app(cmd="click", x=bx + bw / 2, y=by + bh / 2)
    s, fixed = wait_for(lambda s: s.get("text") == "Does it work?", 3)
    log = rows(db)
    row = log[-1] if log else {}
    check(5, "click line → card → click fix → Does it work?", opened and fixed and len(log) == 2
          and row.get("category") == "grammar" and row.get("original") == "Is it work?" and row.get("source") == "llm",
          f"card opened={opened}, text={s.get('text')!r}, last row={({k: row.get(k) for k in ('original', 'replacement', 'category')})}")
    s = state()
    check(6, "after the rewrite, no old suggestions remain", not any(x["original"] == "Is it work?" for x in s["suggestions"]),
          f"{[x['original'] for x in s['suggestions']]}")

    # 7. A clean sentence → answered, nothing shown.
    before = show("We went to the beach and it was great.")
    s, ok = wait_for(answered(before), 20)
    check(7, "clean sentence → no suggestions", ok and not s["suggestions"], f"{[x['original'] for x in s['suggestions']]}")

    # 8. Unfinished sentence with the caret at its end → no request; the period → one request.
    s0 = state()
    requests = s0["tier2"]["counters"]["requests"]
    show("My brother is older from me in three years")
    time.sleep(2.5)
    idle = state()["tier2"]["counters"]["requests"] - requests
    before = show("My brother is older from me in three years.")
    s, ok = wait_for(answered(before), 20)
    check(8, "no request while unfinished, one after the period", idle == 0 and ok
          and s["tier2"]["counters"]["requests"] - requests == 1,
          f"while typing={idle}, total={s['tier2']['counters']['requests'] - requests}, "
          f"found={[(x['original'], x['replacements']) for x in s['suggestions']]}")

    # 9. Changing the sentence mid-request cancels it; the old answer never shows.
    cancelled = state()["tier2"]["counters"]["cancelled"]
    fixture(cmd="set", field="text", text="Yesterday I have seen a nice movie.")
    time.sleep(0.15)
    fixture(cmd="set", field="text", text="Yesterday I have seen a nice movi")
    time.sleep(4)
    s = state()
    check(9, "sentence changed mid-request → cancelled, nothing stale", s["tier2"]["counters"]["cancelled"] > cancelled
          and not any(x["source"] == "llm" for x in s["suggestions"]),
          f"cancelled {cancelled} → {s['tier2']['counters']['cancelled']}, shown={[x['original'] for x in s['suggestions']]}")

    # 10. Keychain save / read / delete works for the app (dummy item only).
    reply = app(cmd="keychainSelfTest")
    check(10, "keychain save/read/delete", reply.get("ok"), f"{reply}")

    # 11. The app log never contains the text.
    minutes = int((time.time() - started) / 60) + 2
    out = subprocess.run(["log", "show", "--last", f"{minutes}m", "--info", "--predicate",
                          'subsystem == "com.danielmaymon.WritingAssistant"'], capture_output=True, text=True).stdout
    leaks = [w for w in ("dont", "brother", "beach", "Is it work", "movie") if w in out]
    tier2_lines = sum("tier2:" in line for line in out.splitlines())
    check(11, "app log has tier-2 lines but none of the text", tier2_lines > 0 and not leaks,
          f"{tier2_lines} tier-2 lines, leaks={leaks}")

    s = state()
    print(f"\nTier 2 today: {s['tier2']['requestsToday']} requests, ${s['tier2']['costToday']:.5f}; snapshots in {work}")
    app(cmd="setLog", enabled=True, path="")
    app(cmd="resetIgnore")
    subprocess.run(["pkill", "-x", "FixtureApp"])
    print(f"\n{sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
