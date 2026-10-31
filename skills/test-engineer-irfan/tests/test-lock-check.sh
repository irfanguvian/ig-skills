#!/usr/bin/env bash
# Asserts test-lock.sh: `lock --check` gate, `lock --spec` scope, fail-closed verify, lock record, guard deny/allow.
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
[ "$rc" -eq 0 ] && grep -qxF 'ok: 1 locked files unchanged (specs: all)' "$T/out" || fail "f: verify rc $rc: $(cat "$T/out" "$T/err")"

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

# --- lock --spec: two specs in the main checkout's .learning/specs (gitignored, as in real repos)
clean
echo '.learning/' >> "$R/.git/info/exclude"
S=$R/.learning/specs/mod; mkdir -p "$S"
spec() { echo "rule $1${2:-}" > "$S/$1.md"; }
spec A; spec B
SA=.learning/specs/mod/A.md; SB=.learning/specs/mod/B.md
LT=$(git -C "$R" rev-parse --show-toplevel)/.claude/test-lock.json

# o) --spec A (relative to cwd, absolute, main-checkout form: one entry) -> only A locked; B edits pass, A edits fail
rc=$(run lock --spec ../$SA --spec "$S/A.md" --spec $SA)
[ "$rc" -eq 0 ] || fail "o: lock --spec rc $rc: $(cat "$T/err")"
[ "$(jq -c .specs "$L")" = "[\"$SA\"]" ] || fail "o: specs = $(jq -c .specs "$L")"
[ "$(jq -c '.files | keys' "$L")" = "[\"$SA\",\"e2e/login.ts\",\"src/a.spec.ts\"]" ] || fail "o: files = $(jq -c '.files | keys' "$L")"
! grep -q 'no --spec given' "$T/err" || fail "o: all-specs notice with --spec"
grep -qxF "locked: 3 files (specs: $SA) -> $LT" "$T/out" || fail "o: locked line: $(cat "$T/out")"
spec B ' v2'
rc=$(run verify)
[ "$rc" -eq 0 ] && grep -qxF "ok: 3 locked files unchanged (specs: $SA)" "$T/out" || fail "o: B edit failed scoped verify (rc $rc): $(cat "$T/out" "$T/err")"
spec A ' v2'
rc=$(run verify)
[ "$rc" -eq 1 ] && [ "$(cat "$T/out")" = "changed: $SA" ] || fail "o: A edit not caught (rc $rc): $(cat "$T/out")"
rm "$S/A.md"
rc=$(run verify)
[ "$rc" -eq 1 ] && [ "$(cat "$T/out")" = "removed: $SA" ] || fail "o: A delete not caught (rc $rc): $(cat "$T/out")"
spec A; spec B; clean

# p) --spec on a missing file, a non-.md file, a .md outside .learning/specs (plain and ../ escape),
#    a name with a backslash (shasum escapes it, so it would never be hashed) -> refused, no lock, no record
echo x > "$S/notes.txt"; echo x > "$R/README.md"; echo x > "$R/.learning/x.md"; echo x > "$S/sib\\1.md"
for a in "$S/missing.md:no such file" "$S/notes.txt:not a .md file" "$R/README.md:not under" "$S/sib\\1.md:backslash or newline" \
         ".learning/specs/../../README.md:not under" ".learning/specs/mod/../../x.md:not under"; do
  rc=$(run lock --spec "${a%:*}")
  [ "$rc" -ne 0 ] || fail "p: lock accepted --spec ${a%:*}"
  [ ! -e "$L" ] && [ ! -e "$M" ] || fail "p: lock or record written for --spec ${a%:*}"
  grep -qF -- "--spec ${a%:*}: ${a##*:}" "$T/err" || fail "p: no refusal msg for ${a%:*}: $(cat "$T/err")"
done

# q) no --spec -> specs "all" + notice; another spec's edit fails verify (old behaviour)
rc=$(run lock)
[ "$rc" -eq 0 ] && [ "$(jq -c .specs "$L")" = '"all"' ] || fail "q: specs = $(jq -c .specs "$L") rc $rc"
grep -qxF "test-lock: no --spec given: locking ALL .learning/specs (another ticket's spec edit will fail verify)" "$T/err" || fail "q: no notice: $(cat "$T/err")"
grep -qxF "locked: 4 files (specs: all) -> $LT" "$T/out" || fail "q: locked line: $(cat "$T/out")"
spec B ' v2'
rc=$(run verify)
[ "$rc" -eq 1 ] && [ "$(cat "$T/out")" = "changed: $SB" ] || fail "q: B edit passed all-specs verify (rc $rc): $(cat "$T/out")"
spec B

# r) legacy lock without a "specs" key (record matches) -> all specs, as before
jq 'del(.specs)' "$L" > "$T/legacy" && cp "$T/legacy" "$L" && cp "$L" "$M"
rc=$(run verify)
[ "$rc" -eq 0 ] && grep -qxF 'ok: 4 locked files unchanged (specs: all)' "$T/out" || fail "r: legacy lock failed verify untouched (rc $rc): $(cat "$T/out" "$T/err")"
spec B ' v2'
rc=$(run verify)
[ "$rc" -eq 1 ] && [ "$(cat "$T/out")" = "changed: $SB" ] || fail "r: B edit passed legacy verify (rc $rc): $(cat "$T/out")"
spec B; clean

