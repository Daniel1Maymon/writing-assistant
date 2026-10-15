#!/usr/bin/env python3
"""M3 manual check, automated (PLAN.md → M3): real clicks and ⌥⏎ in a real app.

The installed debug app posts the mouse clicks and key presses itself (debug socket `click` /
`optionReturn`), as hardware input, so the global mouse monitor and the ⌥⏎ event tap are exercised.
Before running, the target app's text field must be focused and contain SENTENCE.
Usage: scripts/real-app-check.py <bundle id> [--no-passthrough]
"""
import json
import socket
import subprocess
import sys
import time

SENTENCE = "I recieve the mail every day. She dont like teh rain."


def ask(line):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect("/tmp/wa-debug.sock")
    s.sendall(line.encode() + b"\n")
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    return json.loads(data)


def state():
    return ask("state")


def app(**command):
    return ask(json.dumps(command))


def fresh(s, word):
    """The suggestion for `word` whose range matches the field's current text (not a stale position)."""
    text = s.get("text", "")
    for x in s["suggestions"]:
        loc, length = x["range"]
        if x["original"] == word and text.encode("utf-16-le")[2 * loc:2 * (loc + length)].decode("utf-16-le") == word:
            return x
    return None


def wait(bundle, predicate, timeout=4.0):
    end = time.monotonic() + timeout
    s = None
    while time.monotonic() < end:
        s = state()
        if s.get("app") == bundle and predicate(s):
            return s, True
        time.sleep(0.05)
    return s, False


def card_buttons():
    """Positions of the card's buttons, read through Accessibility."""
    out = subprocess.run(["osascript", "-e", 'tell application "System Events" to tell process "WritingAssistant" '
                          'to get {position, size} of every button of every UI element of every window'],
                         capture_output=True, text=True).stdout
    nums = [float(n) for n in out.replace("{", "").replace("}", "").split(",") if n.strip()]
    half = len(nums) // 2
    pos, size = nums[:half], nums[half:]
    return [(pos[i], pos[i + 1], size[i], size[i + 1]) for i in range(0, half, 2)]


def main():
    bundle = sys.argv[1]
    passthrough = "--no-passthrough" not in sys.argv
    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  ({detail})" if detail else ""))

    subprocess.run(["osascript", "-e", f'tell application id "{bundle}" to activate'], check=True)
    s, ok = wait(bundle, lambda s: fresh(s, "recieve") and fresh(s, "teh"))
    if not ok:
        print(f"FAIL  setup: no fresh underlines (app={s.get('app')}, role={s.get('role')}, "
              f"words={[x['original'] for x in s['suggestions']]})")
        return 1
    check("underlines shown", True, f"role={s['role']}")

    target = fresh(s, "recieve")
    r = target["rect"]
    app(cmd="click", x=r[0] + r[2] / 2, y=r[1] + r[3] / 2)
    s, ok = wait(bundle, lambda s: s["card"] == target["id"], 2.0)
    check("click underline → card opens", ok)

    buttons = card_buttons() if ok else []
    if buttons:
        x, y, w, h = buttons[0]
        app(cmd="click", x=x + w / 2, y=y + h / 2)
    s, ok = wait(bundle, lambda s: "I receive the mail" in s.get("text", ""), 2.0)
    check("click first fix on card → fixed", ok, f"{len(buttons)} card buttons")

    s, _ = wait(bundle, lambda s: fresh(s, "teh"))
    teh = fresh(s, "teh")
    if teh:
        r = teh["rect"]
        app(cmd="click", x=r[0] + r[2] + 1.3, y=r[1] + r[3] / 2)  # caret at the end of the word
        s, at = wait(bundle, lambda s: s["atCaret"] == teh["id"], 1.0)
        # Some apps (Mail) put the caret after the following space; step back with the left arrow.
        extra = (s.get("selection") or [0])[0] - (teh["range"][0] + teh["range"][1])
        for _ in range(max(0, extra) if not at else 0):
            subprocess.run(["osascript", "-e", 'tell application "System Events" to key code 123'])
        s, _ = wait(bundle, lambda s: s["atCaret"] == teh["id"], 1.5)
        app(cmd="optionReturn")
    s, ok = wait(bundle, lambda s: "like the rain" in s.get("text", ""), 2.0)
    check("caret in flagged word + ⌥⏎ → fixed", ok, f"caret={s.get('selection')}")

    if passthrough:
        before = s.get("text", "")
        app(cmd="optionReturn")  # caret now after "the": nothing flagged there
        s, ok = wait(bundle, lambda s: s.get("text", "") != before, 2.0)
        check("⌥⏎ with nothing flagged → reaches the app", ok)

    s = state()
    check("card closed afterwards", s["card"] == "")
    print(f"\n{sum(results)}/{len(results)} passed in {bundle}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
