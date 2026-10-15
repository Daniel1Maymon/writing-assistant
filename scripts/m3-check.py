#!/usr/bin/env python3
"""M3 integration checks (PLAN.md → M3, decision 0006).

Clicks and keys can't be sent from the shell, so this calls the same accept / dismiss / ignore code the
card buttons call, through the debug socket. Fixes are written into FixtureApp through Accessibility
(or paste), exactly as in a real app. Needs: scripts/install.sh already run, Accessibility granted.
Usage: scripts/m3-check.py
"""
import json
import os
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/WritingAssistant-local")
FIXTURE = os.path.join(DERIVED, "Build/Products/Debug/FixtureApp.app")
FIXTURE_ID = "com.danielmaymon.WritingAssistantFixture"
APP = "/Applications/WritingAssistant.app"

results = []


def ask(path, line):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(path)
    s.sendall(line.encode() + b"\n")
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    return json.loads(data)


def state():
    return ask("/tmp/wa-debug.sock", "state")


def app(**command):
    return ask("/tmp/wa-debug.sock", json.dumps(command))


def fixture(**command):
    reply = ask("/tmp/wa-fixture.sock", json.dumps(command))
    assert reply.get("ok"), f"fixture refused {command}"
    return reply


def text():
    return fixture(cmd="get", field="text")["text"]


def wait_for(predicate, timeout):
    """Polls the app state until predicate(state) is truthy. Returns (state, seconds) or (last state, None)."""
    start = time.monotonic()
    last = None
    while time.monotonic() - start < timeout:
        try:
            last = state()
        except OSError:
            last = None
        if last and last.get("app") == FIXTURE_ID and predicate(last):
            return last, time.monotonic() - start
        time.sleep(0.02)
    return last, None


def flagged(word):
    return lambda s: any(x["original"] == word for x in s["suggestions"])


def find(s, word):
    return next(x for x in s["suggestions"] if x["original"] == word)


def show(text_value):
    """Set the fixture text and wait until the app has checked it."""
    done = state()["counters"]["completedChecks"]
    fixture(cmd="set", field="text", text=text_value)
    s, _ = wait_for(lambda s: s["counters"]["completedChecks"] > done, 3.0)
    return s


def check(number, name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {number}. {name}" + (f"  ({detail})" if detail else ""))


def rows(db):
    if not os.path.exists(db):
        return []
    con = sqlite3.connect(db)
    con.row_factory = sqlite3.Row
    out = [dict(r) for r in con.execute("SELECT * FROM mistakes ORDER BY id")]
    con.close()
    return out


def pasteboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def launch_fixture():
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcodebuild", "-project", os.path.join(ROOT, "WritingAssistant.xcodeproj"), "-scheme", "FixtureApp",
                    "-configuration", "Debug", "-derivedDataPath", DERIVED, "-quiet", "build"],
                   check=True, env=env, stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-x", "FixtureApp"])
    time.sleep(0.5)
    subprocess.run(["open", "-n", FIXTURE], check=True)
    for _ in range(100):
        if os.path.exists("/tmp/wa-fixture.sock"):
            try:
                fixture(cmd="focus", field="text")
                return
            except (OSError, AssertionError):
                pass
        time.sleep(0.1)


