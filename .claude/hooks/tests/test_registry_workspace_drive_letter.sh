#!/bin/bash
# Regression test for OmarAraby/apexyard#7: registry `workspace:` values and
# git-dir pointers (`gitdir:`, `commondir`) in a Windows drive-letter spelling
# (C:/Users/x/repo, C:\Users\x\repo) are ABSOLUTE. Before the fix the
# active-ticket lib tested only for a leading "/", so such a value was
# concatenated onto the ops root and never matched, and every Windows linked
# worktree failed with "git dir failed validation".
#
# (_AT_MOK is 0 when a tree validates and 1 when it fails.)
# Part A is string-level and runs on every platform: it checks the
# classification (drive-letter absolute, drive-relative `C:foo` still
# relative, mirroring _portfolio_resolve in _lib-portfolio-paths.sh).
# Part B needs real drive-letter paths. It runs only where `pwd -W` exists
# (Git Bash / MSYS) and prints SKIP elsewhere, because on Linux/macOS
# "C:/x" is just an unrelated relative path and cannot name a real clone.
set -u

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HOOKS="$SRC_ROOT/.claude/hooks"
export APEXYARD_OPS_DISABLE_PIN=1 APEXYARD_DISABLE_RESOLUTION_CACHE=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

PASS=0
FAIL=0
ok() { echo "PASS [$1]"; PASS=$((PASS + 1)); }
bad() { echo "FAIL [$1]: $2" >&2; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
. "$HOOKS/_lib-active-ticket.sh"

B=$(mktemp -d)
B=$(cd -P "$B" && pwd)
trap 'rm -rf "$B"' EXIT

mkrepo() {
  git init -q -b main "$1" 2>/dev/null || git init -q "$1"
  git -C "$1" commit -q --allow-empty -m init
}

OPS="$B/ops"
WS="$OPS/workspace"
mkrepo "$OPS"
: > "$OPS/.apexyard-fork"
: > "$OPS/onboarding.yaml"
mkdir -p "$WS"

write_registry() {
  {
    printf 'version: 1\nprojects:\n'
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
    printf 'defaults:\n  status: active\n'
  } > "$OPS/apexyard.projects.yaml"
}

ctx() {
  active_ticket_set_context "$OPS" "$WS"
  _AT_REG="$OPS/apexyard.projects.yaml"
  _at_memo_clear
}

# ---- Part A: classification, all platforms --------------------------------
write_registry \
  '  - name: pa' '    repo: org/pa' '    workspace: C:/proj/with space/pa' \
  '  - name: pb' '    repo: org/pb' '    workspace: D:\proj\pb' \
  '  - name: pc' '    repo: org/pc' '    workspace: C:rel/pc' \
  '  - name: pd' '    repo: org/pd' '    workspace: rel/pd'
ctx

active_ticket_project_clone pa
if [ "$REPLY" = "C:/proj/with space/pa" ]; then ok "A1 drive-letter forward-slash workspace is absolute"; else bad "A1" "REPLY=$REPLY"; fi
active_ticket_project_clone pb
if [ "$REPLY" = 'D:\proj\pb' ]; then ok "A2 drive-letter backslash workspace is absolute"; else bad "A2" "REPLY=$REPLY"; fi
active_ticket_project_clone pc
if [ "$REPLY" = "$OPS/C:rel/pc" ]; then ok "A3 drive-relative C:rel stays relative to the ops root"; else bad "A3" "REPLY=$REPLY"; fi
active_ticket_project_clone pd
if [ "$REPLY" = "$OPS/rel/pd" ]; then ok "A4 plain relative workspace is unchanged"; else bad "A4" "REPLY=$REPLY"; fi

# ---- Part B: real drive-letter paths, MSYS / Git Bash only -----------------
if ! WINOPS=$(cd "$OPS" && pwd -W 2>/dev/null) || [ -z "$WINOPS" ]; then
  echo "SKIP [B] no 'pwd -W': real drive-letter paths need Git Bash / MSYS (Part A covers classification)"
else
  mkrepo "$B/clone"
  WT="$B/wt"
  git -C "$B/clone" worktree add -q "$WT" -b wt1
  WINCLONE=$(cd "$B/clone" && pwd -W)
  WINWT=$(cd "$WT" && pwd -W)
  case "$WINCLONE" in [A-Za-z]:/*) ;; *) bad "B0" "pwd -W gave $WINCLONE" ;; esac

  # B1: registry workspace: in drive-letter form validates the main clone.
  write_registry '  - name: pe' '    repo: org/pe' "    workspace: $WINCLONE"
  ctx
  _AT_MOK=""; _AT_MWHY=""
  _at_validate_w "$B/clone"
  if [ "${_AT_MOK:-}" = 0 ]; then ok "B1 drive-letter registry workspace validates its main clone"; else bad "B1" "MOK=${_AT_MOK:-} MWHY=${_AT_MWHY:-}"; fi

  # B2: its linked worktree validates (git for Windows writes gitdir: C:/...).
  gitdir_line=$(cat "$WT/.git")
  case "$gitdir_line" in
    "gitdir: "[A-Za-z]:/*) ok "B2a git wrote a drive-letter gitdir pointer (the failing input)" ;;
    *) printf 'gitdir: %s/.git/worktrees/wt\n' "$WINCLONE" > "$WT/.git" ;;
  esac
  _at_memo_clear
  _AT_MOK=""; _AT_MWHY=""
  _at_validate_w "$WT"
  if [ "${_AT_MOK:-}" = 0 ]; then ok "B2 linked worktree with drive-letter gitdir validates"; else bad "B2" "MOK=${_AT_MOK:-} MWHY=${_AT_MWHY:-}"; fi

  # B3: drive-letter commondir pointer is absolute too.
  printf '%s/.git\n' "$WINCLONE" > "$B/clone/.git/worktrees/wt/commondir"
  _at_memo_clear
  _AT_MOK=""; _AT_MWHY=""
  _at_validate_w "$WT"
  if [ "${_AT_MOK:-}" = 0 ]; then ok "B3 drive-letter commondir validates"; else bad "B3" "MOK=${_AT_MOK:-} MWHY=${_AT_MWHY:-}"; fi
  : "$WINOPS" "$WINWT"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
