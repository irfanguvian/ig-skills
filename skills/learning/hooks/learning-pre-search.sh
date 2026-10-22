#!/usr/bin/env bash
# PreToolUse Grep|Glob|Bash(grep/rg): look up search terms in .learning/ first, inject compact hits.
# Deterministic grep done here so model spends zero tokens searching the DB.
set -uo pipefail
INPUT=$(cat 2>/dev/null)
command -v jq >/dev/null 2>&1 || exit 0
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
if [ "$TOOL" = Bash ]; then
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
  # most Bash calls search nothing: skip them before the git/jq/awk work
  case "$CMD" in *grep*|*rg*|*"ag "*|*ack*|*learn.sh*) ;; *) exit 0;; esac
fi
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty'); CWD="${CWD:-$PWD}"
ROOT=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); ROOT="${ROOT%/.git}"
L="${ROOT:-$CWD}/.learning" # linked worktree -> main checkout (never its own copy)
[ -d "${LEARNING_DIR:-}" ] && L="$LEARNING_DIR" # board clone (git clone --shared): main checkout DB
[ -f "$L/INDEX.md" ] || exit 0
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
# agent_id/agent_type exist only on subagent tool calls; subagents share the parent session_id
AGID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')
AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_type // "main"')
TERMS=""
# English stopwords match nearly every note; same list as learn.sh find
SW='^(not|the|and|for|with|from|this|that|are|was|were|has|have|into|onto|than|then|them|they|what|when|where|which|while|will|would|should|could|only|also|just|like|very|more|most|some|such|each|other|over|under|same|both)$'
# metrics line: lm <ev> <extra json object>. aid = id tail, the head is the agent name
lm() { jq -nc --arg ts "$(date -u +%FT%TZ)" --arg ev "$1" --arg sid "${SID:0:8}" --arg agent "$AGENT" --arg agid "$AGID" \
  --arg root "${ROOT:-$CWD}" --arg cwd "$CWD" --arg terms "$TERMS" --argjson x "$2" \
  '{ts:$ts,ev:$ev,sid:$sid,agent:$agent,aid:($agid|.[-8:]),root:$root,cwd:$cwd,terms:$terms} + $x' >> "$HOME/.claude/learning-metrics.jsonl" 2>/dev/null || true; }
case "$TOOL" in
  Grep|Glob)
    TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.path // empty')
    case "$TARGET" in *".learning"*) exit 0;; esac
    PAT=$(printf '%s' "$INPUT" | jq -r '.tool_input.pattern // empty');;
  Bash)
    # statements split on ; && || newline, each cut at its first unquoted | (the tail filters stdin).
    # FS="" = O(1) char access; a statement head past 500 chars holds no search we can parse.
    # heredoc bodies dropped (delimiter rule as jobq-guard.sh): body text is no command, its apostrophes open no quote.
    # a heredoc starts only at an unquoted << or one inside "$(…)": "use << EOF" in a message is text
    STMTS=$(printf '%s\n' "$CMD" | awk -v sq="'" 'BEGIN { FS = "" }
      hd != "" { l = $0; sub(/^\t+/, "", l); if (l == hd) hd = ""; next }
      {
      for (i = 1; i <= NF; i++) { c = $i
        if (c == "<" && $(i + 1) == "<" && hd == "" && (q == "" || q == "\"" && cs)) {
          if ($(i + 2) == "<") i += 2
          else if (match(substr($0, i + 2), "^-?[ \t]*[\"" sq "]?[A-Za-z_][A-Za-z0-9_]*")) { hd = substr($0, i + 1 + RSTART, RLENGTH); sub("^-?[ \t]*[\"" sq "]?", "", hd) } }
        if (q != "") { if (c == q) q = cs = ""; else if (q == "\"" && c == "$" && $(i + 1) == "(") cs = 1 }
        else if (c == "\"" || c == "'"'"'") q = c
        else if (c == ";" || (c == "&" || c == "|") && $(i + 1) == c) { print o; o = ""; k = t = 0; if (c != ";") i++; continue }
        else if (c == "|") t = 1
        if (!t && k++ < 500) o = o c }
      if (q == "") { print o; o = ""; k = t = 0 } else if (!t && k++ < 500) o = o " " }
      END { if (o != "") print o }')
    # on-demand lookup = a statement that runs learn.sh find; learn.sh logs its own hits
    FC=$(printf '%s\n' "$STMTS" | grep -E '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^ ]* +)*((ba)?sh +)?[^ ]*learn\.sh["'"'"']? +find( |$)' | head -1)
    if [ -n "$FC" ]; then
      TERMS=$(printf '%s\n' "${FC#*learn.sh}" | sed -E 's/^["'"'"']? +find//; s/[<>].*//' | tr -c '[:alnum:]_\n' ' ' | tr ' ' '\n' | awk -v sw="$SW" 'length>2 && tolower($0) !~ sw' | head -5 | tr '\n' ' ' | sed 's/ $//')
      lm find-call '{}'; exit 0
    fi
    case "$CMD" in *".learning"*) exit 0;; esac
    # only a search that starts a pipeline reads the repo; `... | grep x` filters stdin
    FIRST=$(printf '%s\n' "$STMTS" | grep -E '^[[:space:]]*([^ ]*/)?(rg|grep|egrep|ag|ack|git[[:space:]]+grep)([[:space:]]|$)' | head -1)
    [ -n "$FIRST" ] || exit 0
    TW=$(printf '%s' "$FIRST" | awk '{ w = $1; sub(/.*\//, "", w); print (w == "git" ? $2 : w) }')
    # file listing / patterns read from a file (ack -f lists files; ag -f = follow symlinks): nothing to look up
    case "$TW" in ag) ;; *) case "$FIRST " in *" --files "*|*" --file "*|*" --file="*|*" -f "*) exit 0;; esac;; esac
    # pattern = -e/--regexp arg wherever it sits, else first non-flag arg after the tool; crude but cheap
    Q='"[^"]+"|'"'"'[^'"'"']+'"'"'|[^ ]+'
    PAT=$(printf '%s' "$FIRST" | grep -oE " (-e +|--regexp[= ])($Q)" | head -1 | sed -E 's/^ (-e +|--regexp[= ])//')
    # flags that take a spaced value (-A 3, -t ts, --type ts): the value is not the pattern
    case "$TW" in
      rg) VF=ABCmtTgjM; LF='type|type-not|glob|iglob|max-count|context|after-context|before-context|threads|max-depth';;
      ag) VF=ABCmG; LF='';; ack) VF=ABCm; LF='';;
      *) VF=ABCmfdD; LF='include|exclude|exclude-dir|max-count|context|after-context|before-context|file';; esac
    F="( +(-[$VF] +[^ ]+|${LF:+--($LF) +[^ ]+|}-[^ -][^ ]*|--[^ ]+))*"
    [ -n "$PAT" ] || PAT=$(printf '%s' "$FIRST" | grep -oE "(^|[[:space:];&|/])(rg|grep|egrep|ag|ack)$F +($Q)" | head -1 | sed -E "s/^[[:space:];&|\/]*(rg|grep|egrep|ag|ack)$F +//")
    PAT=$(printf '%s' "$PAT" | sed -E 's/^["'"'"']//; s/["'"'"']$//')
    # bare -- in the pattern slot: the next word is the pattern, leading dash and all (-- after a pattern = pathspec)
    DD=""
    [ "$PAT" != "--" ] || { DD=$(printf '%s' "$FIRST" | grep -oE " -- +($Q)" | head -1 | sed -E 's/^ -- +//; s/^["'"'"']//; s/["'"'"']$//'); PAT="$DD"; }
    [ -n "$DD" ] || case "$PAT" in -*) exit 0;; esac
    ;;
  *) exit 0;;
