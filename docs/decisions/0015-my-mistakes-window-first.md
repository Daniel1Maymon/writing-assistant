# 0015 — "My mistakes…" window built first in M5, reading the same SQLite file

- **Date:** 2026-10-19
- **Status:** accepted
- **Supersedes:** nothing (moves one M5 item to the front)

## Context

Accepted fixes have been saved to `mistakes.sqlite` since M3, but there was no way to see them without a SQLite tool. The user wants to review them to practise their own mistakes.

## Decision

1. The window is the first M5 item, before wider app support.
2. It opens its own read/delete connection to the same file the checker writes to (the debug socket can point both at a temp file). It doesn't copy or cache the data.
3. Search and filtering run in SQL (`LIKE`, case-insensitive), so they're tested in Core with no UI.
4. When a fix is recorded, the checker posts a notification and an open window reloads, so new fixes appear without reopening it.
5. Two views: "All fixes" (table, newest first, search, type filter, delete, Export CSV) and "Most repeated".

## Why

- One file, two connections, is the simplest thing that's always up to date. SQLite handles a writer and a reader in one process.
- Putting search in Core keeps the logic testable without UI tests.

## Consequences

- A database error while the window is open shows a message in the window. It never affects checking.
- Practice features (quizzes) remain out of scope (DESIGN.md).
