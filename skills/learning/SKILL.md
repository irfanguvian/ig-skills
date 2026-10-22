---
name: learning
description: 'Per-project learning database in .learning/ — business process, one md per module, decisions, session verdicts, graphify relation graph. Search it before reading code; update it on finish. Caveman ultra, local only. Trigger: /learning, "onboard", "learn this codebase", "what do we know about <module>".'
---

# /learning

Project memory for AI. Lives in `<repo>/.learning/`. Never pushed (`.learning/.gitignore` = `*`).
Goal: next session knows the codebase without re-reading it. Small docs, grep-first, graph for relations.

```
/learning                 status (counts, last session). no .learning -> onboard
/learning onboard         first time on a project: learn business process + modules, write DB
/learning save            end of session: verdict + work + decisions into DB, rebuild graph
/learning query <q>       grep + graph lookup, print hits only
/learning module <name>   (re)learn one module, rewrite its doc
/learning migrate         backfill frontmatter contract on old notes (id/type/ids-not-paths)
/learning vault           export Obsidian vault -> .learning/vault/ (--out DIR to override)
/learning hooks           install|uninstall|status per-repo hooks (.claude/settings.local.json)
/learning doctor          health check: hook scripts, registration, Stop chain, INDEX freshness
/learning fix             doctor --fix: restore stale hook scripts, register hooks, rebuild INDEX
/learning stats           hook telemetry: real hit rate, dup savings, on-demand finds per agent, save nags
```

Helper CLI (use it, do not reimplement): `bash ~/.claude/skills/learning/bin/learn.sh {find <terms>|build|migrate|vault export|hooks install|doctor [--fix]|fix|stats [days] [--here]|status}`.
Hooks are PER REPO, not global: `/learning onboard` installs them into `<repo>/.claude/settings.local.json` (gitignored by Claude Code). SessionStart inject, PreToolUse search-first, PostToolUse graph rebuild, Stop save-guard. Canonical scripts ship with the skill in `~/.claude/skills/learning/hooks/`; `install` points settings at the runtime copies in `~/.claude/hooks/`, and `/learning fix` restores any that went missing or stale. Restart session after install.

**Worktrees write to the parent tree.** A linked git worktree never gets its own `.learning/`. Every hook and `learn.sh` resolve the DB via `git rev-parse --git-common-dir` → the main checkout's `.learning/`, so a session in `../repo-feature-x` reads and saves the same SESSIONS/DECISIONS/modules as the parent. `hooks install` also drops `hooks/learning-git-post-checkout.sh` into `<repo>/.git/hooks/post-checkout` (shared by all worktrees) so a new worktree is seeded with `.claude/settings.local.json` + every `CLAUDE.local.md` from the main checkout — without those the hooks would never fire there. Seed copies ONCE: later main-checkout changes (new hook, new rule) only reach a live worktree via `/learning fix` run inside it. Rules: never `mkdir .learning` in a worktree; name worktree + branch in the session block; give subagents running in a worktree the same instruction (they have no hooks of their own).

PreToolUse search-first: only a grep/rg/ag/ack/`git grep` that STARTS a pipeline counts (`ps aux | grep x` = stdin filter, skipped, not logged). Bash command with no `grep|rg|ag |ack|learn.sh` substring exits before any git/jq/awk work. Pattern = `-e`/`--regexp` arg, else first non-flag arg; bare `--` in that slot = next word is the pattern (`-- -force`), `--` after a pattern = pathspec (`git grep x -- apps`); `ack -f` (file list) = no lookup (`--include='*.ts'`, `--exclude-dir=x` = flags; spaced value skipped for `-A -B -C -m` + grep `-f -d -D --include --exclude --exclude-dir --max-count --context --after-context --before-context --file`, rg `-t -T -g -j -M --type --type-not --glob --iglob --max-count --context --after-context --before-context --threads --max-depth`, ag `-G`). Leading tabs/spaces ok (indented line). Heredoc body dropped; heredoc starts only at unquoted `<<` or `<<` inside `"$(…)"` (`"use << EOF"` = text). Same terms again in same session + same agent = no inject (`dup`). Seen-file `$TMPDIR/learning-seen-<sid8>`. Subagent = own key (`agent_id`), parent injection not visible to it. Statement that RUNS `learn.sh find` (`[VAR=x ][bash ]<path>/learn.sh find …`) = on-demand call: hook logs `find-call`, injects nothing. `grep "learn.sh find" x` = normal lookup.