esac
[ -n "${PAT:-}" ] || exit 0
# glob patterns: keep stem words only
TERMS=$(printf '%s' "$PAT" | tr -c '[:alnum:]_\n' ' ' | tr ' ' '\n' | awk -v sw="$SW" 'length>2 && tolower($0) !~ sw && $0 !~ /^(src|lib|test|tests|spec|index|main|utils|ts|tsx|js|jsx|py|go|md|json)$/' | head -4 | tr "\n" " " | sed "s/ $//")
[ -n "$TERMS" ] || exit 0
# same terms already injected to this agent in this session -> skip, log what it saved
# per-user 700 dir: on a shared /tmp another user could pre-create or symlink a fixed name. Unsafe -> no dedupe
TD="${TMPDIR:-/tmp}/learning-$(id -u)"; mkdir -m 700 "$TD" 2>/dev/null; { [ -d "$TD" ] && [ ! -L "$TD" ] && [ -O "$TD" ] && chmod 700 "$TD" 2>/dev/null; } || TD=""
SEEN="${TD:+$TD/learning-seen-${SID:0:8}}"; SEEN="${SEEN:-/dev/null}"
KEY="${SID:-nosid} ${AGID:-main} $(printf '%s\n' $TERMS | sort -u | tr '\n' ' ')"
PREV=$(awk -F'\t' -v k="$KEY" '$1 == k { print $2; exit }' "$SEEN" 2>/dev/null)
[ -z "$PREV" ] || { lm pre-search "{\"hits\":0,\"bytes\":0,\"dup\":true,\"saved\":$PREV}"; exit 0; }
HITS=$(LEARNING_CALLER=hook LEARNING_DIR="$L" bash "$HOME/.claude/skills/learning/bin/learn.sh" find $TERMS 2>/dev/null | head -18)
CTX="learning DB hits for [$TERMS] — read these before raw files:
$HITS"
# metrics: every lookup attempt, hit or miss — hit rate = usability signal
NH=$(printf '%s' "$HITS" | grep -c .)
[ -n "$HITS" ] && NB=${#CTX} || NB=0
{ printf '%s\t%s\n' "$KEY" "$NB" >> "$SEEN"; } 2>/dev/null
lm pre-search "{\"hits\":$NH,\"bytes\":$NB}"
[ -n "$HITS" ] || exit 0
jq -n --arg ctx "$CTX" '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$ctx}}'
