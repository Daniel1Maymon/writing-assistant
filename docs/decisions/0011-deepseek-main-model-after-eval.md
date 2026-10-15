# 0011 — DeepSeek V4 Flash is the main model after the M4 eval

- **Date:** 2026-10-15
- **Status:** accepted (revisit when Haiku 5.5 and GPT-6 Luna can be called)
- **Supersedes:** 0004 (dev-only model), DESIGN.md's model table (Haiku 5.5 as main)

## Context

The M4 eval was meant to compare Haiku 5.5, GPT-6 Luna and DeepSeek V4 Flash. On this OpenRouter account, Haiku and Luna return HTTP 404 "Model blocked by guardrail" (a workspace setting at https://openrouter.ai/workspaces/default/guardrails). Only DeepSeek answers.

`eval/score.py` on `eval/golden.jsonl` (100 sentences with mistakes, 50 clean), DeepSeek V4 Flash, the app's exact prompt and body:

| | Result | Target (PLAN.md go/no-go) |
| --- | --- | --- |
| Fixed exactly (word / phrase / sentence) | 98% (98% / 96% / 100%) | recall ≥ 80% |
| False positives on clean sentences | 0% | ≤ 5% |
| `rewrite` null on clean sentences | 100% | ≥ 90% (decision 0007) |
| Latency p50 / p95 | 1.4 s / 3.9 s | p95 ≤ 2 s |
| Cost | ≈ $0.05 per 1,000 sentences | ≤ $3 / month |
| Unreadable answers | 1 in 151 | — (the app retries) |

## Decision

DeepSeek V4 Flash is the main model. The planned Swift live test (`LIVE_OPENROUTER=1 swift test --filter Live`) is replaced by `scripts/m4-check.py`, `scripts/m4-real-app.py` and `eval/score.py`, which all make real calls with the app's prompt.

## Why

- It beats every quality and cost target by a wide margin. Only p95 latency misses.
- The other two candidates can't be called at all right now, so they can't be the main model.
- A Swift live test would only repeat what the three scripts already check against the real API, and the eval is the better quality test.

## Consequences

- The fallback in `.env` (GPT-6 Luna) is blocked, so today there is no working fallback. Either the guardrail is relaxed or the fallback changes.
- p95 latency (3.9 s) is an open item for the go/no-go. Tier 2 runs after a sentence is finished and never blocks typing, so it feels like a late underline, not lag.
- Once the guardrail allows them, rerun `eval/score.py --model anthropic/claude-haiku-5.5 --model openai/gpt-6-luna` and revisit this decision.
