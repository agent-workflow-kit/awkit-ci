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
# plus a clone to use as the target directory. The PR has a plain commit, a commit
# adding a .gitattributes with `* -diff` and a file with an added line, and a merge
# commit as head. An unrelated branch "orphan" has no merge base with main.
git init -q --bare -b main "$work/origin.git"
git clone -q "$work/origin.git" "$work/clone" 2> /dev/null
(
  cd "$work/clone" || exit 1
  echo base > f && git add f && git commit -q -m base && git push -q origin main
  git checkout -q -b side && echo side > s && git add s && git commit -q -m side
  git checkout -q -b feature main
  echo more >> f && git commit -q -am feature
  printf '* -diff\n' > .gitattributes && echo ADDED_SECRET_LINE > g
  git add .gitattributes g && git commit -q -m attrs
  git merge -q --no-ff -m merge side
  git push -q origin feature:refs/pull/7/head
  orphan=$(git commit-tree -m orphan "$(git mktree < /dev/null)")
  git push -q origin "$orphan:refs/heads/orphan"
)
head_sha=$(git -C "$work/clone" rev-parse feature)
base_sha=$(git -C "$work/clone" rev-parse main)
# A second clone that has never seen the PR commit (so the fallback must fetch it).
git clone -q "$work/origin.git" "$work/fresh" 2> /dev/null
# A clone whose origin no longer exists (the fetch must fail).
git clone -q "$work/origin.git" "$work/badorigin" 2> /dev/null
git -C "$work/badorigin" remote set-url origin "$work/does-not-exist.git"
# A user-level AWKIT_GUARD must never leak into the runs below.
export AWKIT_GUARD=/nonexistent/user-guard

cat > "$work/bin/gh" << 'FAKE'
#!/usr/bin/env bash
# Fake gh. Behavior is driven by FAKE_* environment variables; calls are logged.
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "repo view") echo "owner/repo" ;;
  "pr view")
    case "$*" in
      *mergeCommit*)
        # Post-merge re-check: state, merge commit oid, head oid (tab-separated).
        [ -z "${FAKE_VIEW_FAIL:-}" ] || exit 1
        printf '%s\t%s\t%s\n' "${FAKE_VIEW_STATE-OPEN}" "${FAKE_VIEW_MERGE-}" "${FAKE_VIEW_HEAD-$FAKE_CURRENT_HEAD}"
        ;;
      *headRefOid*) echo "$FAKE_HEAD" ;;
      *baseRefName*)
        [ -z "${FAKE_BASE_FAIL:-}" ] || exit 1
        echo "${FAKE_BASE-main}"
        ;;
      *title,body*) printf 'PR title\n\nPR body\n' ;;
      *) exit 1 ;;
    esac
    ;;
  "pr checks") exit "${FAKE_CHECKS_RC:-0}" ;;
  "pr merge")
    # FAKE_MERGE_RC_AFTER: merge, then exit non-zero like gh does when its branch
    # cleanup fails (the merge itself has happened).
    if [ -n "${FAKE_MERGE_RC_AFTER:-}" ]; then
      echo "MERGED" >> "$FAKE_LOG"
      echo "gh: HTTP 404: Reference does not exist (deleteRef)" >&2
      exit "$FAKE_MERGE_RC_AFTER"
    fi
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
      near1)
        echo "gh: HTTP 406: diff too big" >&2
        exit 1
        ;;
      near2)
        echo "gh: HTTP 500: maximum number of lines in the response reached" >&2
        exit 1
        ;;
    esac
    ;;
  range)
    # Report what a real scan would see: cwd, git env, the commits and added lines.
    {
      echo "range-pwd $PWD"
      echo "range-worktree ${GIT_WORK_TREE:-}"
      echo "range-index ${GIT_INDEX_FILE:-}"
      echo "range-commits $(git rev-list "$2" | wc -l | tr -d ' ')"
      if git log -p --format=%H "$2" | grep -q '^+ADDED_SECRET_LINE'; then echo "range-saw-added"; fi
    } >> "$FAKE_LOG"
    exit "${FAKE_RANGE_RC:-0}"
    ;;
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

