#!/usr/bin/env bash
# Stop: project has .learning/ and this session edited files since last SESSIONS.md save
#       -> block, tell Claude to run /learning save.
# Loop guard is a per-session counter, NOT stop_hook_active: that flag is shared by every Stop
# hook, so an earlier blocking hook (e.g. a test or eval guard) would mask this one for the rest of
# the session and the save nag would never fire.
# Ceiling: 2 blocks per session, then silent for good — a save resets nothing, it just makes
# UNSAVED 0. Fails open everywhere (no jq, no transcript, unwritable marker) rather than nag on.
set -uo pipefail
INPUT=$(cat 2>/dev/null)
# board run (TB_PHASE set): save once per ticket, only in working on the last task
[ -z "${TB_PHASE:-}" ] || { [ "$TB_PHASE" = working ] && [ "${TB_LAST_TASK:-}" = 1 ]; } || exit 0
command -v jq >/dev/null 2>&1 || exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty'); CWD="${CWD:-$PWD}"
ROOT=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); ROOT="${ROOT%/.git}"
L="${ROOT:-$CWD}/.learning" # linked worktree -> main checkout (never its own copy)
[ -d "${LEARNING_DIR:-}" ] && L="$LEARNING_DIR" # board clone (git clone --shared): main checkout DB
[ -f "$L/SESSIONS.md" ] || exit 0
TR=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -f "$TR" ] || exit 0
# per-user 700 dir: on a shared /tmp another user could pre-create or symlink a fixed name. Unsafe -> no marker -> no block
TD="${TMPDIR:-/tmp}/learning-$(id -u)"; mkdir -m 700 "$TD" 2>/dev/null; { [ -d "$TD" ] && [ ! -L "$TD" ] && [ -O "$TD" ] && chmod 700 "$TD" 2>/dev/null; } || TD=""
MARK="${TD:+$TD/learning-stop-${SID:-nosid}}"
BLOCKS=$(cat "$MARK" 2>/dev/null || echo 0)
case "$BLOCKS" in ''|*[!0-9]*) BLOCKS=0;; esac
[ "$BLOCKS" -ge 2 ] && exit 0
# count real writes from the assistant's own tool_use blocks only (system prompt, hook context and
# tool results also say "Bash"/"cp"); a WRITE whose target is SESSIONS.md is the save, resets to 0
# ponytail: shell parse is a heuristic (heredoc bodies dropped, quoted text flattened, segment must
# START with a write verb or redirect to a non-scratch file); `cd /tmp && cat > x` still counts. Upgrade: a real sh tokenizer.
# linked worktrees of this repo count as project too (edits in ../<repo>-NNN from the main checkout)
WT=$(git -C "$CWD" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r w; do [ -d "$w" ] && printf '%s\n' "$w"; done)
UNSAVED=$(jq -nR --arg root "${ROOT:-}" --arg cwd "$CWD" --arg wt "$WT" --arg tmp "${TMPDIR:-}" '
  ([$root, $cwd] + ($wt | split("\n")) | map(select(. != ""))) as $roots
  | def inproj: . as $p | any($roots[]; . as $r | $p == $r or ($p | startswith($r + "/")));
  def scratch: test("^(/dev/null$|/tmp/|/private/tmp/|\\$\\{?TMPDIR\\b)")
    or ($tmp != "" and startswith($tmp | rtrimstr("/") + "/"));
  # drop wrappers so the real command leads: if cp .. / xargs sed .. / CI=1 npm i ..
  def lead: (capture("^(?:\\s+|[({!]+|(?:if|while|until|time|env|sudo|do|then|else|xargs(?:\\s+-\\S+)*|[A-Za-z_]\\w*=\\S*)\\s+)(?<r>.*)$") | .r | lead) // .;
  def sedi: "(\\S*/)?sed(\\s+-\\S+)*?\\s+(-[a-zA-Z]*i\\S*|--in-place\\S*)(\\s|$)";
  def lastarg: [splits("\\s+") | select(. != "")] | last // "";
  # S=/private/tmp/x; D=$S/y; cat > $D -> expand from assignments earlier in the same command
  def expand($vars): (capture("^\\$\\{?(?<k>\\w+)\\}?(?<r>.*)$") | if $vars[.k] then $vars[.k] + .r else empty end) // .;
  def keep($vars): expand($vars) | select(scratch | not);
  # one string per write: its target ("" when unknown); no output = no write
  def targets:
    gsub("<<-?\\s*[\u0027\"]?(?<tag>\\w+)[\u0027\"]?(?<rest>[^\\n]*)\\n(?:[\\s\\S]*?\\n)?\\s*\\k<tag>(?=\\n|$)"; " \(.rest)") as $h
    | ($h | gsub("\u0027(?<q>[^\u0027]*)\u0027|\"(?<d>[^\"]*)\""; (.q // .d) | gsub("[\\s;&|<>()]"; "_")) | [splits("&&|\\|\\||[;|\\n]")]) as $raw
    | (reduce ($raw[] | capture("^\\s*(?<k>[A-Za-z_]\\w*)=(?<v>\\S+)\\s*$")) as $a ({}; . as $m | .[$a.k] = ($a.v | expand($m)))) as $vars
    | ($raw[] | lead
        | (if test("^" + sedi) or test("^(\\S*/)?(mv|cp)(\\s|$)") then lastarg
           elif test("^(\\S*/)?(git\\s+commit|npm\\s+(i|install)|pnpm\\s+add|prisma\\s+migrate)(\\s|$)") or test("-exec\\s+" + sedi) then ""
           else empty end),
          (capture("^(\\S*/)?tee(\\s+-\\S+)*\\s+(?<t>\\S+)") | .t | keep($vars)),
          (scan(">>?\\s*([^\\s&<>()]+)") | .[0] | keep($vars))),
      ($h | match("(^|[\\s;&|(])(\\S*/)?(ba|z)?sh\\s+(-\\S+\\s+)*-\\w*c\\s+(\u0027(?<a>[^\u0027]*)\u0027|\"(?<b>[^\"]*)\")"; "g")
        | .captures[] | select(.name == "a" or .name == "b") | .string | strings | targets);
  reduce (inputs | fromjson? | objects | select(.type == "assistant") | .message | objects | .content | arrays | .[] | objects
          | select(.type == "tool_use")) as $t (0;
    . as $n | try (
      (($t.input | objects) // {}) as $in
      | if ($t.name | IN("Edit", "Write", "NotebookEdit", "MultiEdit")) then
          ($in.file_path // $in.notebook_path // "" | tostring) as $p
          | if ($p | test("\\.learning/SESSIONS\\.md$")) then 0 elif ($p | inproj) then $n + 1 else $n end
        elif $t.name == "Bash" then
          # every /learning save ends with learn.sh build — the one marker that survives however
          # the docs were written (heredoc, python, sed), unlike a redirect next to the filename
          ($in.command // "" | tostring) as $c
          | if ($c | test("learn\\.sh[\u0027\"]?\\s+build(\\s|$)")) then 0
            else [$c | targets] as $w
            | if ($w | length) == 0 then $n elif any($w[]; test("\\.learning/SESSIONS\\.md$")) then 0 else $n + 1 end
            end
        else $n end) catch $n)' "$TR" 2>/dev/null)
# metrics: every evaluated stop — blocked (nag fired) vs clean (saved / pure Q&A)
lm_stop() { jq -nc --arg ts "$(date -u +%FT%TZ)" --arg sid "${SID:0:8}" --arg root "${ROOT:-$CWD}" --arg cwd "$CWD" --argjson unsaved "${UNSAVED:-0}" --argjson blocked "$1" \
  '{ts:$ts,ev:"stop",sid:$sid,root:$root,cwd:$cwd,unsaved:$unsaved,blocked:$blocked}' >> "$HOME/.claude/learning-metrics.jsonl" 2>/dev/null || true; }
[ "${UNSAVED:-0}" -gt 0 ] || { lm_stop false; exit 0; }
# the counter IS the only loop guard — if it cannot be written, do not block
{ echo $((BLOCKS + 1)) > "$MARK"; } 2>/dev/null || exit 0
lm_stop true
jq -n --arg r "learning: $UNSAVED unsaved edits this session. Before stopping run /learning save: (1) .learning/SESSIONS.md: if top block header ends with 'sid:${SID:0:8}' update that block in place, else prepend '## S-NNNN YYYY-MM-DD <slug> sid:${SID:0:8}' + lines verdict:/work:/decisions:/next:, caveman ultra, link notes by id as [[billing]]; (2) append new decisions to .learning/DECISIONS.md as '- D-NNNN YYYY-MM-DD [[module-id]] chose A over B because C'; (3) update touched .learning/modules/*.md or CODEBASE.md only if behavior/structure changed; (4) bash ~/.claude/skills/learning/bin/learn.sh build. Then stop. Skip silently only if this turn was pure Q&A." \
  '{decision:"block", reason:$r}'
