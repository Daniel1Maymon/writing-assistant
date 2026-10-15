#!/usr/bin/env python3
"""M2 integration checks (PLAN.md → M2, decision 0006).

Drives FixtureApp over /tmp/wa-fixture.sock and reads the installed debug app's state from
/tmp/wa-debug.sock. Needs: scripts/install.sh already run, Accessibility granted.
Usage: scripts/m2-check.py
"""
import json
import os
import socket
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/WritingAssistant-local")
FIXTURE = os.path.join(DERIVED, "Build/Products/Debug/FixtureApp.app")
FIXTURE_ID = "com.danielmaymon.WritingAssistantFixture"

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


def fixture(**command):
    reply = ask("/tmp/wa-fixture.sock", json.dumps(command))
    assert reply.get("ok"), f"fixture refused {command}"


def wait_for(predicate, timeout):
    """Polls the app state until predicate(state) is truthy. Returns (state, seconds) or (last state, None)."""
    start = time.monotonic()
    last = None
    while time.monotonic() - start < timeout:
        last = state()
        if last.get("app") == FIXTURE_ID and predicate(last):
            return last, time.monotonic() - start
        time.sleep(0.01)
    return last, None


def check(number, name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {number}. {name}" + (f"  ({detail})" if detail else ""))


def words(s):
    return sorted((x["original"], x["category"]) for x in s["suggestions"])


def inside(rect, window):
    x, y, w, h = rect
    wx, wy, ww, wh = window
    return w > 0 and h > 0 and wx <= x and x + w <= wx + ww and wy <= y and y + h <= wy + wh


def main():
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    subprocess.run(["xcodebuild", "-project", os.path.join(ROOT, "WritingAssistant.xcodeproj"), "-scheme", "FixtureApp",
                    "-configuration", "Debug", "-derivedDataPath", DERIVED, "-quiet", "build"],
                   check=True, env=env, stderr=subprocess.DEVNULL)
    ask("/tmp/wa-debug.sock", json.dumps({"cmd": "setTierTwo", "enabled": False}))  # tier 1 only, no model calls
    subprocess.run(["pkill", "-x", "FixtureApp"])
    time.sleep(0.5)
    subprocess.run(["open", "-n", FIXTURE], check=True)
    for _ in range(100):
        if os.path.exists("/tmp/wa-fixture.sock"):
            try:
                fixture(cmd="focus", field="text")
                break
            except (OSError, AssertionError):
                pass
        time.sleep(0.1)

    # 1. Spelling + grammar underlines appear within 1 s.
    fixture(cmd="set", field="text", text="I recieve the mail. I has a apple.")
    want = {("recieve", "spelling"), ("has", "grammar"), ("a", "grammar")}
    s, took = wait_for(lambda s: want <= set(words(s)), 1.0)
    rects_ok = took is not None and all(inside(x["rect"], s["window"]) for x in s["suggestions"])
    check(1, "spelling + grammar underlined within 1 s", took is not None and rects_ok,
          f"{took:.2f} s, {words(s)}" if took is not None else f"got {words(s) if s else None}")

    # 2. Editing sentence 2 keeps sentence 1's ids and re-checks one sentence.
    first_id = next(x["id"] for x in s["suggestions"] if x["original"] == "recieve")
    before = s["counters"]["sentencesChecked"]
    fixture(cmd="replace", field="text", **{"from": "I has a apple.", "to": "I have a apple."})
    s, took = wait_for(lambda s: not any(x["original"] == "has" for x in s["suggestions"])
                       and s["counters"]["sentencesChecked"] > before, 2.0)
    kept = any(x["id"] == first_id for x in s["suggestions"])
    rechecked = s["counters"]["sentencesChecked"] - before
    check(2, "edit sentence 2 → sentence 1 ids kept, 1 sentence re-checked", took is not None and kept and rechecked == 1,
          f"kept={kept}, re-checked={rechecked}" + ("" if kept else f", now {[(x['original'], x['id']) for x in s['suggestions']]}, wanted {first_id}"))

    # 3. Secure field: no checks, no suggestions.
    fixture(cmd="focus", field="secure")
    s, _ = wait_for(lambda s: s["secure"], 2.0)
    checks = s["counters"]["sentencesChecked"]
    fixture(cmd="set", field="secure", text="I recieve teh password")
    time.sleep(1.0)
    s = state()
    check(3, "secure field → zero checks", s["secure"] and s["counters"]["sentencesChecked"] == checks and not s["suggestions"],
          f"secure={s['secure']}, new checks={s['counters']['sentencesChecked'] - checks}, skips={s['counters']['secureSkips']}")

    # 4. Moving the window moves the rects within 100 ms.
    fixture(cmd="set", field="text", text="I recieve the mail.")
    s, _ = wait_for(lambda s: any(x["original"] == "recieve" for x in s["suggestions"]), 2.0)
    x0 = next(x["rect"][0] for x in s["suggestions"] if x["original"] == "recieve")
    start = time.monotonic()
    fixture(cmd="move", dx=120)
    s, took = wait_for(lambda s: any(x["original"] == "recieve" and abs(x["rect"][0] - (x0 + 120)) < 1
                                     for x in s["suggestions"]), 1.0)
    took = time.monotonic() - start if took is not None else None
    check(4, "window moved → rects follow within 100 ms", took is not None and took < 0.1,
          f"{took * 1000:.0f} ms" if took is not None else "rects didn't move")
    fixture(cmd="move", dx=-120)

    # 5. 2,000-word document, one-word edit → re-check under 100 ms.
    sentence = "The quick brown fox jumps over the lazy dog near the river bank today. "
    doc = "".join(sentence.replace("today", f"today {i}") for i in range(140))  # ~2,000 words, distinct sentences
    fixture(cmd="set", field="text", text=doc)
    s, _ = wait_for(lambda s: s["counters"]["lastDirtyCount"] >= 100, 15.0)  # first full check done
    done = s["counters"]["completedChecks"]
    fixture(cmd="replace", field="text", **{"from": "lazy dog near the river bank today 70.", "to": "lazy cat near the river bank today 70."})
    s, took = wait_for(lambda s: s["counters"]["completedChecks"] > done and s["counters"]["lastDirtyCount"] > 0, 3.0)
    ms = s["counters"].get("lastRecheckMs") if took is not None else None
    check(5, "2,000 words, one-word edit → re-check < 100 ms", took is not None and ms is not None and ms < 100,
          f"{ms:.1f} ms for {s['counters']['lastDirtyCount']} sentence(s)" if ms is not None else "no re-check")

    # 6. Killing harper-ls → the next check restarts it.
    starts = state()["counters"]["harperStarts"]
    subprocess.run(["pkill", "-f", "WritingAssistant.app/Contents/Helpers/harper-ls"])
    time.sleep(0.5)
    fixture(cmd="set", field="text", text="She dont know.")
    s, took = wait_for(lambda s: any(x["original"] == "dont" for x in s["suggestions"]), 5.0)
    check(6, "harper-ls killed → restarted, still underlines", took is not None and s["counters"]["harperStarts"] > starts,
          f"starts {starts} → {s['counters']['harperStarts']}, fallback checks {s['counters']['fallbackChecks']}")

    ask("/tmp/wa-debug.sock", json.dumps({"cmd": "setTierTwo", "enabled": True}))
    subprocess.run(["pkill", "-x", "FixtureApp"])
    print(f"\n{sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
