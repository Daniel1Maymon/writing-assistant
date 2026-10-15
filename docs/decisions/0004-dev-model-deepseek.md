# 0004 — Use DeepSeek V4 Flash as the model during development

- **Date:** 2026-10-15
- **Status:** accepted (until the M4 eval)
- **Supersedes:** —

## Context

DESIGN.md names `anthropic/claude-haiku-5.5` as the main model, while the user's `.env` had `OPENROUTER_MODEL=deepseek/deepseek-v4-flash`. The question was whether that was on purpose.

## Decision

Keep `deepseek/deepseek-v4-flash` in `.env` for development (the user's choice, 2026-10-15). The M4 eval (`score.py` over Haiku 5.5, GPT-6 Luna and DeepSeek V4 Flash) still picks the final main model.

## Why

- It's the cheapest of the three ($0.09 / $0.18 per 1M tokens), which suits a period of many test calls.
- The model is a config value, so nothing in the code depends on this choice.

## Consequences

- Live tests and manual checks before M4 reflect DeepSeek's quality, not Haiku's.
- DESIGN.md's model table is unchanged; the eval result will update it.
