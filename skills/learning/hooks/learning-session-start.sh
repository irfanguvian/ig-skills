#!/usr/bin/env bash
# SessionStart: if project has .learning/, inject search rules + module ids + last session header and its next: line.
# stdout of SessionStart hook = context for Claude. Keep under 2 KB: Claude Code shows the model only a 2 KB preview of bigger output.
set -uo pipefail
INPUT=$(cat 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null); CWD="${CWD:-$PWD}"
ROOT=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); ROOT="${ROOT%/.git}"
L="${ROOT:-$CWD}/.learning" # linked worktree -> main checkout (never its own copy)
[ -d "${LEARNING_DIR:-}" ] && L="$LEARNING_DIR" # board clone (git clone --shared): main checkout DB
LEARN="$HOME/.claude/skills/learning/bin/learn.sh"
FIND="bash $LEARN find"; SAVE="On finish: /learning save (SESSIONS.md + DECISIONS.md + touched module docs, caveman ultra)."
# board run (an external task runner sets TB_PHASE): Bash naming .claude is denied there, the run PATH has a `learn` wrapper
[ -n "${TB_PHASE:-}" ] && { FIND="learn find"; SAVE="Board run: save notes only when the board note says so (working phase, last task)."; }
if [ ! -f "$L/INDEX.md" ]; then
  # only nudge in code repos, one line
  for f in package.json pyproject.toml go.mod Cargo.toml pom.xml composer.json Gemfile; do
    [ -f "$CWD/$f" ] && { echo "learning: no .learning/ here. Onboarding new project? run /learning onboard (builds module map, local only)."; break; }
  done
  exit 0
fi
OUT="learning: .learning/ DB present. RULES: before reading code or grepping repo, search DB first: \`$FIND <terms>\` (grep INDEX+docs+graph). Read only matched docs. $SAVE Never cat whole .learning/.
$(awk -F'|' '/^\| / { id = $2; t = $3; gsub(/ /, "", id); gsub(/ /, "", t); if (id == "id") next; if (t == "concept" || t == "guide") m = m " " id; else n++ }
  END { if (m != "" || n) print "modules:" m (n ? " +" n " more (learn.sh find)" : "") }' "$L/INDEX.md")
$(awk '/^## S-/ { if (h != "") exit; h = substr($0, 4)
    # cut the slug, never the sid: token (the save step matches it)
    if (length(h) > 140) { if (match(h, / sid:[^ ]+/) && RSTART + RLENGTH > 141) h = substr(h, 1, 140 - RLENGTH) substr(h, RSTART, RLENGTH); else h = substr(h, 1, 140) }
    print "last: " h; next }
  h != "" && /^next:/ { print; exit }' "$L/SESSIONS.md" 2>/dev/null | cut -c1-200)"
printf '%s\n' "$OUT"
# metrics: bytes injected at session start
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
jq -nc --arg ts "$(date -u +%FT%TZ)" --arg sid "${SID:0:8}" --arg root "${ROOT:-$CWD}" --arg cwd "$CWD" --argjson bytes "${#OUT}" \
  '{ts:$ts,ev:"session-start",sid:$sid,root:$root,cwd:$cwd,bytes:$bytes}' >> "$HOME/.claude/learning-metrics.jsonl" 2>/dev/null || true
