#!/bin/sh
# learning-worktree-seed — installed by `learn.sh hooks install` into <repo>/.git/hooks/post-checkout.
# New linked worktree: copy the gitignored local Claude config from the main checkout so the learning
# hooks + local rules fire there. The DB itself is NOT copied: hooks and learn.sh resolve .learning/
# at the main checkout (git-common-dir), so every worktree writes to the parent tree.
root=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); root=${root%/.git}
top=$(git rev-parse --show-toplevel 2>/dev/null)
[ -z "$root" ] || [ -z "$top" ] || [ "$top" = "$root" ] && exit 0
seed() { [ -f "$root/$1" ] && [ ! -e "$top/$1" ] && mkdir -p "$top/$(dirname "$1")" && cp "$root/$1" "$top/$1"; }
seed .claude/settings.local.json
for f in $(cd "$root" && find . -maxdepth 3 -name CLAUDE.local.md -not -path '*/node_modules/*' | sed 's#^\./##'); do seed "$f"; done
exit 0
