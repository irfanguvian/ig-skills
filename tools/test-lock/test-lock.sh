#!/usr/bin/env bash
# test-lock.sh — hash-lock tests so agents cannot change them during implementation.
#   lock    write <repo>/.claude/test-lock.json: sha256 of tests, snapshot baselines, .learning/specs,
#           plus a copy (the record) at $STATE/<sha256 of repo root>.json so a deleted lock shows up
#           --check "<cmd>": run <cmd> (bash -c, repo root) first; non-zero = lock NOT written
#   verify  recompute, print changed/added/removed, exit 1 if any. Fails closed: no record, lock
#           missing or different from its record, empty or corrupt lock = exit 1
#   unlock  delete the lock and its record. The user only, own terminal (guard blocks it for Claude)
#   guard   PreToolUse hook. stdin = hook JSON. exit 2 = block the tool call
# Needs: git, jq, shasum, cmp. Bash 3.2 safe. STATE = ${XDG_STATE_HOME:-$HOME/.local/state}/test-lock

LOCK=.claude/test-lock.json
MSG="Tests are locked. If a test looks wrong, stop and tell the user."
STATE=${XDG_STATE_HOME:-$HOME/.local/state}/test-lock
# Bash verbs that write, move or delete files (guard only; text match, not a parser)
WV='(^|[^[:alnum:]_.-])(rm|rmdir|mv|cp|ln|unlink|truncate|dd|install|touch|chmod|shred|rsync|patch)([^[:alnum:]_.-]|$)|sed[^;&|]*[[:space:]]-[[:alnum:]]*i|perl[^;&|]*[[:space:]]-[[:alnum:]]*i|git[^;&|]*[[:space:]](clean|checkout|restore|stash|reset|mv|rm)([[:space:]]|$)|-delete'

die() { echo "test-lock: $*" >&2; exit 1; }
block() { echo "$MSG${1:+ ($1)}" >&2; exit 2; }

