# test-engineer-irfan — templates

Specs live in `.learning/` (local only, gitignored). They follow the learning frontmatter contract so `learn.sh build` stays clean. Spec files are exempt from the global Mermaid rule.

## Spec — `.learning/specs/<module>/<module>-<feature>.md`

```markdown
---
id: <module>-<feature>
title: <Feature> spec
type: reference
tags: [spec, <module>]
summary: <one line: which rules this spec owns>
related: [<module>]
status: DRAFT
---
# <Feature> spec
## Rules
R1: <one sentence rule>
  layer: static | unit | property | integration | e2e   — why: <one line>
  examples:
  | input | expected | note |
  |---|---|---|
  | amount=10050, rate=1% | fee=101 | 100.50 rounds up (ceil) to 101 |
R2: ...
## Must not change (backward compat)
B1: <existing behaviour>   layer: ...   source: <existing test file:line, or "none yet">
## Out of scope
- <thing>
verdict: draft | approved YYYY-MM-DD
```

## Bugs — `.learning/specs/<module>/<module>-bugs.md`

```markdown
---
id: <module>-bugs
title: <Module> bug rules
type: reference
tags: [spec, bugs, <module>]
related: [<module>]
---
# <Module> bug rules
BUG1: <one sentence rule>   status: DRAFT | APPROVED   date: YYYY-MM-DD
  layer: unit | property | integration | e2e   — why: <one line>
  repro: <input or steps that show the bug today>
  | input | expected | note |
  |---|---|---|
verdict: <n> bug rules, <m> approved
```

## Index — module doc `## Specs`

Put it above the `verdict:` line. It counts toward the 40-line module cap. One line per feature:

```markdown
## Specs
- fee-rounding: [[billing-fee-rounding]] .learning/specs/billing/billing-fee-rounding.md R1-R4 B1-B2
- bugs: [[billing-bugs]] .learning/specs/billing/billing-bugs.md BUG1-BUG3
```

## Lavish review page

Get guidance from the CLI first: `npm exec --yes --package=lavish-axi@0.1.90 -- lavish-axi playbook plan` (also `table`, `input`). Use the `npm exec` form, because `npx -y lavish-axi` can fail on some setups. The top-level version is pinned on purpose (supply chain); its dependencies still resolve by range. Bump it only after you check the new release. Page goes to `.lavish/<module>-<feature>-spec.html`. Open it with `npm exec --yes --package=lavish-axi@0.1.90 -- lavish-axi <page>`, then run `... lavish-axi poll <page>` in the foreground.

Start with a **Verdict:** line: what the spec covers and what the user must decide. Label every item in words, "Rule 1 — <rule>", "Old behaviour 1 — <behaviour>", "Bug 1 — <rule>", never a bare R1, B1 or BUG1. Then sections, in order:
1. Interview Q&A: question, options shown, answer the user picked.
2. Rules and old behaviours to keep (must not change), each with its example table.
3. Testing Trophy layer per rule + one-line why.
4. Planned tests: rule (in words) | test name | layer | file.
5. Out of scope.
6. Open questions and assumptions.

Lite path: Verdict line + section 2 (bug rows) + reproduction test plan only.

## Map — rule → test (Phase 4, reused in Phase 8)

| Rule | Test name | Layer | File | Red ok? | Final |
|---|---|---|---|---|---|
| Rule 1 | R1: fee rounds up to whole cent | unit | src/billing/fee.test.ts | yes | PASS |

Then: `orphan tests: none` · `rules without test: none`.

## Red check (Phase 5)

| Test | Expected | Actual (quoted) | ok? |
|---|---|---|---|
| R1: fee rounds up | FAIL assertion | `expected 101, received 100` | yes |
| B1: zero amount, zero fee | PASS | `✓ B1: zero amount, zero fee` | yes |
| R2: fee capped | FAIL assertion | `Cannot find module './fee'` | NO: setup, fix import |

## Report (Phase 8) — `docs/verdicts/<YYYY-MM-DD>-<slug>.md`

```markdown
# Spec run · <module>/<feature> · <date>
**Verdict:** PASS | FAIL — <one plain sentence>
<mermaid flowchart of the tested flow>
## Rule → test
<Map table, Final column filled>
## Suite
<command per layer + quoted summary line, e.g. `Tests  14 passed (14)`>
## Lock
<`test-lock.sh verify` output, quoted>
## Mutation
| mutation | file:line | killed by | survived? |
## Evidence
<screenshot paths, evidence only>
```
