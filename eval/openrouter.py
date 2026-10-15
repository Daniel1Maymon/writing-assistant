"""Sends one sentence to OpenRouter exactly as the app does (decision 0010).

The prompt and schema are read from Core/Sources/Core/TierTwoRequest.swift, so the eval tests the app's prompt.
The key comes from .env and is never printed.
"""
import json
import os
import re
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT = os.path.join(ROOT, "Core/Sources/Core/TierTwoRequest.swift")


def _between(text, start, end):
    block = text[text.index(start):text.index(end)]
    return re.search(r'#"""\n(.*?)\n"""#', block, re.S).group(1)


_source = open(SWIFT).read()
PROMPT = _between(_source, "// PROMPT-START", "// PROMPT-END")
SCHEMA = json.loads(_between(_source, "// SCHEMA-START", "// SCHEMA-END"))


def env():
    values = {}
    for line in open(os.path.join(ROOT, ".env")):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.removeprefix("export ").split("=", 1)
            values[key.strip()] = value.strip().strip("\"'")
    return values


def body(sentence, before, after, models):
    return {
        "models": models,
        "provider": {"sort": "latency"},
        "messages": [{"role": "system", "content": PROMPT},
                     {"role": "user", "content": f"BEFORE: {before or ''}\nSENTENCE: {sentence}\nAFTER: {after or ''}"}],
        "response_format": {"type": "json_schema", "json_schema": {"name": "sentence_check", "strict": True, "schema": SCHEMA}},
        "max_tokens": 300,
        "temperature": 0,
        "reasoning": {"enabled": False},
        "usage": {"include": True},
    }


def check(sentence, models, before=None, after=None):
    """Returns (answer dict or None, cost, seconds, model used, error)."""
    config = env()
    request = urllib.request.Request(config.get("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1") + "/chat/completions",
                                     data=json.dumps(body(sentence, before, after, models)).encode(),
                                     headers={"Authorization": "Bearer " + config["OPENROUTER_API_KEY"],
                                              "Content-Type": "application/json", "X-Title": "WritingAssistant eval"})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=30) as reply:
            data = json.load(reply)
    except urllib.error.HTTPError as error:
        return None, 0, time.monotonic() - started, None, f"HTTP {error.code}: {error.read()[:300].decode(errors='replace')}"
    except Exception as error:  # noqa: BLE001
        return None, 0, time.monotonic() - started, None, type(error).__name__
    seconds = time.monotonic() - started
    cost = (data.get("usage") or {}).get("cost", 0)
    try:
        content = data["choices"][0]["message"]["content"].strip()
        if content.startswith("```"):
            content = content.split("\n", 1)[1].rsplit("```", 1)[0]
        return json.loads(content), cost, seconds, data.get("model"), None
    except Exception as error:  # noqa: BLE001
        return None, cost, seconds, data.get("model"), f"malformed: {type(error).__name__}"