# run <target> [VAR=value ...]: runs pr-merge 7 with a fresh log and the fakes first on
# PATH, AWKIT_GUARD pinned to the fake (overridable), from $RUN_CWD if set.
run() {
  local target=$1
  shift
  : > "$FAKE_LOG"
  rm -f "$FAKE_TEXT_OUT"
  (
    cd "${RUN_CWD:-.}" || exit 99
    env PATH="$work/bin:$PATH" AWKIT_GUARD="$work/bin/guard" \
      FAKE_HEAD="$head_sha" FAKE_CURRENT_HEAD="$head_sha" \
      "$@" "$script" "$target" 7 > "$out" 2>&1
  )
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
logval() { sed -n "s/^$1 //p" "$FAKE_LOG" | head -n 1; }
# The range scan ran in an empty temp dir used as work tree and index home, and the
# dir is gone afterwards.
range_isolated() {
  local p w i
  p=$(logval range-pwd)
  w=$(logval range-worktree)
  i=$(logval range-index)
  [ -n "$p" ] && [ "$p" = "$w" ] && [ "$i" = "$p/idx" ] && [ "$p" != "$work/clone" ] && [ ! -e "$p" ]
}

abs_scan_paths() {
  case $(logval range-worktree) in /*) ;; *) return 1 ;; esac
  case $(logval range-index) in /*) ;; *) return 1 ;; esac
}

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

# 12. The range scan runs in an empty work tree: it sees every PR commit (including
# the merge-commit head) and the added line despite the checked-out `-diff` attribute.
run "$work/clone" FAKE_GUARD_PR=toolarge
check "range env: isolated empty work tree, removed afterwards" range_isolated
check "range env: sees all 4 commits" logged "range-commits 4"
check "range env: sees the added line despite -diff" logged "range-saw-added"
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_RANGE_RC=1
check "range env (finding): temp dir removed after die" range_isolated

# 13. A relative AWKIT_GUARD is canonicalized before entering the target, so a
# same-named file in the target is never run.
# shellcheck disable=SC2016 # the log path must expand when the impostor runs
printf '#!/usr/bin/env bash\necho IMPOSTOR >> "$FAKE_LOG"\nexit 0\n' > "$work/clone/g"
chmod +x "$work/clone/g"
cp "$work/bin/guard" "$work/bin/g"
RUN_CWD="$work/bin" run "$work/clone" FAKE_GUARD_PR=toolarge AWKIT_GUARD=./g
check "relative guard: exit 0" rc_is 0
check "relative guard: impostor in target not run" not_logged IMPOSTOR
check "relative guard: range ran with the real guard" logged "guard range"
rm -f "$work/clone/g"

# 14. Unrelated failures close to the trigger text take no fallback.
for mode in near1 near2; do
  run "$work/clone" FAKE_GUARD_PR=$mode
  check "$mode: exit 1" rc_is 1
  check "$mode: no fallback" not_logged "guard range"
  check "$mode: not merged" not_logged "pr merge"
done

# 15. Fallback prerequisites failing: fetch error, unreadable/empty base, no merge base.
run "$work/badorigin" FAKE_GUARD_PR=toolarge
check "fetch fails: exit 1" rc_is 1
check "fetch fails: no range scan" not_logged "guard range"
check "fetch fails: not merged" not_logged "pr merge"
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_BASE_FAIL=1
check "base unreadable: exit 1" rc_is 1
check "base unreadable: no range scan" not_logged "guard range"
check "base unreadable: not merged" not_logged "pr merge"
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_BASE=
check "base empty: exit 1" rc_is 1
check "base empty: no range scan" not_logged "guard range"
check "base empty: not merged" not_logged "pr merge"
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_BASE=orphan
check "no merge base: exit 1" rc_is 1
check "no merge base: no range scan" not_logged "guard range"
check "no merge base: not merged" not_logged "pr merge"

# 16. The user's AWKIT_GUARD (exported above as a nonexistent path) is not inherited.
run "$work/clone"
check "guard pinned: exit 0 with a bogus user AWKIT_GUARD" rc_is 0

# 17. Base advanced past the merge base: the range still starts at the old merge base.
git clone -q "$work/origin.git" "$work/adv" 2> /dev/null
(cd "$work/adv" && echo newer > n && git add n && git commit -q -m newer && git push -q origin main)
new_main=$(git -C "$work/adv" rev-parse HEAD)
run "$work/clone" FAKE_GUARD_PR=toolarge
check "base advanced: exit 0" rc_is 0
check "base advanced: range starts at old merge base" logged "guard range $base_sha..$head_sha"
check "base advanced: new base tip not used" not_logged "$new_main"

# 12. A bare AWKIT_GUARD that is executable only in the cwd (not on PATH) is a clear
# error, not a guard path of "$PWD/".
mkdir -p "$work/cwdonly"
cp "$work/bin/guard" "$work/cwdonly/cwdguard"
RUN_CWD="$work/cwdonly" run "$work/clone" FAKE_GUARD_PR=toolarge AWKIT_GUARD=cwdguard
check "bare guard not on PATH: exit 1" rc_is 1
check "bare guard not on PATH: clear error" said "not found on PATH"
check "bare guard not on PATH: no guard run" not_logged "guard "
check "bare guard not on PATH: not merged" not_logged "pr merge"

# 12b. A relative TMPDIR still yields absolute scan paths and a working scan.
mkdir -p "$work/reltmp"
RUN_CWD="$work" run "$work/clone" FAKE_GUARD_PR=toolarge TMPDIR=reltmp
check "relative TMPDIR: exit 0" rc_is 0
check "relative TMPDIR: scan isolated" range_isolated
check "relative TMPDIR: worktree path absolute" abs_scan_paths
check "relative TMPDIR: scan saw the commits" logged "range-saw-added"

# 18. gh pr merge exits non-zero: only a PR that is MERGED with our head counts as merged.
merged_view="FAKE_VIEW_STATE=MERGED FAKE_VIEW_MERGE=abc123"
# shellcheck disable=SC2086 # intentional word splitting of the VAR=value list
run "$work/clone" FAKE_MERGE_RC_AFTER=1 $merged_view
check "merged anyway: exit 0" rc_is 0
check "merged anyway: merge attempted once" logged MERGED
check "merged anyway: re-checked the PR" logged "pr view 7 --repo owner/repo --json state,mergeCommit,headRefOid"
check "merged anyway: warns" said "warning: .*merged"
check "merged anyway: shows gh output" said "HTTP 404"
check "merged anyway: reports merged" said "pr-merge: merged owner/repo#7"
run "$work/clone" FAKE_GUARD_PR=toolarge FAKE_MERGE_RC_AFTER=1 $merged_view
check "merged anyway (fallback): exit 0" rc_is 0
run "$work/clone" FAKE_MERGE_RC_AFTER=1 FAKE_VIEW_STATE=OPEN
check "merge failed, PR open: exit 1" rc_is 1
check "merge failed, PR open: error" said "error: merge failed"
check "merge failed, PR open: shows gh output" said "HTTP 404"
check "merge failed, PR open: no success line" not said "pr-merge: merged"
run "$work/clone" FAKE_MERGE_RC_AFTER=1 FAKE_VIEW_STATE=CLOSED
check "merge failed, PR closed: exit 1" rc_is 1
# shellcheck disable=SC2086
run "$work/clone" FAKE_MERGE_RC_AFTER=1 $merged_view FAKE_VIEW_HEAD=1111111111111111111111111111111111111111
check "merged with other head: exit 1" rc_is 1
check "merged with other head: not ours" said "not the commit"
check "merged with other head: no success line" not said "pr-merge: merged"
run "$work/clone" FAKE_MERGE_RC_AFTER=1 FAKE_VIEW_STATE=MERGED FAKE_VIEW_MERGE=
check "merged without merge commit: exit 1" rc_is 1
run "$work/clone" FAKE_MERGE_RC_AFTER=1 FAKE_VIEW_FAIL=1
check "view fails: exit 1" rc_is 1
check "view fails: shows gh output" said "HTTP 404"
run "$work/clone" FAKE_CURRENT_HEAD=0000000000000000000000000000000000000000 FAKE_VIEW_STATE=MERGED FAKE_VIEW_MERGE=abc123
check "refused merge, PR looks merged with other head: exit 1" rc_is 1
run "$work/clone"
check "clean merge: no re-check" not_logged "mergeCommit"

# 11. Usage errors keep exit status 2.
env PATH="$work/bin:$PATH" "$script" > "$out" 2>&1
rc=$?
: > "$FAKE_LOG"
check "usage: exit 2" rc_is 2

echo "pr-merge tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
