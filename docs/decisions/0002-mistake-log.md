# 0002 — Mistake log: accepted fixes, with the full sentence

- **Date:** 2026-10-15
- **Status:** accepted
- **Supersedes:** —

## Context

The user wants a database of every grammar mistake so they can learn from it later. The options were:

1. Log accepted fixes together with the full sentence.
2. Log accepted fixes without the sentence (more private).
3. Log everything flagged, including dismissed items.

## Decision

Option 1. One row per **accepted** fix, including the sentence as it was before the fix, stored locally in `~/Library/Application Support/WritingAssistant/mistakes.sqlite`. Schema: DESIGN.md → Mistake log.

## Why

- **Accepted = confirmed.** An accepted fix is a mistake the user agreed was real. Dismissed items are often false alarms and would pollute a learning list.
- **Context matters.** Without the sentence, "its → it's" is hard to learn from later.
- **It's still local.** It's the same data the user typed, kept on their own Mac and never sent anywhere.

## Consequences

- This breaks the "no user text stored" principle on purpose. Mitigations: a Settings toggle to turn it off, "Delete all", and secure fields and excluded apps are never checked, so they can never be logged.
- It's a separate file from the suggestion cache, so clearing the cache keeps the history.
- Writing a row must never block or fail an accept.
- Undo (⌘Z) after an accept does not remove the row.
