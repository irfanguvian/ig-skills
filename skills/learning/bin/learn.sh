#!/usr/bin/env bash
# learn.sh — tiny CLI over a project's .learning/ database.
#   learn.sh find [--brief] <terms...>   word hits: INDEX rows, DOC notes, DEC/SES lines, NODE lines. <= 16 lines; --brief (pre-search hook) <= 3 INDEX + 3 DOC.
#   learn.sh build [dir]       rebuild INDEX.md + graph.json (contract) + graphify-out/graph.json (native)
#   learn.sh migrate [dir]     build + backfill frontmatter contract on existing notes
#   learn.sh vault export [--out DIR] [--graph PATH]   Obsidian vault from graph.json (default .learning/vault)
#   learn.sh hooks install|uninstall|status            per-repo hooks in .claude/settings.local.json
#   learn.sh doctor [--fix] | fix                      check hooks/scripts/INDEX health, --fix repairs
#   learn.sh status            doc counts, last session line
# Local only. Never reads the whole database into stdout.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); LR="${LR%/.git}"
L="${LEARNING_DIR:-${LR:+$LR/}.learning}" # linked worktree -> main checkout
cmd="${1:-status}"; shift || true

# python that has graphify. cached. pyenv shims lie per-dir, so resolve real binaries.
# -I on every inline python: the caller's cwd is untrusted, a repo json.py/graphify.py must not run
CACHE="$HERE/.python"
PY=""
if [ -f "$CACHE" ] && "$(cat "$CACHE")" -I -c 'import graphify' 2>/dev/null; then PY=$(cat "$CACHE"); else
  for c in python3 "$HOME"/.pyenv/versions/*/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    command -v "$c" >/dev/null 2>&1 && "$c" -I -c 'import graphify' 2>/dev/null && { PY=$(command -v "$c"); echo "$PY" > "$CACHE"; break; }
  done
fi
PY="${PY:-python3}"
# one writer per DB: main checkout + worktree sessions rebuild from post-edit at the same time
locked() { if [ -x /usr/bin/lockf ] && [ -d "$1" ]; then /usr/bin/lockf -k -t 25 "$1/.build.lock" "${@:2}"; else "${@:2}"; fi; }

case "$cmd" in
  build)
    locked "${1:-$L}" "$PY" "$HERE/learn-build.py" "${1:-$L}"
    ;;
  migrate)
    locked "${1:-$L}" "$PY" "$HERE/learn-build.py" "${1:-$L}" --migrate
    ;;
  vault)
    "$PY" "$HERE/learn-vault.py" "$@" --learning "$L"
    ;;
  hooks)
    # git post-checkout seed: a linked worktree gets the main checkout's local Claude config (never its own .learning/)
    GH="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/hooks/post-checkout"
    case "${1:-status}" in
      install)
        if [ -n "${GH%/hooks/post-checkout}" ]; then
          if [ ! -e "$GH" ]; then cp "$HERE/../hooks/learning-git-post-checkout.sh" "$GH"; chmod +x "$GH"; echo "git post-checkout installed -> $GH (worktrees seed from main checkout)"
          elif ! grep -q learning-worktree-seed "$GH"; then echo "problem: $GH exists and is not ours -> merge $HERE/../hooks/learning-git-post-checkout.sh into it by hand"; fi
        fi;;
      uninstall) [ -f "$GH" ] && grep -q learning-worktree-seed "$GH" && rm "$GH" && echo "git post-checkout removed";;
      *) [ -f "$GH" ] && grep -q learning-worktree-seed "$GH" && echo "git post-checkout: installed" || echo "git post-checkout: not installed";;
    esac
    "$PY" -I - "${1:-status}" "$HOME/.claude/hooks" <<'PYEOF'
import json, sys
from pathlib import Path
action, hdir = sys.argv[1], sys.argv[2]
f = Path(".claude/settings.local.json")
s = json.loads(f.read_text()) if f.exists() else {}
hooks = s.setdefault("hooks", {})
WANT = [("SessionStart", None, "learning-session-start.sh", None),
        ("PreToolUse", "Grep|Glob|Bash", "learning-pre-search.sh", 10),
        ("PostToolUse", "Edit|Write|MultiEdit", "learning-post-edit.sh", 30),
        ("Stop", None, "learning-stop.sh", 10)]
def has(ev, script): return any(script in json.dumps(e) for e in hooks.get(ev, []))
if action == "install":
    for ev, matcher, script, to in WANT:
        if has(ev, script): continue
        h = {"type": "command", "command": f"bash {hdir}/{script}"}
        if to: h["timeout"] = to
        e = {"hooks": [h]}
        if matcher: e["matcher"] = matcher
        hooks.setdefault(ev, []).append(e)
    f.parent.mkdir(exist_ok=True)
    f.write_text(json.dumps(s, indent=2) + "\n")
    print(f"hooks installed -> {f} (local, not committed). restart session to activate.")
elif action == "uninstall":
    for ev in list(hooks):
        hooks[ev] = [e for e in hooks[ev] if "learning-" not in json.dumps(e)]
        if not hooks[ev]: del hooks[ev]
    if not hooks: s.pop("hooks", None)
    if f.exists(): f.write_text(json.dumps(s, indent=2) + "\n")
    print(f"hooks removed from {f}")
else:
    print("installed: " + ", ".join(ev for ev, _, sc, _ in WANT if has(ev, sc)) if any(has(ev, sc) for ev, _, sc, _ in WANT) else "hooks: not installed (learn.sh hooks install)")
PYEOF
    ;;
  doctor|fix)
    [ "$cmd" = "fix" ] && set -- --fix "$@"
    LEARN_SH="$HERE/learn.sh" "$PY" -I - "${LEARNING_HOOKS_DIR:-$HERE/../hooks}" "$HOME/.claude/hooks" "$L" "$@" <<'PYEOF'
import filecmp, json, os, re, shutil, subprocess, sys, time
from pathlib import Path
canon, live, L = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
FIX = "--fix" in sys.argv[4:]
LEARN_SH = os.environ["LEARN_SH"]
SCRIPTS = ["learning-session-start.sh", "learning-pre-search.sh", "learning-post-edit.sh", "learning-stop.sh"]
EVENTS = {"learning-session-start.sh": "SessionStart", "learning-pre-search.sh": "PreToolUse",
          "learning-post-edit.sh": "PostToolUse", "learning-stop.sh": "Stop"}
bad = fixed = 0
def ok(m): print("ok: " + m)
def problem(m, hint=""):
    global bad; bad += 1; print("problem: " + m + (" -> " + hint if hint else ""))
def did(m):
    global fixed; fixed += 1; print("fixed: " + m)
def run_learn(*args):
    return subprocess.run(["bash", LEARN_SH, *args], capture_output=True, text=True).returncode

# 1. database
if (L / "INDEX.md").exists(): ok("database %s" % L)
else: problem("no %s/INDEX.md" % L, "/learning onboard")

# 2. hook scripts match the copies this skill ships
for sc in SCRIPTS:
    c, v = canon / sc, live / sc
    if not c.exists(): problem("canonical %s missing from skill" % sc); continue
    if v.exists() and filecmp.cmp(c, v, shallow=False): ok("script %s current" % sc); continue
    why = "missing" if not v.exists() else "stale"
    if FIX:
        live.mkdir(parents=True, exist_ok=True); shutil.copy2(c, v); os.chmod(v, 0o755)
        did("%s (%s) restored from skill" % (sc, why))
    else: problem("%s %s" % (sc, why), "/learning fix")

# 3. hooks registered for this repo
f = Path(".claude/settings.local.json")
def registered():
    s = json.loads(f.read_text()) if f.exists() else {}
    h = s.get("hooks", {})
    return h, [sc for sc in SCRIPTS if sc not in json.dumps(h.get(EVENTS[sc], []))]
hooks, missing = registered()
if missing:
    if FIX and run_learn("hooks", "install") == 0 and not registered()[1]:
        hooks = registered()[0]; did("registered %d hook(s) in %s" % (len(missing), f))
    elif FIX: problem("hooks install failed for: %s" % ", ".join(missing), "run learn.sh hooks install from the repo root")
    else: problem("hooks not registered: %s" % ", ".join(missing), "/learning fix")
else: ok("4 hooks registered in %s" % f)

# 3b. git post-checkout seed (only in a git repo): worktrees must inherit the local config and write to the main .learning/
gd = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True).stdout.strip()
if gd:
    gh = Path(gd) / "hooks" / "post-checkout"
    if gh.exists() and "learning-worktree-seed" in gh.read_text(): ok("git post-checkout seeds worktrees (%s)" % gh)
    elif gh.exists(): problem("%s exists and is not ours" % gh, "merge hooks/learning-git-post-checkout.sh into it by hand")
    elif FIX and run_learn("hooks", "install") == 0 and gh.exists(): did("git post-checkout installed at %s" % gh)
    else: problem("git post-checkout missing at %s" % gh, "/learning fix")

# 3c. linked worktree: the seed copied local config ONCE at checkout, later main-checkout changes never arrive
if gd and Path(gd).name == ".git":
    root = Path(gd).parent.resolve()
    top = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True).stdout.strip()).resolve()
    if top == root: ok("main checkout, worktree sync n/a")
    else:
        # hooks only: Claude Code writes the worktree's own "always allow" rules into permissions
        ms, ws = root / ".claude" / "settings.local.json", top / ".claude" / "settings.local.json"
        def load(f):
            try: return json.loads(f.read_text()) if f.exists() else {}
            except ValueError as e: problem("%s is not valid JSON (%s), worktree hooks not compared" % (f, e), "fix it by hand")
        m, w = load(ms), load(ws)
        mh = m.get("hooks") if m is not None else None
        if m is None or w is None: pass
        elif w.get("hooks") == mh: ok("worktree hooks match main checkout (%s)" % ws)
        elif FIX:
            if mh is None: w.pop("hooks", None)
            else: w["hooks"] = mh
            ws.parent.mkdir(exist_ok=True); ws.write_text(json.dumps(w, indent=2) + "\n")
            did("worktree hooks replaced from main checkout, rest of %s kept" % ws)
        else: problem("worktree hooks differ from main checkout (%s)" % ws, "/learning fix")
        # same file set the post-checkout seed copies
        mds = subprocess.run(["find", ".", "-maxdepth", "3", "-name", "CLAUDE.local.md", "-not", "-path", "*/node_modules/*"],
                             cwd=root, capture_output=True, text=True).stdout.split()
        drift = [m[2:] for m in mds if not (top / m).exists() or not filecmp.cmp(root / m, top / m, shallow=False)]
        for rel in drift:
            if FIX:
                (top / rel).parent.mkdir(parents=True, exist_ok=True); bak = ""
                if (top / rel).exists() and (top / rel).stat().st_mtime > (root / rel).stat().st_mtime:
                    bak = "%s.bak-%s" % (rel, time.strftime("%Y%m%d%H%M%S")); shutil.copy2(top / rel, top / bak)
                shutil.copy2(root / rel, top / rel)
                did("%s copied from main checkout%s" % (rel, ", worktree edit (newer) kept as " + bak if bak else ""))
            else: problem("%s differs from main checkout" % rel, "/learning fix")
        if not drift: ok("%d CLAUDE.local.md match main checkout" % len(mds))

# 4. Stop chain: the hook that actually runs must not gate on the shared stop_hook_active flag
st = live / "learning-stop.sh"
if not st.exists(): st = canon / "learning-stop.sh"
code = [l for l in st.read_text().splitlines() if not l.lstrip().startswith("#")] if st.exists() else []
others = [e for e in hooks.get("Stop", []) if "learning-" not in json.dumps(e)]
if any("stop_hook_active" in l for l in code):
    problem("%s gates on stop_hook_active; any other blocking Stop hook masks it for the whole session" % st,
            "per-session counter instead")
elif others: ok("%d other Stop hook(s) present, cannot mask the save nag" % len(others))
else: ok("Stop chain clean")

# 5. INDEX freshness
idx = L / "INDEX.md"
if idx.exists():
    notes = [p for p in L.rglob("*.md") if "vault" not in p.parts and "graphify-out" not in p.parts and p.name != "INDEX.md"]
    stale = [p for p in notes if p.stat().st_mtime > idx.stat().st_mtime]
    if not stale: ok("INDEX fresh (%d notes)" % len(notes))
    elif FIX and run_learn("build", str(L)) == 0: did("INDEX rebuilt")
    elif FIX: problem("INDEX rebuild failed", "run learn.sh build by hand")
    else: problem("INDEX older than %d note(s)" % len(stale), "/learning fix")

# 6. another machine's home dir left in this repo's settings (report only, intent unknown)
me = Path.home().name
seen = False
for name in ("settings.json", "settings.local.json"):
    g = Path(".claude") / name
    if not g.exists(): continue
    seen = True
    dead = set(re.findall(r"/Users/([^/\"\s]+)", g.read_text())) - {me, "Shared"}
    if dead: problem("%s references another machine's home: %s" % (g, ", ".join(sorted(dead))), "edit by hand, intent unknown")
    else: ok("%s has no foreign absolute paths" % g)
if not seen: ok("no .claude/settings*.json here, foreign-path check skipped")

print("verdict: %s" % ("clean" if not bad else ("%d fixed, %d left" % (fixed, bad) if fixed else "%d problem(s) — /learning fix" % bad)))
sys.exit(1 if bad else 0)
PYEOF
    exit $?
    ;;
  find)
    BRIEF=""; [ "${1:-}" = --brief ] && { BRIEF=1; shift; }
    [ -d "$L" ] || { echo "no $L"; exit 0; }
    [ $# -gt 0 ] || { echo "usage: learn.sh find [--brief] <terms...>"; exit 1; }
    # terms: alnum words >2 chars, no English stopword (same list as the pre-search hook), distinct (any case), max 5
    TERMS=$(printf '%s ' "$@" | tr -c '[:alnum:]_\n' ' ' | tr ' ' '\n' | awk 'length>2 && tolower($0) !~ /^(not|the|and|for|with|from|this|that|are|was|were|has|have|into|onto|than|then|them|they|what|when|where|which|while|will|would|should|could|only|also|just|like|very|more|most|some|such|each|other|over|under|same|both)$/ && !s[tolower($0)]++' | head -5 | tr '\n' ' ')
    [ -n "$TERMS" ] || exit 0
    # term < 5 chars: whole word + common endings ("lock" hits "locked", not "clock"); 5+ chars: word prefix
    # ("subscription" hits "subscriptionStatus"). Terms are [[:alnum:]_] only, so no regex escaping
    WB='[^[:alnum:]_]'; END='(s|es|d|ed|ing)?'
    # stdin lines (or '## S-' blocks with arg "block") -> "score<TAB>line<TAB>text", score = distinct terms hit
    rank() { awk -v terms="$TERMS" -v block="${1:-}" -v wb="$WB" -v end="$END" '
      BEGIN { n = split(tolower(terms), T, " "); for (i = 1; i <= n; i++) R[i] = "(^|" wb ")" T[i] (length(T[i]) >= 5 ? "" : end "(" wb "|$)") }
      function flush(  s, k) { s = 0; for (k in hit) s++; if (s && h != "") print s "\t" hn "\t" h; split("", hit) }
      block && /^## S-/ { flush(); h = $0; hn = NR }
      !block { h = $0; hn = NR }
      { l = tolower($0); for (i = 1; i <= n; i++) if (l ~ R[i]) hit[i] = 1 }
      !block { flush() }
      END { flush() }'; }
    # --brief: 3 INDEX rows cut 200, 3 DOC lines (min 1 term); DEC/SES/graph never computed
    NI=5; ND=4; IC=""
    [ -z "$BRIEF" ] || { NI=3; ND=3; IC=200; }
    OUT=$(
      grep '^| ' "$L/INDEX.md" 2>/dev/null | grep -vE '^\| id \||\| doc \|' | rank | sort -k1,1nr -k2,2n | head -$NI | cut -f3- | cut -c1-$IC | sed 's/^/INDEX /'
      # options before the path: BSD grep stops option parsing at the first operand
      for t in $TERMS; do
        grep -rilE --include='*.md' --exclude-dir=vault --exclude-dir=graphify-out -- "(^|$WB)$t$([ ${#t} -ge 5 ] || printf %s "$END($WB|\$)")" "$L" 2>/dev/null
      done | grep -vE '/(INDEX|SESSIONS|DECISIONS)\.md$' | sort | uniq -c | sort -rn | head -$ND | awk -v L="$L/" '{sub(L,"",$2); print "DOC " $2 " (" $1 " hits)"}'
      [ -n "$BRIEF" ] && exit 0
      # SESSIONS/DECISIONS match nearly any term: name the best lines, not the file
      grep '^- D-' "$L/DECISIONS.md" 2>/dev/null | rank | sort -k1,1nr -k2,2nr | head -3 | cut -f3- | cut -c1-200 | sed 's/^/DEC /'
      cat "$L/SESSIONS.md" 2>/dev/null | rank block | sort -k1,1nr -k2,2n | head -2 | cut -f3- | sed 's/^## /SES /'
      if [ -f "$L/graphify-out/graph.json" ]; then
        # graphify returns the same top nodes for any query: keep only NODE lines naming a term (EDGE lines: bytes, rarely followed)
        "$PY" -I -m graphify query "$TERMS" --graph "$L/graphify-out/graph.json" --budget "${LEARN_BUDGET:-3000}" 2>/dev/null | grep -iE "(^|$WB)($(printf '%s' "${TERMS% }" | tr ' ' '|'))$END($WB|\$)" | grep -E '^NODE' | head -2
      fi
    )
    [ -z "$OUT" ] || printf '%s\n' "$OUT"
    # on-demand lookups only; the pre-search hook logs its own
    if [ "${LEARNING_CALLER:-}" != hook ]; then
      SID="${CLAUDE_CODE_SESSION_ID:-}"
      { jq -nc --arg ts "$(date -u +%FT%TZ)" --arg sid "${SID:0:8}" --arg root "$(cd "$L/.." && pwd)" --arg cwd "$PWD" --arg terms "${TERMS% }" \
          --argjson hits "$(printf '%s' "$OUT" | grep -c .)" --argjson bytes "${#OUT}" \
          '{ts:$ts,ev:"find",sid:$sid,root:$root,cwd:$cwd,terms:$terms,hits:$hits,bytes:$bytes}' >> "$HOME/.claude/learning-metrics.jsonl"; } 2>/dev/null
    fi
    ;;
  stats)
    # hook telemetry: learn.sh stats [days] [--here]. Data: ~/.claude/learning-metrics.jsonl (hook-appended).
    M="$HOME/.claude/learning-metrics.jsonl"
    [ -s "$M" ] || { echo "no metrics yet ($M empty) — hooks fire on next session"; exit 0; }
    DAYS=30; HERE_ONLY=""
    for a in "$@"; do case "$a" in --here) HERE_ONLY="${LR:-$PWD}";; ''|*[!0-9]*) ;; *) DAYS="$a";; esac; done
    # --here = this repo: lines rooted here, or cwd in the root, a subdir, or a linked worktree
    WTS=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | jq -Rsc 'split("\n") | map(select(. != ""))')
    CUT=$(date -u -v-"${DAYS}"d +%FT%TZ 2>/dev/null || date -u -d "-${DAYS} days" +%FT%TZ)
    jq -rs --arg cut "$CUT" --arg here "$HERE_ONLY" --argjson wts "${WTS:-[]}" --argjson days "$DAYS" '
      def kb: map(.bytes // 0) | add // 0 | . / 1024 * 10 | floor / 10;
      def pct(a; b): if b == 0 then 0 else (a * 100 / b | floor) end;
      def mine: (.cwd // "") as $c | .root == $here or any(($wts + [$here])[]; . as $w | $c == $w or ($c | startswith($w + "/")));
      map(select(.ts >= $cut and ($here == "" or mine))) as $e |
      ($e | map(select(.ev=="pre-search"))) as $p |
      ($p | map(select(.dup))) as $pd |
      # lines without root predate the fix: their hits counted graph noise, so they are not rated
      ($p | map(select(.root and (.dup | not)))) as $pr |
      ($pr | map(select(.hits > 0))) as $ph |
      ($e | map(select(.ev=="find-call"))) as $fc |
      ($e | map(select(.ev=="find"))) as $f |
      ($e | map(select(.ev=="stop"))) as $s |
      ($e | map(select(.ev=="session-start"))) as $ss |
      ($e | map(select(.root and (.sid // "") != "")) | group_by(.sid)) as $ts |
      ($ts | map(select(any(.[]; .ev=="pre-search") and all(.[]; .ev!="find-call")))) as $nofc |
      pct($ph|length; $pr|length) as $rate |
      ([(if ($pr|length) >= 10 and $rate < 20 then "LOW real hit rate (\($rate)%) — DB stale or terms mismatch, rebuild INDEX or enrich notes" else empty end),
        (if ($ts|length) >= 5 and ($fc|length) == 0 then "LOW on-demand — 0 learn.sh find calls across \($ts|length) sessions" else empty end)]) as $low |
      "window: last \($days)d\(if $here != "" then "  project: \($here)" else "" end)  events: \($e|length)",
      "session-start: \($ss|length) fires, \($ss|kb) KB injected",
      "auto-inject: \($p|length) lookups, \($ph|length) real hits of \($pr|length) rated (\($rate)%), \($pd|length) dup skipped (\($pd|map({bytes:.saved})|kb) KB saved), \($p|kb) KB injected, \($p|map(select(.root|not))|length) legacy unrated",
      "on-demand: \($fc|length) find-calls, \($f|length) finds, \($f|map(select(.hits > 0))|length) hit (\(pct($f|map(select(.hits > 0))|length; $f|length))%)",
      "by agent (auto/on-demand): \(($p + $fc) | group_by(.agent // "main") | map({a:(.[0].agent // "main"), p:(map(select(.ev=="pre-search"))|length), c:(map(select(.ev=="find-call"))|length)}) | sort_by(-(.p + .c)) | .[0:8] | map("\(.a) \(.p)/\(.c)") | join("  "))",
      "sessions with pre-search, zero find-call: \($nofc|length) of \($ts|length) tracked",
      "context cost: ~\((($p + $ss) | map(.bytes // 0) | add // 0) / 4 | floor) tokens injected total",
      "post-edit rebuilds: \($e|map(select(.ev=="post-edit-build"))|length)",
      "stop: \($s|map(select(.blocked))|length) blocked (save nag), \($s|map(select(.blocked|not))|length) clean",
      "top projects: \($e | group_by(.root // .cwd) | map({c:(.[0].root // .[0].cwd),n:length}) | sort_by(-.n) | .[0:5] | map("\(.c) (\(.n))") | join("  "))",
      (if ($e|length) == 0 then "verdict: no events in window — hooks not firing? learn.sh doctor"
       elif ($low|length) > 0 then "verdict: " + ($low | join("; "))
       else "verdict: healthy" end)
    ' "$M"
    ;;
  status)
    [ -d "$L" ] || { echo "no $L — run /learning onboard"; exit 0; }
    echo "docs: $(find "$L" -name '*.md' -not -path '*/graphify-out/*' -not -path '*/vault/*' -not -name INDEX.md | wc -l | tr -d ' ')  modules: $(ls "$L/modules" 2>/dev/null | wc -l | tr -d ' ')  decisions: $(grep -c '^- D-' "$L/DECISIONS.md" 2>/dev/null || echo 0)  sessions: $(grep -c '^## S-' "$L/SESSIONS.md" 2>/dev/null || echo 0)"
    grep -m1 '^## S-' "$L/SESSIONS.md" 2>/dev/null | sed 's/^/last: /'
    [ -f .claude/settings.local.json ] && grep -q learning- .claude/settings.local.json && echo "hooks: installed (.claude/settings.local.json)" || echo "hooks: NOT installed — learn.sh hooks install"
    ;;
  *)
    echo "usage: learn.sh {find <terms>|build [dir]|migrate [dir]|vault export [--out DIR]|hooks install|uninstall|status|doctor [--fix]|fix|stats [days] [--here]|status}"; exit 1;;
esac
exit 0
