# 0012 — MiniMax M3 is the fallback model

- **Date:** 2026-10-15
- **Status:** accepted
- **Supersedes:** the fallback in 0011 and DESIGN.md (GPT-6 Luna)

## Context

GPT-6 Luna is blocked by the account's OpenRouter guardrail. The user allows only four models: Jev 1.13 (TypeSafe), MiniMax M3, DeepSeek V4 Flash 0423 (the main model), and GLM 4.7 Flash.

`eval/score.py` on the same 151 sentences:

| Model | Fixed (word / phrase / sentence) | False positives | p95 | Per 1,000 sentences |
| --- | --- | --- | --- | --- |
| `minimax/minimax-m3` | 81% (92% / 46% / 93%) | 0% | 1.3 s | $0.10 |
| `z-ai/glm-4.7-flash` | 72% (87% / 46% / 50%) | 2% | 2.2 s | $0.04 |
| `typesafe/jev-router` | no answer (HTTP 404 "No models satisfy the decision") | — | — | — |

## Decision

`OPENROUTER_FALLBACK_MODEL=minimax/minimax-m3`. DeepSeek V4 Flash stays the main model (98% fixed).

## Why

- MiniMax M3 fixes more mistakes than GLM, has no false positives, and is the fastest.
- It is weak on phrases (46%), but it only answers when DeepSeek has just failed.

## Consequences

- Checked: a request with `[gpt-6-luna, minimax-m3]` is answered by MiniMax, so OpenRouter skips a blocked model in the list.
- If MiniMax becomes the main model to meet the 2 s target, phrase fixes get much worse.