# $1 = path relative to repo root. Patterns match at any depth (monorepos).
is_locked() {
  case "/$1" in
    *.spec.ts|*.spec.tsx|*.test.ts|*.test.tsx|*.e2e-spec.ts|*/e2e/*|*-snapshots/*|*/__snapshots__/*|*/.learning/specs/*) return 0 ;;
  esac
  return 1
}

# "sha  path" lines. Tests: git tracked + untracked, not ignored. Specs: .learning is gitignored, so find.
# .learning sits in the main checkout (git-common-dir), also when run from a linked worktree.
hashes() {
  local common files=() p
  common=$(cd "$(git rev-parse --path-format=absolute --git-common-dir)/.." && pwd)
  cd "$top" || exit 1
  while IFS= read -r p; do
    is_locked "$p" && [ -f "$p" ] && files+=("$p")
  done < <(git ls-files -co --exclude-standard)
  [ ${#files[@]} -gt 0 ] && shasum -a 256 "${files[@]}"
  [ -d "$common/.learning/specs" ] && (cd "$common" && find .learning/specs -type f -name '*.md' -exec shasum -a 256 {} +)
  return 0
}

to_json() { jq -Rn '[inputs | capture("^(?<h>[0-9a-f]{64})  (?<p>.+)$") | {(.p): .h}] | add // {}'; }

lock() {
  local check= out rc n
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) [ -n "${2:-}" ] || die "--check needs a command"; check=$2; shift 2 ;;
      *) die "unknown lock arg: $1" ;;
    esac
  done
  [ -f "$lockf" ] && die "already locked ($lockf). The user must unlock first."
  [ -f "$record" ] && die "already locked (record $record, lock file gone). The user must unlock first."
  if [ -n "$check" ]; then
    out=$(cd "$top" && bash -c "$check" 2>&1); rc=$?
    [ $rc -eq 0 ] || { echo "test-lock: check failed (exit $rc), lock NOT written" >&2; printf '%s\n' "$out" | tail -n 20 >&2; exit 1; }
  else
    echo "test-lock: no --check given (lint/typecheck not verified)" >&2
  fi
  # ponytail: re-test after a slow check; ms window to the write stays, O_EXCL write if parallel locks ever race
  [ -f "$lockf" ] && die "locked by another run while check ran ($lockf). Lock NOT written."
  mkdir -p "$top/.claude"
  hashes | to_json | jq --arg at "$(date -u +%FT%TZ)" '{lockedAt: $at, files: .}' > "$lockf" || { rm -f "$lockf"; die "write failed"; }
  n=$(jq '.files | length' "$lockf")
  [ "$n" -gt 0 ] 2>/dev/null || { rm -f "$lockf"; die "nothing to lock: no test, snapshot or spec file found. Lock NOT written."; }
  mkdir -p "$STATE" && chmod 700 "$STATE" && cp "$lockf" "$record" || { rm -f "$lockf" "$record"; die "record write failed ($record). Lock NOT written."; }
  local ex; ex=$(git rev-parse --path-format=absolute --git-path info/exclude)
  mkdir -p "${ex%/*}"
  grep -qxF "$LOCK" "$ex" 2>/dev/null || echo "$LOCK" >> "$ex"
  echo "locked: $n files -> $lockf"
}

verify() {
  if [ -f "$record" ]; then
    [ -f "$lockf" ] || die "lock file deleted ($lockf) but its record exists ($record). Tell the user."
    cmp -s "$lockf" "$record" || die "lock file changed: it differs from its record ($record). Tell the user."
  else
    [ -f "$lockf" ] || die "no lock at $lockf"
    die "no record for this lock ($record): the user must unlock and lock again."
  fi
  jq -e '.files | type == "object" and length > 0' "$lockf" >/dev/null 2>&1 || die "lock is empty or corrupt ($lockf), cannot verify. Tell the user."
  local out rc
  out=$(jq -rn --slurpfile old "$lockf" --slurpfile new <(hashes | to_json) '
    $old[0].files as $o | $new[0] as $n
    | ([$o | keys[] | select($n[.] == null) | "removed: \(.)"]
     + [$n | keys[] | select($o[.] == null) | "added: \(.)"]
     + [$o | keys[] | select($n[.] != null and $n[.] != $o[.]) | "changed: \(.)"])[]'); rc=$?
  [ $rc -eq 0 ] || die "compare failed (jq exit $rc), cannot verify"
  [ -z "$out" ] && { echo "ok: $(jq '.files | length' "$lockf") locked files unchanged"; return 0; }
  echo "$out"
  exit 1
}

unlock() { rm -f "$lockf" "$record" && echo "unlocked: $lockf"; }

# Walk up from $1 to the dir holding the lock. Pure bash, no git: runs on every Edit/Write/Bash.
lock_root() {
  local d=$1
  while [ -n "$d" ]; do
    [ -f "$d/$LOCK" ] && { echo "$d"; return 0; }
    d=${d%/*}
  done
  return 1
}

guard() {
  local in p tool cwd f start root cmd c t w targets cand rc
  in=$(cat)
  # jq missing or bad JSON: fail closed only for calls that name the lock, .claude, the record dir or a test file
  p=$(jq -r '[.tool_name // "", .cwd // "", .tool_input.file_path // ""] | @tsv' <<<"$in" 2>/dev/null) || {
    case $in in *test-lock*|*.claude*|*.local/state*|*"$STATE"*|*.spec.ts*|*.test.ts*|*.e2e-spec.ts*|*e2e/*|*snapshots/*|*.learning/specs*) echo "test-lock: cannot read the hook input (jq missing or bad JSON). Install jq." >&2; exit 2 ;; esac
    exit 0
  }
  IFS=$'\t' read -r tool cwd f <<<"$p"
  case "$tool" in
    Edit|Write|MultiEdit)
      [[ $f == /* ]] || f="$cwd/$f"
      [[ $f == "$STATE"/* ]] && block "lock record"
      for start in "${f%/*}" "$cwd"; do
        root=$(lock_root "$start") || continue
        is_locked "${f#"$root"/}" && block
        [[ $f == */$LOCK || $f == */test-lock.sh ]] && block
      done ;;
    Bash)
      cmd=$(jq -r '.tool_input.command // ""' <<<"$in")
      # records live outside every repo: guarded with or without a lock here
      case $cmd in *.local/state*|*XDG_STATE_HOME*|*"$STATE"*) { [[ $cmd == *test-lock* ]] || grep -qE "$WV" <<<"$cmd"; } && block "lock record" ;; esac
      [[ $cmd == *test-lock* && $cmd == *HOME=* ]] && block "HOME change hides the lock record"
      root=
      # ponytail: checks cwd + `cd <dir>` targets only. `git -C`/`--prefix` dirs not followed; `verify` still catches edits.
      for t in "$cwd" $(grep -oE '(^|[;&|(] *)cd +[^ ;&|)]+' <<<"$cmd" | sed -E 's/.*cd +//'); do
        t=${t/#\~/$HOME}
        [[ $t == /* ]] || t="$cwd/$t"
        root=$(lock_root "$t") && break
      done
      [ -n "$root" ] || exit 0
      c=${cmd//test-lock.sh verify/}
      c=${c//test-lock.sh lock/}
      [[ $c == *test-lock[.*?[]* ]] && block
      [[ $cmd == *--update-snapshots* || $cmd == *--updateSnapshot* ]] && block
      grep -qE '(jest|vitest|playwright|(npm|pnpm|yarn|bun)( run)? test)' <<<"$cmd" &&
        grep -qE '(^|[[:space:]])(-u|--update)([[:space:]]|$)' <<<"$cmd" && block
      w=; grep -qE "$WV" <<<"$cmd" && w=1
      # write targets: `> f`, `>> f`, `tee [-a] f` (`2>&1` has no file target)
      targets=$(grep -oE '>>?[[:space:]]*[^[:space:];&|<>()]+' <<<"$cmd" | sed -E 's/^>+[[:space:]]*//'
        grep -oE '(^|[^[:alnum:]_.-])tee( +-[[:alnum:]]+)* +[^ ;&|<>()]+' <<<"$cmd" | sed -E 's/.* //')
      [[ ( -n $w && $cmd == *.claude* ) || $targets == *.claude* ]] && block "touches .claude"
      if [ -n "$w" ]; then cand=$cmd; else cand=$targets; fi
      [ -n "$cand" ] || exit 0
      case $cand in *.spec.ts*|*.test.ts*|*.e2e-spec.ts*|*e2e/*|*snapshots/*|*.learning/specs*) block "writes a locked test file" ;; esac
      # a locked file named from another dir (e2e/login.ts as login.ts): match basenames from the lock
      jq -e --arg c "$cand" '[.files | keys[] | sub(".*/"; "")] | unique | any(. as $b | $c | contains($b))' "$root/$LOCK" >/dev/null 2>&1
      rc=$?
      [ $rc -eq 1 ] || block "writes a locked test file" ;;
  esac
  exit 0
}

case "${1:-}" in
  guard) guard ;;
  lock|verify|unlock)
    top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not a git repo. Run from the repo."
    lockf="$top/$LOCK"
    record="$STATE/$(printf %s "$top" | shasum -a 256 | cut -c1-64).json"
    "$@" ;;
  *) echo "usage: test-lock.sh lock [--check \"<cmd>\"]|verify|unlock|guard" >&2; exit 1 ;;
esac
