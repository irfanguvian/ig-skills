#!/usr/bin/env bash
# PreToolUse Bash hook: heavy jobs (vitest, tsc, eslint, builds) must run via jobq so sessions queue. Parse failure = allow.

unq() { printf '%s' "$1" | tr '\001\002\003' '\n \t' | tr -d '\005'; } # decode a quoted or heredoc body kept by the awk pass

# heavy <command text>: true when any statement is a heavy job not started through jobq
heavy() {
  local stmts line w c f a b h
  # one statement per line, streamed per char: quote chars removed, quoted body kept in its word (blanks encoded), # comments dropped,
  # heredoc body put as one \005 word into the statement that holds its << (and into the next stage after a single |),
  # dropped when the heredoc sits in a quoted $(...); split on ; & | ( ) ` newline
  stmts=$(printf '%s\n' "$1" | awk -v sq="'" '
    function body(  x, s) { printf " \005"; for (x = hs; x < he; x++) { s = L[x] "\001"; gsub(/ /, "\002", s); gsub(/\t/, "\003", s); printf "%s", s }; printf " " }
    { L[NR] = $0 }
    END {
      for (r = 1; r <= NR; r = nx) {
        nx = r + 1 # next line to scan: moves past each heredoc body read from this line
        n = split(L[r] "\n", ch, "")
        for (i = 1; i <= n; i++) {
          c = ch[i]
          if (c == "<" && ch[i + 1] == "<" && ch[i - 1] != "<" && ch[i + 2] != "<" && (q == "" || (q == "\"" && d > 0))) { # heredoc start: unquoted, or inside "$(...)"
            j = i + 2; if (ch[j] == "-") j++
            while (ch[j] == " " || ch[j] == "\t") j++
            if (ch[j] == "\"" || ch[j] == sq) j++
            w = ""; while (ch[j] ~ /[A-Za-z0-9_]/) w = w ch[j++]
            if (w ~ /^[A-Za-z_]/) {
              hs = nx; for (he = nx; he <= NR; he++) { t = L[he]; sub(/^\t+/, "", t); if (t == w) break }
              nx = he + 1
              if (q == "") { body(); hp = 1 }
            }
          }
          if (q != "") {
            if (c == q) { q = ""; d = 0; continue }
            if (q == "\"") { if (c == "\\") c = ch[++i]; else if (c == "$" && ch[i + 1] == "(") d++; else if (c == ")" && d > 0) d-- }
            printf "%s", (c == "\n" ? "\001" : c == " " ? "\002" : c == "\t" ? "\003" : c); last = "x"
            continue
          }
          if (c == "\\") { i++; continue }
          if (c == "\"" || c == sq) { q = c; last = "x"; continue }
          if (c == "#" && last ~ /^[ \t\n]?$/) { i = n - 1; continue } # comment: skip to the line end
          if (index(";&|()`\n", c)) {
            p = (c == "|" && ch[i + 1] != "|" && ch[i - 1] != "|"); if (p && ch[i + 1] == "&") i++
            if (pd) { body(); pd = 0 } # cat <<EOF | bash: the stage after the pipe reads the body too
            printf "\n"; last = "\n"
            if (p && hp) pd = 1; else hp = 0
            continue
          }
          printf "%s", c; last = c
        }
      }
    }' | grep -aE 'vitest|tsc|eslint|next|nest|playwright|npm') || return 1 # a statement without a heavy word cannot be heavy

  while IFS= read -r line; do
    set -f; set -- $line; set +f
    while [ $# -gt 0 ]; do # strip launchers, their flags and numeric args, redirections, VAR=val, shell keywords
      case $1 in
        -u|-g|-s|-I|'<'|'>'|'>>'|[0-9]'>'|[0-9]'>>') shift; shift ;; # value-taking: env -u NAME, sudo -u USER, timeout -s SIG, xargs -I REPL, redirect target
        command) case $2 in -v|-V) break ;; esac; shift ;; # command -v only looks the name up
        npx|env|time|exec|nohup|timeout|gtimeout|nice|caffeinate|sudo|xargs|stdbuf|if|then|else|do|while|until|'!'|'{'|-*|[0-9]*|'<'*|'>'*|[A-Za-z_]*=*) shift ;;
        node) shift; while [ "${1#-}" != "$1" ]; do shift; done; [ $# -gt 0 ] && set -- "${1%.*js}" "${@:2}"; break ;;
        *) break ;;
      esac
    done
    case ${1##*/} in sh|bash|zsh) # bash [-x ..] test-lock.sh ...: read the script's args (-c flags stop: sh branch below; heredoc word skipped: big glob is slow)
      i=2; while [ $i -le $# ] && case ${!i} in -*c*) false ;; -*) true ;; *) false ;; esac; do i=$((i+1)); done
      [ $i -le $# ] && case ${!i} in $'\005'*) ;; *test-lock.sh) shift $((i-1)) ;; esac ;; esac
    case ${1##*/} in
      vitest|tsc|eslint) return 0 ;;
      test-lock.sh) # lock --check "<body>" runs the body via bash -c: re-check it
        while [ $# -gt 0 ]; do [ "$1" = --check ] && heavy "$(unq "${2:-}")" && return 0; shift; done ;;
      next|nest) [ "$2" = build ] && return 0 ;;
      playwright) [ "$2" = test ] && return 0 ;;
      sh|bash|zsh) # re-check the -c body, or a heredoc fed in as the script (no script file operand)
        shift; c=0 f=0 b='' h=''
        for w; do case $w in $'\005'*) h=$w ;; *[\<\>]*|--*) ;; -*c*) c=1 ;; -*) ;; *) if [ $c = 1 ]; then [ -n "$b" ] || b=$w; else f=1; fi ;; esac; done
        if [ $c = 1 ]; then heavy "$(unq "$b")" && return 0; elif [ $f = 0 ] && [ -n "$h" ]; then heavy "$(unq "$h")" && return 0; fi ;;
      eval) shift; heavy "$(unq "$*")" && return 0 ;;
      npm) # drop npm flags (and the values of value-taking ones) wherever they sit, then read subcommand + script
        shift; a=()
        while [ $# -gt 0 ]; do case $1 in --prefix|-w|--workspace|--loglevel|--cache|--userconfig) shift ;; -*) ;; *) a+=("$1") ;; esac; shift; done
        case ${a[0]} in
          t|test) return 0 ;;
          run|run-script) case ${a[1]} in build|test|lint|lint:ci|typecheck) return 0 ;; test:smoke*) ;; test:*) return 0 ;; esac ;;
          exec|x) heavy "${a[*]:1}" && return 0 ;;
        esac ;;
    esac
  done <<< "$stmts"
  return 1
}

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
case $cmd in *vitest*|*tsc*|*eslint*|*next*|*nest*|*playwright*|*npm*) ;; *) exit 0 ;; esac # no heavy word anywhere, bodies included: skip the parse
heavy "$cmd" || exit 0
echo 'heavy job: prefix with jobq and run it with run_in_background (sessions queue, low-RAM laptop), e.g. jobq npx vitest run <path>' >&2
exit 2
