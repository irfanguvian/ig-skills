#!/usr/bin/env bash
# PostToolUse Edit|Write: doc under .learning/ changed -> rebuild INDEX + graph (fast, no LLM).
set -uo pipefail
INPUT=$(cat 2>/dev/null)
command -v jq >/dev/null 2>&1 || exit 0
FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
case "$FP" in
  */.learning/*.md)
    DIR="${FP%%/.learning/*}/.learning"
    [ -f "$DIR/INDEX.md" ] || [ -f "$DIR/CODEBASE.md" ] || exit 0
    bash "$HOME/.claude/skills/learning/bin/learn.sh" build "$DIR" >/dev/null 2>&1 || true
    SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
    jq -nc --arg ts "$(date -u +%FT%TZ)" --arg sid "${SID:0:8}" --arg root "${DIR%/.learning}" --arg cwd "${DIR%/.learning}" \
      '{ts:$ts,ev:"post-edit-build",sid:$sid,root:$root,cwd:$cwd}' >> "$HOME/.claude/learning-metrics.jsonl" 2>/dev/null || true
    ;;
esac
exit 0
