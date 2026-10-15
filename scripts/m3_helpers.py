"""Shared helpers for the integration scripts: debug sockets, FixtureApp, app restart, card buttons."""
import json
import os
import socket
import subprocess
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/WritingAssistant-local")
FIXTURE = os.path.join(DERIVED, "Build/Products/Debug/FixtureApp.app")
FIXTURE_ID = "com.danielmaymon.WritingAssistantFixture"
APP = "/Applications/WritingAssistant.app"


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


def card_buttons():
    """Positions of the card's buttons (x, y, w, h), read through Accessibility."""
    out = subprocess.run(["osascript", "-e", 'tell application "System Events" to tell process "WritingAssistant" '
                          'to get {position, size} of every button of every UI element of every window'],
                         capture_output=True, text=True).stdout
    nums = [float(n) for n in out.replace("{", "").replace("}", "").split(",") if n.strip()]
    half = len(nums) // 2
    pos, size = nums[:half], nums[half:]
    return [(pos[i], pos[i + 1], size[i], size[i + 1]) for i in range(0, half, 2)]
