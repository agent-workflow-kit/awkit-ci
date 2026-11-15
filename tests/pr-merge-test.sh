#!/usr/bin/env bash
# Tests for scripts/pr-merge, using fake `gh` and `guard` executables on a temp PATH.
# Never talks to GitHub and never merges anything: the fake `gh pr merge` only logs.
#
# Usage: tests/pr-merge-test.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/../scripts/pr-merge

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Isolate git and everything else from the user's real configuration.
export HOME=$work/home XDG_CONFIG_HOME=$work/home/.config GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$work/bin"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# Fixture: a bare "origin" with main and a PR head published as refs/pull/7/head,
# plus a clone to use as the target directory.
git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$work/clone" 2> /dev/null
(
  cd "$work/clone" || exit 1
  echo base > f && git add f && git commit -q -m base && git push -q origin main
  git checkout -q -b feature
  echo more >> f && git commit -q -am feature
  git push -q origin feature:refs/pull/7/head
)
head_sha=$(git -C "$work/clone" rev-parse feature)
base_sha=$(git -C "$work/clone" rev-parse main)
# A second clone that has never seen the PR commit (so the fallback must fetch it).
git clone -q "$work/origin.git" "$work/fresh" 2> /dev/null

cat > "$work/bin/gh" << 'FAKE'
#!/usr/bin/env bash
# Fake gh. Behavior is driven by FAKE_* environment variables; calls are logged.
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "repo view") echo "owner/repo" ;;
  "pr view")
    case "$*" in
      *headRefOid*) echo "$FAKE_HEAD" ;;
      *baseRefName*) echo "${FAKE_BASE:-main}" ;;
      *title,body*) printf 'PR title\n\nPR body\n' ;;
      *) exit 1 ;;
    esac
    ;;
  "pr checks") exit "${FAKE_CHECKS_RC:-0}" ;;
  "pr merge")
    # Refuse like GitHub does when the head moved.
    case "$*" in
      *"--match-head-commit $FAKE_CURRENT_HEAD"*) echo "MERGED" >> "$FAKE_LOG" ;;
      *) echo "head changed" >&2; exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE

cat > "$work/bin/guard" << 'FAKE'
#!/usr/bin/env bash
# Fake guard. FAKE_GUARD_PR: ok | toolarge | other.
echo "guard $*" >> "$FAKE_LOG"
case "$1" in
  pr)
    case "${FAKE_GUARD_PR:-ok}" in
      ok) exit 0 ;;
      toolarge)
        echo "gh: HTTP 406: Sorry, the diff exceeded the maximum number of lines (20000)" >&2
        exit 1
        ;;
      other)
        echo "gh: HTTP 500: server error" >&2
        exit 1
        ;;
    esac
    ;;
  range) exit "${FAKE_RANGE_RC:-0}" ;;
  text)
    cat > "$FAKE_TEXT_OUT"
    exit "${FAKE_TEXT_RC:-0}"
    ;;
esac
exit 2
FAKE
chmod +x "$work/bin/gh" "$work/bin/guard"

pass=0
fail=0
out=$work/out
export FAKE_LOG=$work/log FAKE_TEXT_OUT=$work/text

# run <target> [VAR=value ...]: runs pr-merge 7 with a fresh log and the fakes first on PATH.
run() {
  local target=$1
  shift
  : > "$FAKE_LOG"
  rm -f "$FAKE_TEXT_OUT"
  env PATH="$work/bin:$PATH" FAKE_HEAD="$head_sha" FAKE_CURRENT_HEAD="$head_sha" \
    "$@" "$script" "$target" 7 > "$out" 2>&1
  rc=$?
}

check() { # check <name> <condition-command...>
  local name=$1
  shift
  if "$@"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $name"
    echo "--- output ---"
    cat "$out"
    echo "--- log ---"
    cat "$FAKE_LOG"
    echo "--------------"
  fi
}

logged() { grep -q -- "$1" "$FAKE_LOG"; }
not_logged() { ! grep -q -- "$1" "$FAKE_LOG"; }
said() { grep -q -- "$1" "$out"; }
rc_is() { [ "$rc" -eq "$1" ]; }

# 1. guard pr succeeds: merge, no fallback.
run "$work/clone"
check "ok: exit 0" rc_is 0
check "ok: merged" logged MERGED
check "ok: no range scan" not_logged "guard range"
check "ok: names the guard pr route" said "route: guard pr"

# 2. guard pr fails with the size error; fallback clean (fresh clone, must fetch): merge.
run "$work/fresh" FAKE_GUARD_PR=toolarge
check "toolarge clean: exit 0" rc_is 0
check "toolarge clean: merged" logged MERGED
check "toolarge clean: range uses merge base..head" logged "guard range $base_sha..$head_sha"
check "toolarge clean: text scanned" logged "guard text -"
check "toolarge clean: title and body scanned" grep -q "PR body" "$FAKE_TEXT_OUT"
check "toolarge clean: names the fallback route" said "route: large-diff fallback"

# 3. Fallback finds something in the range: refuse.
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_RANGE_RC=1
check "range finding: exit 1" rc_is 1
check "range finding: not merged" not_logged MERGED
check "range finding: no merge attempt" not_logged "pr merge"

# 4. Fallback finds something in title/body: refuse.
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_TEXT_RC=1
check "text finding: exit 1" rc_is 1
check "text finding: not merged" not_logged "pr merge"

# 5. Fallback setup error from guard (exit 2): refuse.
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_RANGE_RC=2
check "range error: exit 1" rc_is 1
check "range error: not merged" not_logged "pr merge"

# 6. guard pr fails with another error: refuse, no fallback.
run "$work/clone" FAKE_GUARD_PR=other
check "other error: exit 1" rc_is 1
check "other error: no fallback" not_logged "guard range"
check "other error: not merged" not_logged "pr merge"

# 7. Size error but target is owner/repo with no clone: refuse with a clear message.
run owner/repo FAKE_GUARD_PR=toolarge
check "no clone: exit 1" rc_is 1
check "no clone: clear message" said "needs a local clone"
check "no clone: not merged" not_logged "pr merge"

# 8. Head changed after the guard: the merge is refused.
run "$work/clone" FAKE_CURRENT_HEAD=0000000000000000000000000000000000000000
check "head moved: exit 1" rc_is 1
check "head moved: not merged" not_logged MERGED
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_CURRENT_HEAD=0000000000000000000000000000000000000000
check "head moved (fallback): exit 1" rc_is 1
check "head moved (fallback): not merged" not_logged MERGED

# 9. The fetched PR head is not the commit gh reported (head moved mid-run): refuse.
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_HEAD="$base_sha"
check "fetched head differs: exit 1" rc_is 1
check "fetched head differs: no range scan" not_logged "guard range"

# 10. Checks failing still stops the merge after the fallback.
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_CHECKS_RC=1
check "checks fail: exit 1" rc_is 1
check "checks fail: not merged" not_logged "pr merge"

# 11. Usage errors keep exit status 2.
env PATH="$work/bin:$PATH" "$script" > "$out" 2>&1
rc=$?
: > "$FAKE_LOG"
check "usage: exit 2" rc_is 2

echo "pr-merge tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
