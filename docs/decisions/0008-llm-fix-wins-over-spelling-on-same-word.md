# 0008 — On the same word, the model's grammar fix comes first

- **Date:** 2026-10-15
- **Status:** accepted
- **Supersedes:** DESIGN.md → pipeline step 7 and PLAN.md M1 merge rule "local wins on overlap" (for the case below only)

## Context

"She dont know." Harper flags `dont` as a spelling mistake and offers "don't". The right fix is "doesn't". Checked through the installed app on 2026-10-15: Harper doesn't flag "She don't know." at all, because it has no subject–verb agreement rule for this. So only the model (M4) can offer "doesn't".

Under the current merge rule, a model edit that overlaps a Harper fix is dropped. The model's "doesn't" would never be shown.

## Decision

When a model edit covers the **same span** as a Harper suggestion, or a span that contains it, the two become one suggestion:

- The model's replacement comes first (the one ⌥⏎ applies), followed by Harper's replacements, without duplicates, up to 3.
- It takes the model's span, category and reason.
- Harper's rule id is kept, so "Ignore rule" still works.

When the edits only partly overlap, Harper still wins and the model's edit is dropped, as before.

## Why

- Harper is a spell checker plus rules for each word. It can't see that "she" needs "doesn't". The model can.
- Keeping Harper's options as alternatives means a wrong model guess costs one extra click, not a missing fix.
- Partial overlaps are rare and hard to show clearly, so the old rule stays for them.

## Consequences

- The `merge` function and its tests change in M4. The current M1 test "overlapping LLM edit is dropped" is narrowed to partial overlaps.
- Until M4, "She dont know." still offers only "don't".