# s) guard with a --spec A lock: Edit on B free; Edit on A blocked (also ../, symlinked folder); any Bash write naming .learning/specs blocked
ge() { jq -n --arg d "${2:-$R}" --arg f "$1" '{tool_name:"Edit",cwd:$d,tool_input:{file_path:$f}}' |
  (HOME=$T XDG_STATE_HOME=$T/state bash "$TL" guard 2>"$T/err"); echo $?; }
run lock --spec $SA >/dev/null
[ "$(ge "$S/B.md")" -eq 0 ] || fail "s: Edit on unlocked spec B blocked ($(cat "$T/err"))"
[ "$(g "$R" "echo x > $SB")" -eq 2 ] || fail "s: Bash write naming .learning/specs (spec B) allowed"
[ "$(g "$R" "echo x > .learning/specs/mod/A.m?")" -eq 2 ] || fail "s: Bash write to locked spec A by glob allowed"
[ "$(ge "$S/A.md")" -eq 2 ] || fail "s: Edit on locked spec A allowed"
[ "$(ge "$S/nope/../A.md")" -eq 2 ] || fail "s: Edit on locked spec A via ../ allowed"
ln -s mod "$R/.learning/specs/alias"
[ "$(ge "$R/.learning/specs/alias/A.md")" -eq 2 ] || fail "s: Edit on locked spec A via symlinked folder allowed"
rm "$R/.learning/specs/alias"
[ "$(g "$R" "echo x > $SA")" -eq 2 ] || fail "s: Bash write to locked spec A allowed"
clean

# s2) guard with an "all" lock and a legacy lock: B blocked too
run lock >/dev/null
for kind in all legacy; do
  [ $kind = legacy ] && { jq 'del(.specs)' "$L" > "$T/legacy" && cp "$T/legacy" "$L"; }
  [ "$(jq -c .specs "$L")" = "$([ $kind = all ] && echo '"all"' || echo null)" ] || fail "s2: $kind lock setup wrong"
  [ "$(ge "$S/B.md")" -eq 2 ] || fail "s2: $kind lock, Edit on spec B allowed"
  [ "$(g "$R" "echo x > $SB")" -eq 2 ] || fail "s2: $kind lock, Bash write to spec B allowed"
  [ "$(g "$R" "echo x > .learning/specs/mod/C.md")" -eq 2 ] || fail "s2: $kind lock, Bash write to a new spec allowed"
done
clean

# t) corrupt "specs" with a matching record -> verify fails closed
run lock --spec $SA >/dev/null
cp "$M" "$T/good"
for v in '5' '["../x.md"]' '[".learning/specs/../../README.md"]'; do
  jq --argjson v "$v" '.specs = $v' "$M" > "$L" && cp "$L" "$M"
  rc=$(run verify)
  [ "$rc" -eq 1 ] && grep -q 'lock specs list is corrupt' "$T/err" || fail "t: verify rc $rc on specs $v: $(cat "$T/out" "$T/err")"
done
# a listed spec with no hash in "files" -> verify fails closed
jq --arg b "$SB" '.specs += [$b]' "$T/good" > "$L" && cp "$L" "$M"
rc=$(run verify)
[ "$rc" -eq 1 ] && grep -q 'a locked spec has no hash in the lock' "$T/err" || fail "t: verify rc $rc on unhashed spec: $(cat "$T/out" "$T/err")"
clean

# v) --spec file that cannot be hashed (unreadable) -> lock refused, no lock, no record
chmod 000 "$S/A.md"
rc=$(run lock --spec $SA)
chmod 644 "$S/A.md"
[ "$rc" -ne 0 ] && [ ! -e "$L" ] && [ ! -e "$M" ] || fail "v: lock written for an unhashable spec (rc $rc)"
grep -q 'a --spec file could not be hashed. Lock NOT written.' "$T/err" || fail "v: no refusal msg: $(cat "$T/err")"

# u) linked worktree: specs live in the main checkout; lock --spec A from the worktree
git -C "$R" add src e2e && git -C "$R" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm t || fail "u: commit"
W=$T/wt; git -C "$R" worktree add -q "$W" -b wt || fail "u: worktree add"
runw() { (cd "$W" && HOME=$T XDG_STATE_HOME=$T/state bash "$TL" "$@" >"$T/out" 2>"$T/err"); echo $?; }
rc=$(runw lock --spec $SA)
[ "$rc" -eq 0 ] || fail "u: lock from worktree rc $rc: $(cat "$T/err")"
spec B ' v2'
rc=$(runw verify)
[ "$rc" -eq 0 ] && grep -qxF "ok: 3 locked files unchanged (specs: $SA)" "$T/out" || fail "u: main-checkout B edit failed worktree verify (rc $rc): $(cat "$T/out" "$T/err")"
[ "$(ge "$S/B.md" "$W")" -eq 0 ] || fail "u: Edit on spec B from worktree blocked ($(cat "$T/err"))"
[ "$(ge "$S/A.md" "$W")" -eq 2 ] || fail "u: Edit on locked spec A from worktree allowed"
spec A ' v2'
rc=$(runw verify)
[ "$rc" -eq 1 ] && [ "$(cat "$T/out")" = "changed: $SA" ] || fail "u: A edit not caught from worktree (rc $rc): $(cat "$T/out")"

echo "PASS: 25 cases (a, b, b2, c, d, e, f, g, h, i, j, k, l, l2, m, n, o, p, q, r, s, s2, t, u, v)"