def restart_app():
    subprocess.run(["pkill", "-x", "WritingAssistant"])
    time.sleep(1.0)
    subprocess.run(["open", APP], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            state()
            return
        except OSError:
            time.sleep(0.1)


def main():
    work = tempfile.mkdtemp(prefix="wa-m3-")
    db = os.path.join(work, "mistakes.sqlite")
    launch_fixture()
    app(cmd="resetIgnore")
    app(cmd="setTierTwo", enabled=False)  # no model calls: these checks are about tier 1 and the card
    app(cmd="setLog", enabled=True, path=db)

    # 1. Accept through Accessibility.
    sentence = "I recieve the mail."
    show(sentence)
    s, _ = wait_for(flagged("recieve"), 2.0)
    reply = app(cmd="accept", id=find(s, "recieve")["id"])
    fixed = text()
    s, gone = wait_for(lambda s: not flagged("recieve")(s), 2.0)
    check(1, "accept recieve → receive (AX path)", reply["result"] == "accessibility" and fixed == "I receive the mail."
          and gone is not None, f"result={reply['result']}, text={fixed!r}")

    # 8a. That accept wrote exactly one row, with the sentence as it was before the fix.
    log = rows(db)
    row = log[-1] if log else {}
    check("8a", "accept → one mistake-log row with the sentence before the fix", len(log) == 1
          and row.get("sentence") == sentence and row.get("original") == "recieve" and row.get("replacement") == "receive"
          and row.get("category") == "spelling" and row.get("appBundleId") == FIXTURE_ID,
          f"{len(log)} row(s), {({k: row.get(k) for k in ('sentence', 'original', 'replacement', 'category', 'appBundleId')})}")

    # 2. Undo in the fixture brings the original back.
    fixture(cmd="undo", field="text")
    after = text()
    check(2, "undo → original text back", after == sentence, f"text={after!r}")

    # 3. Whole-sentence replacement (decision 0007); caret right after the new sentence.
    show("Is it work? Yes it is.")
    reply = app(cmd="replaceSpan", location=0, length=11, original="Is it work?", replacement="Does it work?")
    got = fixture(cmd="get", field="text")
    check(3, "whole-sentence replacement", reply["result"] == "accessibility" and got["text"] == "Does it work? Yes it is."
          and got["selection"] == [13, 0], f"result={reply['result']}, text={got['text']!r}, caret={got['selection']}")

    # 4. Paste fallback; the user's clipboard is the same afterwards.
    marker = f"clipboard-{time.time()}"
    subprocess.run(["pbcopy"], input=marker, text=True, check=True)
    show(sentence)
    s, _ = wait_for(flagged("recieve"), 2.0)
    reply = app(cmd="accept", id=find(s, "recieve")["id"], paste=True)
    fixed = text()
    kept = pasteboard()
    check(4, "paste fallback, clipboard restored", reply["result"] == "paste" and fixed == "I receive the mail." and kept == marker,
          f"result={reply['result']}, text={fixed!r}, clipboard kept={kept == marker}")

    rows_before = len(rows(db))

    # 5. Dismiss, then type more: the dismissed item stays gone.
    show("I recieve teh mail.")
    s, _ = wait_for(lambda s: flagged("recieve")(s) and flagged("teh")(s), 2.0)
    app(cmd="dismiss", id=find(s, "recieve")["id"])
    fixture(cmd="replace", field="text", **{"from": "mail.", "to": "mail. It is here."})
    done = s["counters"]["completedChecks"]
    s, took = wait_for(lambda s: s["counters"]["completedChecks"] > done and flagged("teh")(s), 3.0)
    check(5, "dismiss → stays gone after more typing", took is not None and not flagged("recieve")(s),
          f"now {[x['original'] for x in s['suggestions']]}")

    # 6. Add to dictionary: never flagged again, also after a restart.
    s = show("Zorblax is teh name.")
    s, _ = wait_for(flagged("Zorblax"), 2.0)
    app(cmd="addWord", id=find(s, "Zorblax")["id"])
    show("I saw zorblax and teh cat.")
    s, _ = wait_for(flagged("teh"), 2.0)
    before_restart = not flagged("zorblax")(s)
    restart_app()
    app(cmd="setTierTwo", enabled=False)
    app(cmd="setLog", enabled=True, path=db)
    fixture(cmd="focus", field="text")
    fixture(cmd="set", field="text", text="Zorblax came with teh dog.")
    s, took = wait_for(flagged("teh"), 5.0)
    after_restart = took is not None and not flagged("Zorblax")(s)
    check(6, "add to dictionary → not flagged, also after restart", before_restart and after_restart,
          f"before restart ok={before_restart}, after restart ok={after_restart}")

    # 7. Ignore rule: nothing with that rule id anywhere.
    show("I ate a apple. You ate a orange.")
    s, _ = wait_for(lambda s: sum(x["original"] == "a" for x in s["suggestions"]) >= 2, 2.0)
    rule = find(s, "a")["ruleId"]
    app(cmd="ignoreRule", id=find(s, "a")["id"])
    s, _ = wait_for(lambda s: True, 1.0)
    left = [x for x in s["suggestions"] if x["ruleId"] == rule]
    check(7, "ignore rule → no suggestion with that rule", bool(rule) and not left, f"rule={rule}, left={len(left)}")

    # 8b. Dismiss / dictionary / ignore wrote nothing.
    check("8b", "dismiss / dictionary / ignore → no rows", len(rows(db)) == rows_before, f"{len(rows(db)) - rows_before} new")

    # 8c. Log turned off → fix applied, no row.
    app(cmd="setLog", enabled=False)
    show(sentence)
    s, _ = wait_for(flagged("recieve"), 2.0)
    reply = app(cmd="accept", id=find(s, "recieve")["id"])
    check("8c", "log off → fix applied, no row", reply["result"] == "accessibility" and len(rows(db)) == rows_before,
          f"result={reply['result']}, {len(rows(db)) - rows_before} new")
    app(cmd="setLog", enabled=True)

    # 8d. Log file read-only → fix still applied, app still running.
    locked = os.path.join(work, "locked")
    os.mkdir(locked)
    open(os.path.join(locked, "mistakes.sqlite"), "w").close()
    os.chmod(os.path.join(locked, "mistakes.sqlite"), stat.S_IRUSR)
    os.chmod(locked, stat.S_IRUSR | stat.S_IXUSR)
    app(cmd="setLog", path=os.path.join(locked, "mistakes.sqlite"))
    failures = state()["counters"]["mistakeLogFailures"]
    show(sentence)
    s, _ = wait_for(flagged("recieve"), 2.0)
    reply = app(cmd="accept", id=find(s, "recieve")["id"])
    alive = subprocess.run(["pgrep", "-x", "WritingAssistant"], capture_output=True).returncode == 0
    s = state()
    check("8d", "read-only log → fix applied, app alive", reply["result"] == "accessibility" and text() == "I receive the mail."
          and alive and s["counters"]["mistakeLogFailures"] > failures,
          f"result={reply['result']}, alive={alive}, log failures {failures} → {s['counters']['mistakeLogFailures']}")
    os.chmod(locked, stat.S_IRWXU)

    # 9. Text changed under a stale suggestion → refused, field unchanged.
    show(sentence)
    s, _ = wait_for(flagged("recieve"), 2.0)
    stale = find(s, "recieve")
    fixture(cmd="set", field="text", text="I deceive the mail.")
    reply = app(cmd="replaceSpan", location=stale["range"][0], length=stale["range"][1], original="recieve",
                replacement="receive")
    after = text()
    check(9, "stale suggestion → refused, field unchanged", reply["result"] == "refused" and after == "I deceive the mail.",
          f"result={reply['result']}, text={after!r}")

    app(cmd="setLog", enabled=True, path="")
    app(cmd="resetIgnore")
    app(cmd="setTierTwo", enabled=True)
    subprocess.run(["pkill", "-x", "FixtureApp"])
    print(f"\n{sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
