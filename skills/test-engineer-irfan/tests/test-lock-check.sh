#!/usr/bin/env bash
# Asserts test-lock.sh: `lock --check` gate, fail-closed verify, lock record, guard deny/allow.
# Run: bash ~/.claude/skills/test-engineer-irfan/tests/test-lock-check.sh  (exit 0 = all pass)
set -u
TL=${TL:-$HOME/.claude/hooks/test-lock.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/tlcheck.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

R=$T/repo; mkdir -p "$R/src"
git -C "$R" init -q || fail "git init"
echo "it('x', () => {})" > "$R/src/a.spec.ts"
L=$R/.claude/test-lock.json
# HOME + XDG_STATE_HOME isolated so nothing writes outside the temp dir (lock record goes to $T/state).
run() { (cd "$R/src" && HOME=$T XDG_STATE_HOME=$T/state bash "$TL" "$@" >"$T/out" 2>"$T/err"); echo $?; }
# what the user's unlock leaves behind: no lock, no record
clean() { rm -rf "$L" "$T/state"; }

# a) passing check -> lock written; check runs from repo root (pwd in subdir src/)
rc=$(run lock --check 'test -f src/a.spec.ts')
[ "$rc" -eq 0 ] || fail "a: exit $rc, err: $(cat "$T/err")"
[ -f "$L" ] || fail "a: lock file missing"
grep -q '"src/a.spec.ts"' "$L" || fail "a: spec not hashed"
clean

# b) failing check -> non-zero, no lock, message + check output tail on stderr
rc=$(run lock --check 'echo lint-boom; exit 3')
[ "$rc" -ne 0 ] || fail "b: exit 0 on failed check"
[ ! -e "$L" ] || fail "b: lock written on failed check"
grep -q 'check failed (exit 3), lock NOT written' "$T/err" || fail "b: no refusal msg: $(cat "$T/err")"
grep -q 'lint-boom' "$T/err" || fail "b: check output not shown"

# b2) after a failed check, a passing check locks (failed check left no state behind)
rc=$(run lock --check true)
[ "$rc" -eq 0 ] && [ -f "$L" ] || fail "b2: passing check after failed one did not lock"
clean

# c) another run locks while the check runs -> exit != 0, its lock byte-identical
rc=$(run lock --check 'mkdir -p .claude && echo other-run > .claude/test-lock.json')
[ "$rc" -ne 0 ] || fail "c: exit 0 although lock appeared during check"
[ "$(cat "$L" 2>/dev/null)" = other-run ] || fail "c: other run's lock overwritten or gone"
grep -q 'Lock NOT written' "$T/err" || fail "c: no refusal msg: $(cat "$T/err")"
clean

# d) no --check -> lock as before + notice
rc=$(run lock)
[ "$rc" -eq 0 ] || fail "d: exit $rc"
[ -f "$L" ] || fail "d: lock file missing"
grep -qxF 'test-lock: no --check given (lint/typecheck not verified)' "$T/err" || fail "d: no notice: $(cat "$T/err")"
clean

# e) empty --check -> refused, no lock
rc=$(run lock --check '')
[ "$rc" -ne 0 ] || fail "e: exit 0 on empty --check"
[ ! -e "$L" ] || fail "e: lock written on empty --check"
grep -q -- '--check needs a command' "$T/err" || fail "e: no refusal msg: $(cat "$T/err")"

# --- verify, record, unlock. M = the lock record for this repo.
clean
M=$T/state/test-lock/$(printf %s "$(git -C "$R" rev-parse --show-toplevel)" | shasum -a 256 | cut -c1-64).json
edit() { echo "it('edited', () => {})" > "$R/src/a.spec.ts"; }
restore() { echo "it('x', () => {})" > "$R/src/a.spec.ts"; }

# f) lock writes lock + record (dir 700); untouched tests -> verify ok rc 0
rc=$(run lock)
[ "$rc" -eq 0 ] && [ -f "$M" ] || fail "f: no record at $M"
[ "$(stat -f %Lp "$T/state/test-lock" 2>/dev/null || stat -c %a "$T/state/test-lock")" = 700 ] || fail "f: record dir not mode 700"
rc=$(run verify)
[ "$rc" -eq 0 ] && grep -qxF 'ok: 1 locked files unchanged' "$T/out" || fail "f: verify rc $rc: $(cat "$T/out" "$T/err")"

# g) lock with no record (record deleted, or older test-lock) -> verify FAILS closed, tests untouched
rm -f "$M"
rc=$(run verify)
[ "$rc" -eq 1 ] || fail "g: verify rc $rc with no record"
grep -q 'no record for this lock .*the user must unlock and lock again' "$T/err" || fail "g: no msg: $(cat "$T/err")"

# h) unlock clears lock and record; lock works again
cp "$L" "$M"
rc=$(run unlock)
[ "$rc" -eq 0 ] && [ ! -e "$L" ] && [ ! -e "$M" ] || fail "h: unlock left lock or record"
rc=$(run lock)
[ "$rc" -eq 0 ] || fail "h: relock after unlock rc $rc: $(cat "$T/err")"

# i) empty / corrupt / zero-entry lock (record matches it) + edited test -> verify FAILS closed
edit
for body in '' '{"files":' '{"lockedAt":"x","files":{}}'; do
  printf '%s' "$body" > "$L"; cp "$L" "$M"
  rc=$(run verify)
  [ "$rc" -ne 0 ] || fail "i: verify rc 0 on lock body [$body]"
  grep -q 'lock is empty or corrupt' "$T/err" || fail "i: no fail-closed msg for [$body]: $(cat "$T/err")"
done
restore; clean

# j) delete-edit-relock chain: relock refused, verify fails; hand-made fresh lock differs from record
run lock >/dev/null
rm -f "$L"; edit
rc=$(run lock --check true)
[ "$rc" -ne 0 ] && grep -q 'already locked (record' "$T/err" || fail "j: relock after delete allowed (rc $rc)"
[ ! -e "$L" ] || fail "j: relock wrote a lock"
rc=$(run verify)
[ "$rc" -ne 0 ] && grep -q 'lock file deleted' "$T/err" || fail "j: verify passed with lock deleted (rc $rc)"
printf '{"lockedAt":"x","files":{"src/a.spec.ts":"%s"}}' "$(shasum -a 256 "$R/src/a.spec.ts" | cut -c1-64)" > "$L"
rc=$(run verify)
[ "$rc" -ne 0 ] && grep -q 'differs from its record' "$T/err" || fail "j: forged lock passed verify (rc $rc)"
restore; clean

# --- guard. g <cwd> <command> -> rc. Lock active in $R.
run lock >/dev/null; mkdir -p "$R/e2e"; echo x > "$R/e2e/login.ts"; clean; run lock >/dev/null
g() { jq -n --arg d "$1" --arg c "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' |
  (HOME=$T XDG_STATE_HOME=$T/state bash "$TL" guard 2>"$T/err"); echo $?; }
# k) delete / truncate the lock by glob or dir -> denied
for c in 'rm .claude/test-lock.*' 'rm -rf .claude' ': > .claude/test-lock.json' 'cd .claude && rm *'; do
  [ "$(g "$R" "$c")" -eq 2 ] || fail "k: guard allowed: $c"
done
# l) Bash writes onto locked files -> denied (path, redirect, cp, basename from another dir)
for c in "sed -i '' s/x/y/ src/a.spec.ts" 'echo x > src/a.spec.ts' 'cp /tmp/x src/a.spec.ts' 'rm src/*.spec.ts'; do
  [ "$(g "$R" "$c")" -eq 2 ] || fail "l: guard allowed: $c"
done
[ "$(g "$R/e2e" "sed -i '' s/x/y/ login.ts")" -eq 2 ] || fail "l: basename write from e2e/ allowed"
grep -q 'writes a locked test file' "$T/err" || fail "l: no reason in block msg"
# l2) normal gate commands stay allowed (redirect/tee to a non-locked file, read .claude)
for c in 'npx vitest run src/a.spec.ts 2>&1 | tee /tmp/vt.log' 'npx vitest run src/a.spec.ts > /tmp/vt.log' 'cat .claude/settings.json'; do
  [ "$(g "$R" "$c")" -eq 0 ] || fail "l2: guard blocked: $c ($(cat "$T/err"))"
done
# m) record dir is guarded from any cwd; HOME override next to test-lock denied
[ "$(g "$T" 'rm -rf ~/.local/state/test-lock')" -eq 2 ] || fail "m: record dir delete allowed"
[ "$(g "$R" 'HOME=/tmp/x bash test-lock.sh verify')" -eq 2 ] || fail "m: HOME override allowed"
# n) jq missing -> lock/.claude call denied, unrelated call allowed
mkdir -p "$T/nojq"; ln -s "$(command -v cat)" "$T/nojq/cat"
B=$(command -v bash)
nj() { printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$R" "$1" | (PATH=$T/nojq HOME=$T "$B" "$TL" guard 2>"$T/err"); echo $?; }
[ "$(nj 'rm .claude/test-lock.json')" -eq 2 ] || fail "n: jq missing, lock delete allowed"
grep -q 'jq missing' "$T/err" || fail "n: no jq-missing msg"
[ "$(nj 'ls')" -eq 0 ] || fail "n: jq missing blocked unrelated call"
printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"src/a.spec.ts"}}' "$R" | (PATH=$T/nojq HOME=$T "$B" "$TL" guard 2>/dev/null)
[ $? -eq 2 ] || fail "n: jq missing, Edit on locked test file allowed"

echo "PASS: 16 cases (a, b, b2, c, d, e, f, g, h, i, j, k, l, l2, m, n)"
