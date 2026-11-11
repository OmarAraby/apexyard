#!/bin/bash
# Tests for limit-reviewer-writes.sh (me2resh/apexyard#1840, AgDR-0266).
#
# A review agent may use the Write tool only for its review body under
# <ops-root>/.claude/session/reviews/bodies/. Every other edit-channel write
# by a review agent is blocked. Other callers are not affected.
#
# Part 1 runs the hook alone. Part 2 runs every hook that settings.json wires
# to the Write tool, and then the Bash dispatcher on the commands that post
# the body and write the marker. A body that quotes push, commit, alias and
# redirect text must pass with no block.
#
# bash 3.2 compatible.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
TMP_RAW=$(mktemp -d "${TMPDIR:-/tmp}/apexyard-reviewer-writes.XXXXXX")
TMP=$(cd "$TMP_RAW" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# --- Fixture: an ops root with the hook and its libraries --------------------
OPS="$TMP/ops"
mkdir -p "$OPS/.claude/hooks" "$OPS/.claude/session/reviews/bodies" "$OPS/.claude/session/active-reviewers/s1"
: > "$OPS/.apexyard-fork"
git -C "$OPS" init -q
for f in limit-reviewer-writes.sh _lib-review-markers.sh _lib-path-resolve.sh _lib-ops-root.sh _lib-read-config.sh; do
  cp "$SRC_ROOT/.claude/hooks/$f" "$OPS/.claude/hooks/"
done
printf '{}\n' > "$OPS/.claude/settings.json"
: > "$OPS/README.md"
HOOK="$OPS/.claude/hooks/limit-reviewer-writes.sh"
BODIES="$OPS/.claude/session/reviews/bodies"

BODY_TEXT='## Code Review

The probe ran `git push origin HEAD:main` and `git commit -m "x" > /tmp/out`.
It also ran `git -c alias.p="!sh -c true" p` and `cat <<EOF > hooks.sh`.
The gate blocked each command. Reviewed commit: 0123456789abcdef0123456789abcdef01234567'

# payload <agent_type> <tool> <path> [content] -> one PreToolUse JSON payload.
# An agent_type of "-" means a main-thread call (no agent fields).
# An agent_type of "untyped" means a sub-agent with no type.
payload() {
  local atype="$1" tool="$2" path="$3" content="${4:-x}"
  case "$atype" in
    -) jq -cn --arg t "$tool" --arg p "$path" --arg c "$content" --arg cwd "$OPS" \
         '{session_id:"s1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$p,content:$c}}' ;;
    untyped) jq -cn --arg t "$tool" --arg p "$path" --arg c "$content" --arg cwd "$OPS" \
         '{agent_id:"a1",session_id:"s1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$p,content:$c}}' ;;
    *) jq -cn --arg a "$atype" --arg t "$tool" --arg p "$path" --arg c "$content" --arg cwd "$OPS" \
         '{agent_type:$a,agent_id:"a1",session_id:"s1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:$t,tool_input:{file_path:$p,content:$c}}' ;;
  esac
}

