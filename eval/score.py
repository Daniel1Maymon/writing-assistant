#!/usr/bin/env python3
"""Tier-2 quality eval (PLAN.md → M4): sends every golden sentence to a model, as the app does, and scores it.

Error sentences: "fixed" when applying the model's edits (or taking its rewrite) gives one of the accepted versions;
"flagged" when the model reported anything at all. Clean sentences: any edit or rewrite is a false positive.
Misses and false positives are written to eval/results/<model>.json for reading.
Usage: eval/score.py --model deepseek/deepseek-v4-flash [--model ...] [--only word|phrase|sentence|clean]
"""
import argparse
import json
import os
import statistics
from concurrent.futures import ThreadPoolExecutor

import openrouter

HERE = os.path.dirname(os.path.abspath(__file__))


def normal(text):
    return " ".join(text.replace("’", "'").replace("‘", "'").split())


def result_text(sentence, answer):
    rewrite = answer.get("rewrite")
    if rewrite and rewrite.get("text"):
        return rewrite["text"]
    text = sentence
    for edit in answer.get("edits", []):
        if edit.get("original") and edit["original"] in text:
            text = text.replace(edit["original"], edit.get("replacement", ""), 1)
    return text


def score(model, items):
    with ThreadPoolExecutor(8) as pool:
        answers = list(pool.map(lambda item: openrouter.check(item["text"], [model]), items))
    rows = []
    for item, (answer, cost, seconds, used, error) in zip(items, answers):
        row = {"text": item["text"], "kind": item["kind"], "cost": cost, "seconds": seconds, "error": error, "answer": answer}
        if answer is not None:
            row["result"] = result_text(item["text"], answer)
            row["flagged"] = bool(answer.get("edits") or answer.get("rewrite"))
            row["rewrite"] = (answer.get("rewrite") or {}).get("kind")
            if item["kind"] != "clean":
                row["fixed"] = normal(row["result"]) in {normal(f) for f in item["fixed"]}
                row["accepted"] = item["fixed"]
        rows.append(row)
    return rows


def report(model, rows):
    ok = [r for r in rows if r["error"] is None]
    errors = [r for r in ok if r["kind"] != "clean"]
    clean = [r for r in ok if r["kind"] == "clean"]
    times = sorted(r["seconds"] for r in ok)
    pct = lambda part, whole: f"{100 * len(part) / len(whole):.0f}%" if whole else "-"  # noqa: E731
    print(f"\n== {model}")
    print(f"answered {len(ok)}/{len(rows)}" + (f"  (failed: {sorted({r['error'][:60] for r in rows if r['error']})})" if len(ok) < len(rows) else ""))
    for kind in ("word", "phrase", "sentence"):
        part = [r for r in errors if r["kind"] == kind]
        if part:
            print(f"  {kind:9} fixed {pct([r for r in part if r['fixed']], part):>4}   flagged {pct([r for r in part if r['flagged']], part):>4}   (n={len(part)})")
    if errors:
        print(f"  {'all':9} fixed {pct([r for r in errors if r['fixed']], errors):>4}   flagged {pct([r for r in errors if r['flagged']], errors):>4}   (n={len(errors)})")
    if clean:
        print(f"  clean: false positives {pct([r for r in clean if r['flagged']], clean)}, "
              f"rewrite null {pct([r for r in clean if not r['rewrite']], clean)}  (n={len(clean)})")
    if times:
        p95 = times[min(len(times) - 1, int(0.95 * len(times)))]
        print(f"  latency p50 {statistics.median(times):.2f}s  p95 {p95:.2f}s;  cost ${sum(r['cost'] or 0 for r in rows):.5f} "
              f"(${1000 * sum(r['cost'] or 0 for r in rows) / max(len(rows), 1):.3f} per 1000 sentences)")
    os.makedirs(os.path.join(HERE, "results"), exist_ok=True)
    path = os.path.join(HERE, "results", model.replace("/", "_") + ".json")
    bad = [r for r in rows if r["error"] or (r["kind"] == "clean" and r.get("flagged")) or (r["kind"] != "clean" and not r.get("fixed"))]
    json.dump(bad, open(path, "w"), indent=1, ensure_ascii=False)
    print(f"  misses and false positives: {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", action="append", required=True)
    parser.add_argument("--only")
    args = parser.parse_args()
    items = [json.loads(line) for line in open(os.path.join(HERE, "golden.jsonl")) if line.strip()]
    if args.only:
        items = [i for i in items if i["kind"] == args.only]
    for model in args.model:
        report(model, score(model, items))


if __name__ == "__main__":
    main()
