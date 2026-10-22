#!/usr/bin/env bash
# jobq self-test: guard table, queue race, nesting, exit passthrough, wait timeout, dir ownership. Exits 1 on any failure.
here=$(cd "$(dirname "$0")" && pwd)
JOBQ_DIR=$(mktemp -d); export JOBQ_DIR
trap 'rm -rf "$JOBQ_DIR"' EXIT
jobq="$here/jobq" fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $2, got $3)"; fail=1; fi; }
hook() { jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$here/jobq-guard.sh"; }
guard() { hook "$1" 2>/dev/null; echo $?; }
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
nl=$'\n'

deny=(
  'npx vitest run src/x'
  'cd apps/backend && npx vitest run src/x'
  'FOO=1 npx tsc --noEmit'
  'node ./node_modules/vitest/vitest.mjs run src/x'
  'npx eslint src/a.ts src/b.ts'
  'npm run build'
  'npm --prefix apps/frontend run lint:ci'
  'npm run typecheck 2>&1 | tail -20'
  'npm test'
  'npm run test:e2e'
  'npx next build --turbopack'
  'npx nest build'
  'cd apps/playwright; npx playwright test'
  'ls | head; ./node_modules/.bin/tsc -p .'
  "cat > f <<EOF${nl}x${nl}EOF${nl}npx tsc"
  # launchers
  'timeout 600 npx vitest run x'
  'gtimeout 600 npx tsc'
  'timeout -s KILL 60 npx tsc'
  'nice -n 10 npx vitest run x'
  'caffeinate -i npm run build'
  'command npx tsc --noEmit'
  'sudo npm run build'
  'git ls-files | xargs npx eslint'
  'env -u FOO npx tsc'
  'stdbuf -oL npx vitest run x'
  # shell -c bodies and eval
  'bash -c "npx vitest run x"'
  "sh -c 'cd apps/backend && npm test'"
  'zsh -lc "npm run build"'
  'eval "npx tsc"'
  "bash -c \"bash -c 'npx tsc'\""
  # test-lock.sh lock --check body runs via bash -c
  'test-lock.sh lock --check "npx eslint a.ts"'
  'bash ~/.claude/hooks/test-lock.sh lock --check "npx eslint a.ts && npx tsc --noEmit"'
  '/bin/bash -x ~/.claude/hooks/test-lock.sh lock --check "npx eslint a.ts"'
  # npm forms
  'npm t'
  'npm exec vitest run x'
  'npm x -- tsc'
  'npm run --prefix apps/frontend build'
  'npm run -w apps/backend test'
  'npm --loglevel silent run build'
  'npm --cache /tmp/c test'
  'npm --userconfig ./x.npmrc run lint'
  # heredoc start inside a plain string or a comment is not a heredoc
  "echo \"a <<EOF\"${nl}npx vitest run x"
  "# usage: foo <<EOF${nl}npx vitest run x"
  # heredoc fed to a shell is commands
  "bash <<'EOF'${nl}npx vitest run x${nl}EOF"
  "sh -s <<EOF${nl}npm run build${nl}EOF"
  "zsh <<EOF${nl}cd apps/backend && npx tsc${nl}EOF"
  "cat <<EOF | bash${nl}npx tsc${nl}EOF"
  "sudo bash <<EOF${nl}npx tsc${nl}EOF"
  "bash <<EOF && echo done${nl}npx tsc${nl}EOF"
  "cat > a <<A; bash <<B${nl}x${nl}A${nl}npx tsc${nl}B"
  # quoted command word
  '"bash" -c "npx tsc"'
  "'npx' vitest run x"
  'npm run "build"'
  # leading redirect
  '2>/dev/null npx vitest run x'
  '>out.log npm run build'
  '> out.log npm run build'
  '2> err.log npx tsc'
)
allow=(
  'grep -rn vitest src'
  'cat vitest.config.ts'
  'echo "npm run build"'
  'git commit -m "fix tsc error"'
  'git commit -m "a; npm run build"'
  'ls node_modules/.bin/eslint'
  'npm run dev'
  'npm run test:smoke'
  'node scripts/report.mjs'
  'npx prisma generate'
  'npx next dev'
  'jobq npx vitest run src/x'
  'cd apps/backend && jobq npx vitest run src/x 2>&1 | tail -50'
  'FOO=1 jobq npx tsc --noEmit'
  'timeout 600 jobq npx tsc'
  'jobq bash -c "npx vitest run x"'
  'test-lock.sh lock --check "jobq npx eslint a.ts"'
  'bash ~/.claude/hooks/test-lock.sh lock --check "jobq npx eslint a.ts && jobq npx tsc --noEmit"'
  'bash -c "npm run dev"'
  'bash scripts/deploy.sh'
  'ls # (vitest) is slow'
  "# step 1; npm run build later${nl}ls"
  'echo $# ${x#a}; ls'
  'command -v vitest'
  'command -v tsc >/dev/null && echo ok'
  "cat > f.sh <<'EOF'${nl}npx vitest run src/x${nl}EOF"
  "git commit -m \"\$(cat <<'EOF'${nl}npm run build passes${nl}EOF${nl})\""
  "gh pr create --body \"\$(cat <<'EOF'${nl}npx vitest run x passes${nl}EOF${nl})\""
  "cat > docs/x.md <<EOF${nl}npx tsc${nl}EOF"
  "bash scripts/seed.sh <<EOF${nl}npx tsc${nl}EOF"
  "jobq bash <<'EOF'${nl}npx vitest run x${nl}EOF"
  "bash <<EOF${nl}npm run dev${nl}EOF"
  "cat > f.md <<EOF && sh${nl}npm run build${nl}EOF"
  "cat > f.md <<EOF; bash -l${nl}npx tsc${nl}EOF"
  "cat > f <<EOF${nl}x${nl}EOF${nl}# npx tsc later"
)
for c in "${deny[@]}"; do check "deny:  ${c//$nl/\\n}" 2 "$(guard "$c")"; done
for c in "${allow[@]}"; do check "allow: ${c//$nl/\\n}" 0 "$(guard "$c")"; done
check "allow: not json (fail open)" 0 "$(echo 'not json' | bash "$here/jobq-guard.sh" 2>/dev/null; echo $?)"
check "deny message says jobq + run_in_background" 1 "$(hook 'npx tsc' 2>&1 | grep -c '^heavy job: prefix with jobq and run it with run_in_background ')"

# guard speed on ~300 KB commands: no heavy word (prefilter) and heavy words inside a body (full parse must stay linear)
rep() { perl -e 'print join("\n", ($ARGV[0]) x int(300000 / length($ARGV[0])))' "$1"; } # one line repeated to ~300 KB
speed() { # speed <name> <limit ms> <command>
  local t0 t rc
  t0=$(ms); rc=$(guard "$3"); t=$(( $(ms) - t0 ))
  check "speed: ${#3} B $1 command allowed in < $2 ms (got $t)" "0 1" "$rc $([ $t -lt "$2" ] && echo 1 || echo 0)"
}
speed no-heavy-word 500 "python3 -c \"$(rep 'x = (1, 2); print(x) # loop')\""
speed heavy-words-in-body 2000 "python3 -c \"$(rep "print('npm run build', 'npx tsc'); x = (1, 2)  # vitest")\""
speed heredoc-to-bash 2000 "bash <<'EOF'${nl}$(rep 'echo npm run build is next')${nl}EOF"

# queue race: two 2 s jobs started together must run back to back
t0=$(ms)
"$jobq" sh -c 'sleep 2' 2>"$JOBQ_DIR/a.err" &
"$jobq" sh -c 'sleep 2' 2>"$JOBQ_DIR/b.err" &
sleep 1
"$jobq" status | grep -Eq '^[0-9]{2}:[0-9]{2}:[0-9]{2} pid=[0-9]+ sid=[^ ]* cwd=/[^ ]* cmd=sh -c sleep 2$'
check "status shows holder line while running" 0 $?
wait
wall=$(( $(ms) - t0 ))
check "race: exactly one prints queued line + run_in_background hint" 1 "$(grep -l '^jobq: queued behind .*cmd=sh -c sleep 2 (run jobq with run_in_background' "$JOBQ_DIR"/a.err "$JOBQ_DIR"/b.err | wc -l | tr -d ' ')"
check "race: wall >= 4000 ms (got ${wall})" 1 "$([ "$wall" -ge 4000 ] && echo 1 || echo 0)"

JOBQ_WAIT=2 "$jobq" bash -c "\"$jobq\" true"
check "nested jobq runs inside the held lock, no self-wait" 0 $?

# pid reuse: holder names a live pid that is no longer a jobq -> no shortcut, queue as usual
sleep 3 & spid=$!
lockf -k "$JOBQ_DIR/lock" sleep 1 &
sleep 0.3
printf '00:00:00 pid=%s sid=x cwd=/ cmd=x\n' "$spid" > "$JOBQ_DIR/holder"
JOBQ_HELD=$spid JOBQ_WAIT=0 "$jobq" true 2>/dev/null
check "nested shortcut refuses a live pid that is not jobq" 75 $?
kill $spid; wait 2>/dev/null; : > "$JOBQ_DIR/holder"

# a background child that outlives its job must queue again, not reuse the finished job's lock
"$jobq" sh -c '(sleep 1; "$0" sh -c "echo child ran") >"$1" 2>&1 &' "$jobq" "$JOBQ_DIR/leak.out"
"$jobq" sh -c 'sleep 2'
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'child ran' "$JOBQ_DIR/leak.out" && [ "$("$jobq" status)" = idle ] && break; sleep 0.3; done
check "background child of a finished job queues behind the next holder" 1 "$(grep -c '^jobq: queued behind .*cmd=sh -c sleep 2 (' "$JOBQ_DIR/leak.out")"

check "job keeps the caller umask" 0022 "$(umask 022; "$jobq" sh -c umask)"

"$jobq" sh -c 'exit 3'
check "exit passthrough 3" 3 $?
"$jobq" sh -c 'echo run >> "$JOBQ_DIR/runs"; exit 75'
check "command exit 75 passes through" 75 $?
check "command exit 75 ran once, not retried" 1 "$(wc -l < "$JOBQ_DIR/runs" | tr -d ' ')"

"$jobq" sh -c 'sleep 3' &
sleep 1
msg=$(JOBQ_WAIT=1 "$jobq" true 2>&1); rc=$?
check "wait timeout exits 75" 75 $rc
check "wait timeout prints give-up line" 1 "$(printf '%s\n' "$msg" | grep -c '^jobq: gave up after 1s')"
wait

JOBQ_DIR="$JOBQ_DIR/new" "$jobq" true
check "new lock dir is 700" 700 "$(stat -f %Lp "$JOBQ_DIR/new")"
check "holder file is 600" 600 "$(stat -f %Lp "$JOBQ_DIR/new/holder")"
mkdir -m 755 "$JOBQ_DIR/old"; JOBQ_DIR="$JOBQ_DIR/old" "$jobq" true
check "existing 755 lock dir tightened to 700" 700 "$(stat -f %Lp "$JOBQ_DIR/old")"
JOBQ_DIR=/usr "$jobq" true 2>/dev/null
check "refuses a dir it does not own" 70 $?
ln -s "$JOBQ_DIR" "$JOBQ_DIR/lnk"
JOBQ_DIR="$JOBQ_DIR/lnk" "$jobq" true 2>/dev/null
check "refuses a symlinked dir" 70 $?

check "status idle afterwards" idle "$("$jobq" status)"
[ $fail = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $fail