# expect <name> <allowed|blocked> <payload>
expect() {
  local name="$1" want="$2" input="$3" out rc
  out=$(cd "$OPS" && printf '%s' "$input" | CLAUDE_CODE_SESSION_ID=s1 /bin/bash "$HOOK" 2>&1)
  rc=$?
  if [ "$want" = allowed ] && [ "$rc" -eq 0 ]; then
    ok "$name"
  elif [ "$want" = blocked ] && [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '^BLOCKED:'; then
    ok "$name"
  else
    bad "$name (want=$want rc=$rc out=$out)"
  fi
}

# --- Part 1: the hook alone --------------------------------------------------
BODY="$BODIES/me2resh__apexyard__42-rex.md"
for agent in code-reviewer security-reviewer; do
  expect "$agent: Write of a body that quotes command text is allowed" allowed \
    "$(payload "$agent" Write "$BODY" "$BODY_TEXT")"
  expect "$agent: Write of a body in a new sub-folder is allowed" allowed \
    "$(payload "$agent" Write "$BODIES/run-2/me2resh__apexyard__42-security.md")"
  expect "$agent: Write of a repo file is blocked" blocked \
    "$(payload "$agent" Write "$OPS/README.md")"
  expect "$agent: Write of a new docs file is blocked" blocked \
    "$(payload "$agent" Write "$OPS/docs/new.md")"
  expect "$agent: Write of a hook file is blocked" blocked \
    "$(payload "$agent" Write "$OPS/.claude/hooks/limit-reviewer-writes.sh")"
  expect "$agent: Write of settings.json is blocked" blocked \
    "$(payload "$agent" Write "$OPS/.claude/settings.json")"
  expect "$agent: Write of a CEO marker is blocked" blocked \
    "$(payload "$agent" Write "$OPS/.claude/session/reviews/me2resh__apexyard__42-ceo.approved")"
  expect "$agent: Write of an architecture marker is blocked" blocked \
    "$(payload "$agent" Write "$OPS/.claude/session/reviews/me2resh__apexyard__42-architecture.approved")"
  expect "$agent: Write of a Rex marker through Write is blocked" blocked \
    "$(payload "$agent" Write "$OPS/.claude/session/reviews/me2resh__apexyard__42-rex.approved")"
  expect "$agent: Write of an active-reviewer marker is blocked" blocked \
    "$(payload "$agent" Write "$OPS/.claude/session/active-reviewers/s1/me2resh__apexyard__42-rex")"
  expect "$agent: Write outside the ops root is blocked" blocked \
    "$(payload "$agent" Write "$TMP/elsewhere.md")"
  expect "$agent: Edit of a repo file is blocked" blocked \
    "$(payload "$agent" Edit "$OPS/README.md")"
  expect "$agent: MultiEdit of a hook file is blocked" blocked \
    "$(payload "$agent" MultiEdit "$OPS/.claude/hooks/_lib-review-markers.sh")"
done

expect "a .. segment that leaves the body folder is blocked" blocked \
  "$(payload code-reviewer Write "$BODIES/../me2resh__apexyard__42-ceo.approved")"
expect "a .. segment that stays in the body folder is blocked" blocked \
  "$(payload code-reviewer Write "$BODIES/x/../y.md")"
expect "a relative body path is blocked" blocked \
  "$(payload code-reviewer Write ".claude/session/reviews/bodies/x.md")"
expect "the body folder itself is blocked" blocked \
  "$(payload code-reviewer Write "$BODIES/")"
expect "a payload with no target is blocked" blocked \
  "$(jq -cn '{agent_type:"code-reviewer",agent_id:"a1",tool_name:"Write",tool_input:{content:"x"}}')"

ln -s "$OPS/.claude/settings.json" "$BODIES/link.md"
expect "a symbolic link in the body folder is blocked" blocked \
  "$(payload code-reviewer Write "$BODIES/link.md")"
rm -f "$BODIES/link.md"

# A body folder that is a link to the hooks folder resolves outside it.
mv "$BODIES" "$TMP/bodies.real"
ln -s "$OPS/.claude/hooks" "$BODIES"
expect "a body folder that links to the hooks folder is blocked" blocked \
  "$(payload code-reviewer Write "$BODIES/dispatch-bash.sh")"
rm -f "$BODIES"
mv "$TMP/bodies.real" "$BODIES"

# Other callers are not limited by this hook.
expect "the orchestrator may write a repo file" allowed "$(payload - Write "$OPS/README.md")"
expect "a build agent may write a repo file" allowed "$(payload backend-engineer Write "$OPS/README.md")"
expect "an untyped sub-agent with no active review may write a repo file" allowed \
  "$(payload untyped Write "$OPS/README.md")"
: > "$OPS/.claude/session/active-reviewers/s1/me2resh__apexyard__42-rex"
expect "an untyped sub-agent during an active review cannot write a repo file" blocked \
  "$(payload untyped Write "$OPS/README.md")"
expect "an untyped sub-agent during an active review may write a body" allowed \
  "$(payload untyped Write "$BODY")"
rm -f "$OPS/.claude/session/active-reviewers/s1/me2resh__apexyard__42-rex"

# A payload that is not JSON fails closed only when it names a review agent.
expect "a broken payload from a review agent is blocked" blocked \
  '{"agent_type":"code-reviewer","tool_name":"Write","tool_input":{"file_path":'
expect "a broken payload from another caller is not blocked" allowed \
  '{"tool_name":"Write","tool_input":{"file_path":'

# With the review-markers library missing, the built-in list still applies.
mv "$OPS/.claude/hooks/_lib-review-markers.sh" "$TMP/lib.bak"
expect "no markers library: a review agent repo write is blocked" blocked \
  "$(payload security-reviewer Write "$OPS/README.md")"
expect "no markers library: a review agent body write is allowed" allowed \
  "$(payload security-reviewer Write "$BODY")"
expect "no markers library: a build agent is not blocked" allowed \
  "$(payload backend-engineer Write "$OPS/README.md")"
mv "$TMP/lib.bak" "$OPS/.claude/hooks/_lib-review-markers.sh"

# review_body_path builds a name in the sanctioned folder.
got=$(/bin/bash -c '. "$1/.claude/hooks/_lib-review-markers.sh" && review_body_path me2resh/apexyard 42 rex "$1"' _ "$OPS")
if [ "$got" = "$BODY" ]; then ok "review_body_path names the sanctioned body file"; else bad "review_body_path printed '$got'"; fi
expect "the review_body_path file is allowed" allowed "$(payload code-reviewer Write "$got")"

# --- Windows drive-letter paths (OmarAraby/apexyard#4) ----------------------
# Claude Code on Windows sends C:\... or C:/... . A fake cygpath maps drive Z:
# onto $TMP so these cases run on every host, not only on Windows.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/cygpath" <<'FAKE'
#!/bin/bash
[ "${1:-}" = -u ] || exit 1
shift
[ "${1:-}" = -- ] && shift
case "${1:-}" in
  [Zz]:\\*|[Zz]:/*) rest=${1#??}; printf '%s%s\n' "$FAKE_DRIVE_ROOT" "$(printf '%s' "$rest" | tr '\\' '/')" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$FAKEBIN/cygpath"
OLD_PATH=$PATH
export FAKE_DRIVE_ROOT="$TMP"
PATH="$FAKEBIN:$PATH"
REL_OPS=${OPS#"$TMP"}
WIN_BS="Z:$(printf '%s' "$REL_OPS" | tr '/' '\\')"
WIN_FS="Z:$REL_OPS"
BODY_NAME=me2resh__apexyard__42-rex.md

expect "windows: a body as Z:\\... is allowed" allowed \
  "$(payload code-reviewer Write "$WIN_BS\\.claude\\session\\reviews\\bodies\\$BODY_NAME")"
expect "windows: a body as Z:/... is allowed" allowed \
  "$(payload code-reviewer Write "$WIN_FS/.claude/session/reviews/bodies/$BODY_NAME")"
: > "$OPS/.claude/session/active-reviewers/s1/me2resh__apexyard__42-rex"
expect "windows: an untyped sub-agent during an active review may write a body" allowed \
  "$(payload untyped Write "$WIN_BS\\.claude\\session\\reviews\\bodies\\$BODY_NAME")"
rm -f "$OPS/.claude/session/active-reviewers/s1/me2resh__apexyard__42-rex"
expect "windows: a repo file as Z:\\... is blocked" blocked \
  "$(payload code-reviewer Write "$WIN_BS\\README.md")"
expect "windows: a hook file as Z:/... is blocked" blocked \
  "$(payload security-reviewer Write "$WIN_FS/.claude/hooks/limit-reviewer-writes.sh")"
expect "windows: a CEO marker as Z:\\... is blocked" blocked \
  "$(payload code-reviewer Write "$WIN_BS\\.claude\\session\\reviews\\me2resh__apexyard__42-ceo.approved")"
expect "windows: a path outside the ops root is blocked" blocked \
  "$(payload code-reviewer Write "Z:\\elsewhere.md")"
expect "windows: a .. segment that leaves the body folder is blocked" blocked \
  "$(payload code-reviewer Write "$WIN_BS\\.claude\\session\\reviews\\bodies\\..\\me2resh__apexyard__42-ceo.approved")"
expect "windows: a .. segment that stays in the body folder is blocked" blocked \
  "$(payload code-reviewer Write "$WIN_BS\\.claude\\session\\reviews\\bodies\\x\\..\\y.md")"
expect "windows: a . segment with forward slashes is blocked" blocked \
  "$(payload code-reviewer Write "$WIN_FS/.claude/session/reviews/bodies/./y.md")"
expect "windows: a drive-relative path is blocked" blocked \
  "$(payload code-reviewer Write "Z:bodies\\$BODY_NAME")"
expect "windows: an Edit of a repo file as Z:\\... is blocked" blocked \
  "$(payload code-reviewer Edit "$WIN_BS\\README.md")"
expect "windows: the orchestrator is not limited" allowed \
  "$(payload - Write "$WIN_BS\\README.md")"

# With the path library missing, a drive-letter path stays unconverted and
# fails closed.
mv "$OPS/.claude/hooks/_lib-path-resolve.sh" "$TMP/path-lib.bak"
expect "windows: no path library: a body as Z:\\... is blocked" blocked \
  "$(payload code-reviewer Write "$WIN_BS\\.claude\\session\\reviews\\bodies\\$BODY_NAME")"
mv "$TMP/path-lib.bak" "$OPS/.claude/hooks/_lib-path-resolve.sh"
PATH=$OLD_PATH
unset FAKE_DRIVE_ROOT

# On a real Windows host, also check the real cygpath and the real drive.
if command -v cygpath >/dev/null 2>&1 && REAL_WIN=$(cygpath -w "$OPS" 2>/dev/null) && [ -n "$REAL_WIN" ]; then
  expect "real windows: a body as C:\\... is allowed" allowed \
    "$(payload code-reviewer Write "$REAL_WIN\\.claude\\session\\reviews\\bodies\\$BODY_NAME")"
  expect "real windows: a body as C:/... is allowed" allowed \
    "$(payload code-reviewer Write "$(printf '%s' "$REAL_WIN" | tr '\\' '/')/.claude/session/reviews/bodies/$BODY_NAME")"
  expect "real windows: a .. segment is blocked before cygpath collapses it" blocked \
    "$(payload code-reviewer Write "$REAL_WIN\\.claude\\session\\reviews\\bodies\\x\\..\\y.md")"
  expect "real windows: a repo file is blocked" blocked \
    "$(payload code-reviewer Write "$REAL_WIN\\README.md")"
else
  echo "SKIP: real windows cases (no cygpath on this host)"
fi

# --- Part 2: every Write-channel hook, then the Bash dispatcher --------------
FULL="$TMP/full"
mkdir -p "$FULL/.claude" "$FULL/.claude/session/active-reviewers/s1" "$TMP/pins"
cp -R "$SRC_ROOT/.claude/hooks" "$FULL/.claude/"
cp "$SRC_ROOT/.claude/settings.json" "$FULL/.claude/"
: > "$FULL/.apexyard-fork"
git -C "$FULL" init -q
: > "$FULL/.claude/session/active-reviewers/s1/me2resh__apexyard__42-rex"
FULL_BODY="$FULL/.claude/session/reviews/bodies/me2resh__apexyard__42-rex.md"

WRITE_HOOKS=$(jq -r '.hooks.PreToolUse[] | select(.matcher as $m | "Write" | test("^(" + $m + ")$")) | .hooks[].command' "$FULL/.claude/settings.json" \
  | grep -oE '[A-Za-z0-9_.-]+\.sh' | sort -u)
case "$WRITE_HOOKS" in
  *limit-reviewer-writes.sh*) ok "settings.json wires limit-reviewer-writes.sh to the Write tool" ;;
  *) bad "settings.json does not wire limit-reviewer-writes.sh to the Write tool"; WRITE_HOOKS="" ;;
esac
[ -n "$WRITE_HOOKS" ] || { echo ""; echo "Results: $PASS passed, $((FAIL + 1)) failed"; exit 1; }

for agent in code-reviewer security-reviewer; do
  input=$(jq -cn --arg a "$agent" --arg p "$FULL_BODY" --arg c "$BODY_TEXT" --arg cwd "$FULL" \
    '{agent_type:$a,agent_id:"a1",session_id:"s1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$p,content:$c}}')
  all_ok=1
  for h in $WRITE_HOOKS; do
    out=$(cd "$FULL" && printf '%s' "$input" | CLAUDE_CODE_SESSION_ID=s1 /bin/bash "$FULL/.claude/hooks/$h" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -q 'BLOCKED'; then
      all_ok=0
      bad "$agent: Write-channel hook $h blocked the body write (rc=$rc out=$out)"
    fi
  done
  [ "$all_ok" -eq 1 ] && ok "$agent: no Write-channel hook blocks a body that quotes command text"

  input=$(jq -cn --arg a "$agent" --arg p "$FULL/.claude/settings.json" --arg cwd "$FULL" \
    '{agent_type:$a,agent_id:"a1",session_id:"s1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$p,content:"{}"}}')
  blocked=0
  for h in $WRITE_HOOKS; do
    (cd "$FULL" && printf '%s' "$input" | CLAUDE_CODE_SESSION_ID=s1 /bin/bash "$FULL/.claude/hooks/$h" >/dev/null 2>&1) || blocked=1
  done
  if [ "$blocked" -eq 1 ]; then ok "$agent: the Write-channel hooks block a settings.json write"; else bad "$agent: no Write-channel hook blocked a settings.json write"; fi
done

# The reviewer posts the body by path and writes its marker in Bash.
for cmd in ". .claude/hooks/_lib-tracker.sh; tracker_review_submit me2resh/apexyard 42 comment $FULL_BODY" \
           "review_write_rex_approved $FULL_BODY 0123456789abcdef0123456789abcdef01234567 $FULL/.claude/session/reviews/me2resh__apexyard__42-rex.approved"; do
  input=$(jq -cn --arg c "$cmd" --arg cwd "$FULL" \
    '{agent_type:"code-reviewer",agent_id:"a1",session_id:"s1",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c}}')
  out=$(cd "$FULL" && printf '%s' "$input" | CLAUDE_CODE_SESSION_ID=s1 /bin/bash "$FULL/.claude/hooks/dispatch-bash.sh" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'BLOCKED'; then
    ok "dispatcher allows: ${cmd%% *} ..."
  else
    bad "dispatcher blocked '$cmd' (rc=$rc out=$out)"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