Metrics: one JSONL line per event to `~/.claude/learning-metrics.jsonl` (global, all projects, never synced with skill folder, append-only). Every line: `ts ev sid root cwd` — `root` = git-common-dir root (worktree lines roll up to main checkout).
- `session-start` bytes injected.
- `pre-search` terms hits bytes agent aid; misses logged too. Repeat: `dup:true bytes:0 saved:<bytes of first inject>`.
- `find-call` terms agent aid — hook saw a Bash `learn.sh find`.
- `find` terms hits bytes — written by `learn.sh find` itself, unless `LEARNING_CALLER=hook` (hook's own lookup). sid = first 8 of `CLAUDE_CODE_SESSION_ID`.
- `post-edit-build`, `stop` (blocked/clean, unsaved count).
- `agent` = hook input `agent_type`, `main` when absent (main thread). `aid` = LAST 8 of `agent_id` (format `a<name>-<16 hex>`, head = name, not unique).

`learn.sh stats [days] [--here]` lines: window/project · session-start fires + KB · auto-inject: lookups, real hits (hits>0, not dup) of rated, real hit %, dup skipped + KB saved, legacy unrated · on-demand: find-calls, finds, find hit % · by agent `auto/on-demand` · sessions with pre-search but zero find-call · context cost · post-edit rebuilds · stop · top projects · verdict. `--here` = git-common-dir root of PWD: `.root` match OR cwd = root/subdir OR cwd in `git worktree list`. Legacy lines (no `root`, pre-fix) not rated: their hits counted graph hub noise. Verdict LOW: real hit rate <20% over >=10 rated lookups; on-demand 0 find-calls over >=5 tracked sessions. Logging fails open — metrics write never blocks hook.

## Layout

```
.learning/
  .gitignore        "*"  (local only)
  INDEX.md          GENERATED by learn.sh build. one row per note: id | type | summary | tags. only file read whole.
  graph.json        GENERATED. contract graph {nodes:[{id,title,type,tags,path}], edges:[{from,to,rel}]}. exporter input.
  vault/            GENERATED by learn.sh vault export. Obsidian vault: <type>/<id>.md + index.md MOC. never hand-edit.
  CODEBASE.md       what app IS + what it SHOULD be: business process, actors, flows, stack, invariants, conventions
  modules/<name>.md one per module. purpose, entry points, key files, deps, gotchas, related
  DECISIONS.md      append-only. one line per decision. every session
  SESSIONS.md       newest first. one block per session. verdict + work + decisions + next
  graphify-out/     graph.json (+ graph.html). GENERATED, graphify-native, richer (tags, D-/S- nodes). query via learn.sh find
```

## Doc style — caveman ultra (overrides the "normal prose in persisted docs" rule for this dir only)

- One word when one word enough. No articles, no filler, no conjunctions when order unambiguous. State each fact once.
- Code symbols, file paths, API names, error strings: verbatim. No invented abbreviations. No arrows.
- Every doc ends with `verdict:` line.
- Caps: module doc <= 40 lines. CODEBASE.md <= 80 lines. Session block <= 12 lines. Decision = 1 line. Over cap = cut, not split.
- Facts only. Not sure = write `?` after it. Never invent.
- Link notes by ID: `[[billing]]`, `[[codebase]]`. Never by path or title. Links become `related` graph edges + Obsidian backlinks. Link liberally, that is the graph.

### Frontmatter CONTRACT (required, parsed by build; build reports violations, `learn.sh migrate` fixes old notes)

```
---
id: billing                         # kebab-case, unique, = filename stem, never changes
title: Billing
type: concept                       # concept (module) | guide (CODEBASE) | reference (DECISIONS, SESSIONS) | moc
tags: [billing, stripe, money]      # >= 1
summary: invoices, payments, webhooks. Stripe. money = integer minor units   # optional, feeds INDEX + hook
prerequisites: [users]              # optional. ids. "read users first". edge users -> billing (learning order)
related: [orders]                   # optional. ids only
---
```

Unknown ids allowed (forward refs); `learn.sh vault export` reports them as dangling. Duplicate id = build problem.

### modules/<name>.md template

```
---
id: <name>
title: <Name>
type: concept
tags: [..]
summary: <one line, what it does for business>
prerequisites: [<id>, ..]
related: [<id>, ..]
---
# <Name>
role: <business purpose, 1-2 lines. who uses it, why>
entry: `src/x/x.controller.ts` routes / `src/x/x.service.ts` logic / jobs / listeners
flow: <main happy path in 3-6 steps, file:fn per step>
data: <tables/models owned. key columns. indexes>
deps: in: [[a]] out: [[b]], ext: Stripe, Redis
rules: <business invariants. e.g. refund only if status=paid. idempotency key on POST>
gotchas: <traps. race, env flag, legacy path>
tests: <where. what covered. what not>
verdict: <state: solid | fragile | legacy | wip. one line why>
```

### CODEBASE.md template

```
---
id: codebase
title: <Project>
type: guide
tags: [codebase]
summary: <what business does, one line>
prerequisites: []
related: [<every module id>]
---
# <Project>
business: <who pays, for what. actors. 2-4 lines>
process: <end-to-end business flow as numbered steps, each step names [[module-id]]>
stack: <lang, framework, db, queue, infra. versions if pinned>
layout: <top dirs and meaning, one line each>
conventions: <naming, error format, pagination, auth, money, time. the contracts>
should-be: <target architecture / direction. what good looks like. migration in progress?>
drift: <where code differs from should-be>
run: <install, dev, test, build commands>
verdict: <overall state one line>
```

### SESSIONS.md / DECISIONS.md header (type reference)

```
---
id: sessions            # or: decisions
title: Sessions
type: reference
tags: [reference]
---
# Sessions
```

### SESSIONS.md block (newest on top, under `# Sessions` header)

```
## S-0007 2026-08-23 add-refund-endpoint sid:a1b2c3d4
verdict: shipped — refund POST live, webhook retry still TODO
work: refund service + controller [[billing]]; idempotency key; integration test
decisions: D-0012 D-0013
next: webhook retry backoff; index on payments(order_id,status)
open: <unanswered question for human, or none>
```

### DECISIONS.md line

```
- D-0012 2026-08-23 [[billing]] refunds idempotent by Idempotency-Key header; rejected: dedupe by amount+time (race)
```

## onboard — steps

1. `ls`, read README/CLAUDE.md/docs/REGISTRY.md index only. Detect stack + module boundaries (dirs under src/, Nest modules, Django apps, Go pkgs, ..). List candidate modules. If > 12, group by business domain, not by folder.
2. Per module, delegate read-only: `Agent` with `caveman:cavecrew-investigator` (or `Explore`, or `oh-my-claudecode:explore`), 2-4 in parallel, handover = module name + dirs + the template above + "return filled template, caveman ultra, facts with file:line, `?` when unsure, <= 40 lines". Orchestrator only verifies + writes.
3. Write `.learning/.gitignore` (`*`), `CODEBASE.md`, `modules/*.md`, `DECISIONS.md` (`# Decisions` + seed lines for visible architectural choices found in code, tag `(inferred)`), `SESSIONS.md` (`# Sessions` + S-0001 onboard block).
4. `bash ~/.claude/skills/learning/bin/learn.sh build` then `learn.sh status`. Zero `problem:` lines, INDEX rows = notes.
5. `bash ~/.claude/skills/learning/bin/learn.sh hooks install` — per-repo hooks + git `post-checkout` worktree seed. Tell human: restart session to activate.
6. Report: module count, open `?` list, verdict. Ask human only the `?` that block business understanding.

Do NOT write per-file docs, API reference, or prose tours. One md per module. That is all.

## save — steps (end of every working session; Stop hook nags if forgotten)

1. Next ids: `grep -c '^## S-' .learning/SESSIONS.md`, `grep -c '^- D-' .learning/DECISIONS.md`.
2. Same Claude session as top block (`sid:` matches, hook tells you)? Update that block in place. Else prepend new block after `# Sessions` line. One block per session, not per turn. Append decision lines to DECISIONS.md. Every non-obvious choice this session = decision line, incl. rejected option.
3. Touched module changed behavior/structure/contract? Edit that module doc lines in place. New module? New doc. Nothing structural changed? Touch nothing.
4. `bash ~/.claude/skills/learning/bin/learn.sh build`. Done.
5. In a linked worktree: same steps, same files — `learn.sh` and the hooks already point at the main checkout's `.learning/`. Never create one in the worktree.

## doctor / fix — hook health

`/learning doctor` (read-only) and `/learning fix` (= `doctor --fix`) run
`bash ~/.claude/skills/learning/bin/learn.sh doctor [--fix]` in the repo root. One `ok:`/`problem:`/`fixed:` line per check, `verdict:` last.

| Check | `--fix` repairs |
|---|---|
| `.learning/INDEX.md` present | no — run `/learning onboard` |
| each `~/.claude/hooks/learning-*.sh` matches the skill's canonical copy | yes, copies it back |
| all 4 hooks registered in `.claude/settings.local.json` | yes, runs `hooks install` |
| git `post-checkout` worktree seed present (git repos only) | yes, runs `hooks install`; a foreign post-checkout is reported, never overwritten |
| linked worktree only: `.claude/settings.local.json` `.hooks` == main checkout's (main prints `ok: main checkout, worktree sync n/a`) | yes, replaces ONLY `.hooks`; `permissions` (Claude Code "always allow" rules) + other keys kept. Invalid JSON either side = `problem:`, not compared |
| linked worktree only: every `CLAUDE.local.md` the seed copies (same find) byte-equal to main's | yes, copies main's over (rules never diverge); worktree copy newer (mtime) than main's -> kept first as `<file>.bak-<YYYYmmddHHMMSS>`, named in the `fixed:` line |
| `learning-stop.sh` does not gate on `stop_hook_active` | no — see below |
| INDEX newer than every note | yes, runs `build` |
| `.claude/settings*.json` free of another machine's `/Users/<name>/` | no, intent unknown |

Exits 1 when any problem is left, so it works as a gate. Run it from the repo root — `--fix` writes `.claude/settings.local.json` relative to the cwd. `LEARNING_HOOKS_DIR` overrides the canonical dir (tests use it; nothing else should).

`stop_hook_active` is shared by **every** Stop hook. A `learning-stop.sh` that early-exits on it goes
silent for the whole session as soon as any other Stop hook blocks first, so the save nag never fires.
Loop protection is a per-session block counter at `$TMPDIR/learning-stop-<sid8>` (max 2) instead.

## vault — Obsidian export

`bash ~/.claude/skills/learning/bin/learn.sh vault export [--out DIR]`. Pipeline: notes (frontmatter ids) -> `graph.json` -> `vault/<type>/<id>.md` + `vault/index.md` (MOC by tag, then type). Passthrough frontmatter + `cssclass: generated`, body unchanged, `## Prerequisites` (incoming), `## Related` (symmetric). No "Leads to" — backlinks cover it. Idempotent, byte-identical; vault wiped + regenerated each run (guarded by `.learning-vault` marker). Default out inside `.learning/` (already ignored); `--out` outside appends to `.gitignore`. Report: nodes, edges, dangling ids, orphans, prerequisite cycles (warning). Open `.learning/vault` as an Obsidian vault. Pure file transform, no LLM.

## query — steps

1. `bash ~/.claude/skills/learning/bin/learn.sh find <terms>` — <= 18 lines, best first, query matching nothing prints nothing. Cheap. Terms: alnum words > 2 chars, max 5, English stopwords dropped (`not the and for with from this that …`, same list in the pre-search hook).
   - `INDEX <row>` (<=5) INDEX rows ranked by distinct terms hit.
   - `DOC <path> (n hits)` (<=4) notes, n = terms matched. Never SESSIONS/DECISIONS/INDEX/graphify-out/vault.
   - `DEC <line>` (<=3) DECISIONS lines matching most terms, newest on tie, cut 200 chars.
   - `SES <header>` (<=2) `## S-` headers whose block matches most terms, newest on tie.
   - `NODE`/`EDGE` (<=2 each) graphify lines that name a term. graphify puts hub nodes first for any seeded query — unfiltered they read as hits.
2. Open only docs it names. Follow `[[id]]` links one hop if needed. Stop.
3. Need relation between two concepts: `learn.sh find A B` then follow EDGE lines; or open `.learning/graphify-out/graph.html` in browser.
4. Never `cat .learning/*`. Never read more than 3 docs before touching code.

## Rules

- Search DB before repo. Hook does it for Grep/Glob/grep (once installed); you do it on first prompt: `learn.sh find <keywords from user ask>`.
- Tests for the tooling: `python3 -m unittest discover -s ~/.claude/skills/learning/tests` (stdlib; vault fixture: forward ref + orphan + 2-cycle, idempotency, no-relation note, migrate; `test_find.py`: find output, pre-search filter/dedupe/find-call, stats --here — HOME/TMPDIR/LEARNING_DIR in tmp, real metrics never written).
- `learn.sh build|migrate` hold `/usr/bin/lockf -k -t 25 .learning/.build.lock` (under post-edit hook timeout 30) — main checkout + worktree post-edit builds never write INDEX/graph at once. No lockf = unlocked. Lock file covered by `.learning/.gitignore` `*`.
- DB is local only. Never `git add .learning`. Never reference it in commits.
- Update, do not append forever: module docs are rewritten in place, capped. SESSIONS/DECISIONS are the only append logs.
- If `docs/REGISTRY.md` exists, REGISTRY stays the authoritative change record; `.learning` is the map + verdicts. Do not duplicate REGISTRY entries into SESSIONS, link the R-id instead.
- Conflict between `.learning` doc and code: code wins; fix the doc in the same session.
