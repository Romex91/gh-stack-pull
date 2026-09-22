#!/usr/bin/env bash
# End-to-end tests for gh stack-pull against a real GitHub repository, with the
# real gh, gh-stack and git. Nothing is mocked.
#
#   TESTBED_REPO=owner/repo tests/run.sh [name-filter]
#
# The testbed repository's description must contain "gh-stack-pull e2e testbed".
# Every branch except the default one is deleted, every open PR closed, every
# stack unstacked, and the default branch force-pushed to a fresh root before
# every test. Run one instance at a time.
#
# Each test builds a stack main <- s1 <- s2 <- s3 (one commit per layer, each
# editing its own line of file.txt: s1 line 10, s2 line 20, s3 line 30) and
# clones it twice: A is the machine under test, B is "the other machine", which
# rewrites or clobbers the stack with the real `gh stack sync`.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STACK_PULL=$HERE/../gh-stack-pull
REPO=${TESTBED_REPO:?set TESTBED_REPO=owner/repo (its description must contain "gh-stack-pull e2e testbed")}
FILTER=${1:-}
KEEP=${KEEP:-0}   # KEEP=1 keeps every test's work dir; failed tests are kept regardless

for tool in gh git jq; do command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }; done
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in" >&2; exit 2; }
gh extension list 2>/dev/null | grep -q '^gh stack\b' || { echo "gh-stack is not installed" >&2; exit 2; }
desc=$(gh repo view "$REPO" --json description --jq .description)
case "$desc" in
  *"gh-stack-pull e2e testbed"*) ;;
  *) echo "refusing: $REPO's description does not contain 'gh-stack-pull e2e testbed'" >&2; exit 2 ;;
esac
DEFAULT=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)

export GIT_AUTHOR_NAME=stack-pull-test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=stack-pull-test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_EDITOR=true GH_PROMPT_DISABLED=1 NO_COLOR=1

# ---------------------------------------------------------------- remote reset
reset_remote() {
  local tmp n
  gh pr list -R "$REPO" --state open --json number --jq '.[].number' \
    | xargs -r -n1 gh pr close -R "$REPO" >/dev/null 2>&1 || true
  tmp=$(mktemp -d)
  gh repo clone "$REPO" "$tmp/c" -- -q --depth 1 2>/dev/null
  (
    cd "$tmp/c"
    for n in $(gh api "repos/$REPO/stacks" --jq '.[].number // empty' 2>/dev/null); do
      gh stack unstack "$n" >/dev/null 2>&1 || true
    done
    for b in $(gh api "repos/$REPO/branches" --paginate --jq '.[].name' | grep -vx "$DEFAULT" || true); do
      gh api -X DELETE "repos/$REPO/git/refs/heads/$b" >/dev/null
    done
    git checkout -q --orphan fresh
    git rm -rq . >/dev/null 2>&1 || true
    seq 1 40 | sed 's/^/line /' > file.txt
    git add file.txt && git commit -qm "root $(date +%s)"
    git push -q --force origin "HEAD:refs/heads/$DEFAULT"
  )
  rm -rf "$tmp"
}

# ---------------------------------------------------------------- fixture
# Sets WORK, A, B. A and B are clones with the stack tracked by gh-stack, on s3.
fixture() {
  WORK=$(mktemp -d); echo "WORK=$WORK"
  reset_remote
  gh repo clone "$REPO" "$WORK/seed" -- -q 2>/dev/null
  (
    cd "$WORK/seed"
    git switch -q "$DEFAULT"
    for i in 1 2 3; do
      git switch -qc "s$i"
      edit_line $((i * 10)) "edited by s$i"
      git commit -qam "s$i"
    done
    git push -q origin s1 s2 s3 2>/dev/null
    for i in 1 2 3; do git branch -q -u "origin/s$i" "s$i"; done
  )
  cp -a "$WORK/seed" "$WORK/A"; cp -a "$WORK/seed" "$WORK/B"
  A=$WORK/A; B=$WORK/B
  for m in "$A" "$B"; do (cd "$m" && gh stack init --base "$DEFAULT" s1 s2 s3 >/dev/null 2>&1); done
}

edit_line() { sed -i "${1}s/.*/$2/" file.txt; }          # edit_line <n> <text>
# Both leave the clone on the branch it was on before.
commit_on() {                                              # commit_on <dir> <branch> <line> <text> <message>
  (cd "$1" && git switch -q "$2" && edit_line "$3" "$4" && git commit -qam "$5" && git switch -q -)
}
add_file_on() {                                            # add_file_on <dir> <branch> <file> <message>
  (cd "$1" && git switch -q "$2" && echo "$3" > "$3" && git add "$3" && git commit -qm "$4" && git switch -q -)
}
sha() { git -C "$1" rev-parse "$2"; }                      # sha <dir> <ref>
sync_on() {                                                # sync_on <dir>: the real gh stack sync, must succeed and push
  local out
  out=$(cd "$1" && gh stack sync 2>&1) || { echo "gh stack sync failed in $1:"; echo "$out"; return 1; }
  grep -q 'Pushed' <<<"$out" || { echo "gh stack sync in $1 pushed nothing:"; echo "$out"; return 1; }
}

# ---------------------------------------------------------------- assertions
run() { set +e; out=$("$@" 2>&1); status=$?; set -e; }
pull() { run "$STACK_PULL" "$@"; }                         # in the current directory
assert_status() { [ "$status" -eq "$1" ] || { echo "expected exit $1, got $status:"; echo "$out"; return 1; }; }
assert_contains() { grep -qF -- "$1" <<<"$out" || { echo "output lacks '$1':"; echo "$out"; return 1; }; }
assert_lacks() { grep -qF -- "$1" <<<"$out" && { echo "output has unexpected '$1':"; echo "$out"; return 1; } || true; }
assert_eq() { [ "$1" = "$2" ] || { echo "expected '$2', got '$1' ($3)"; return 1; }; }
assert_matches_origin() {                                  # assert_matches_origin <dir> <branch>...
  local d=$1; shift; git -C "$d" fetch -q origin
  for b in "$@"; do [ "$(sha "$d" "$b")" = "$(sha "$d" "origin/$b")" ] || { echo "$b: local $(sha "$d" "$b") != origin $(sha "$d" "origin/$b")"; return 1; }; done
}
rebasing() { [ -d "$1/.git/rebase-merge" ] || [ -d "$1/.git/rebase-apply" ]; }
on_branch() { assert_eq "$(git -C "$1" branch --show-current)" "$2" "current branch in $1"; }
RESTACK='IMPORTANT!!! Run `gh stack sync` to rebase child branches.'

# ================================================================ tests

test_up_to_date() {
  fixture; cd "$A"
  pull; assert_status 0; assert_contains "Already up to date."
}

test_fast_forward_current_and_other_branch() {
  fixture
  commit_on "$B" s3 35 "s3 tip moved on B" "more s3"; (cd "$B" && git push -q origin s3)
  commit_on "$B" "$DEFAULT" 1 "trunk moved" "trunk"; (cd "$B" && git push -q origin "$DEFAULT")
  cd "$A"                                                  # on s3: s3 is the checked-out branch, main is not
  pull; assert_status 0
  assert_contains "Fast-forwarded s3"; assert_contains "Fast-forwarded $DEFAULT"; assert_contains "Done."
  assert_contains "$RESTACK"                               # the trunk moved under s1
  assert_matches_origin "$A" "$DEFAULT" s1 s2 s3; on_branch "$A" s3
  assert_eq "$(sed -n 35p file.txt)" "s3 tip moved on B" "working tree updated by the fast-forward"
}

test_ahead_is_left_alone() {
  fixture
  commit_on "$A" s2 21 "unpushed on A" "local s2"; local before; before=$(sha "$A" s2)
  cd "$A"; pull; assert_status 0
  assert_contains "s2: ahead by 1, nothing to pull"; assert_contains "Already up to date."
  assert_eq "$(sha "$A" s2)" "$before" "s2 untouched"
}

test_diverged_refuses_without_rebase() {
  fixture
  commit_on "$B" s1 11 "B on s1" "B s1"; sync_on "$B"         # s1 gains a commit; the cascade rewrites s2 and s3
  local s1 s2 s3; s1=$(sha "$A" s1); s2=$(sha "$A" s2); s3=$(sha "$A" s3)
  cd "$A"; pull; assert_status 1
  assert_contains "s1: behind by 1, fast-forward"
  assert_contains "2 branch(es) have diverged from origin and cannot be fast-forwarded"
  assert_contains "gh stack-pull --rebase"
  assert_eq "$(sha "$A" s1)$(sha "$A" s2)$(sha "$A" s3)" "$s1$s2$s3" "nothing moved"
  ! rebasing "$A"
}

test_rebase_adopts_rewrite() {
  fixture
  commit_on "$B" s1 11 "B on s1" "B s1"; sync_on "$B"
  cd "$A"; pull --rebase; assert_status 0
  assert_contains "Fast-forwarded s1"
  assert_eq "$(grep -c '0 local commit(s) kept' <<<"$out")" 2 "s2 and s3 adopted with no replay"
  assert_lacks "will be kept"; assert_lacks "CONFLICT"; assert_contains "Done."; assert_lacks "IMPORTANT"
  assert_matches_origin "$A" s1 s2 s3; on_branch "$A" s3
}

test_rebase_after_fresher_trunk() {
  fixture
  commit_on "$B" "$DEFAULT" 1 "trunk moved" "trunk"; (cd "$B" && git push -q origin "$DEFAULT")
  sync_on "$B"                                             # rebases the whole stack onto the new trunk
  cd "$A"; pull --rebase; assert_status 0
  assert_contains "Fast-forwarded $DEFAULT"; assert_lacks "will be kept"; assert_lacks "CONFLICT"; assert_lacks "IMPORTANT"
  assert_matches_origin "$A" "$DEFAULT" s1 s2 s3
}

test_context_only_rewrite_is_not_reported_as_removed() {
  fixture                                                  # s2 edits line 20; B edits line 17, inside s2's 3-line context but not adjacent
  commit_on "$B" s1 17 "B inside s2's context" "B s1"; sync_on "$B"
  cd "$A"; pull --rebase; assert_status 0
  assert_lacks "will be kept"; assert_lacks "Kept"; assert_lacks "CONFLICT"
  assert_matches_origin "$A" s1 s2 s3
}

test_clobbered_commit_is_kept_and_pushed_back() {
  fixture
  add_file_on "$A" s2 y.txt "Y from A"; (cd "$A" && git push -q origin s2); local y; y=$(sha "$A" s2)
  add_file_on "$B" s2 v.txt "V from B"; sync_on "$B"         # B never fetched: overwrites Y (issue #516)
  git -C "$A" fetch -q origin
  assert_eq "$(git -C "$A" branch -r --contains "$y" | wc -l)" 0 "real gh stack sync removed Y from the remote"
  cd "$A"; pull --rebase; assert_status 0
  assert_contains "will be kept: ${y:0:7} Y from A"; assert_contains "Kept 1 commit(s)"
  assert_contains "$RESTACK"                               # s3 adopted the remote and is not on s2's tip
  assert_eq "$(git log --format=%s origin/s2..s2)" "Y from A" "Y replayed on top of the remote"
  assert_eq "$(git log -1 --format=%s origin/s2)" "V from B" "remote tip is B's V"
  assert_matches_origin "$A" s1 s3
  run gh stack sync; assert_status 0; assert_contains "Pushed"   # the pull left sync able to publish Y again
  assert_matches_origin "$A" s1 s2 s3
}

test_lost_commit_on_parent_and_child_is_kept_on_both() {
  fixture
  add_file_on "$A" s2 y.txt "Y from A"; sync_on "$A"         # Y on s2; A's sync rebases s3 onto it and pushes both
  local y; y=$(sha "$A" s2)
  git -C "$A" merge-base --is-ancestor "$y" s3 || { echo "fixture: s3 does not contain Y"; return 1; }
  add_file_on "$B" s2 v.txt "V from B"; sync_on "$B"         # B never fetched: overwrites Y on s2 and s3 (issue #516)
  git -C "$A" fetch -q origin
  assert_eq "$(git -C "$A" branch -r --contains "$y" | wc -l)" 0 "real gh stack sync removed Y from the remote"
  cd "$A"; pull --rebase; assert_status 0
  assert_eq "$(grep -c "will be kept: ${y:0:7} Y from A" <<<"$out")" 1 "Y reported once, on the lowest branch"
  assert_contains "Kept 1 commit(s)"
  assert_eq "$(git log --format=%s origin/s2..s2)" "Y from A" "Y replayed on s2, where it was made"
  assert_matches_origin "$A" s1 s3                          # s3 adopts the remote; the sync cascade brings Y back
  assert_contains "$RESTACK"
  run gh stack sync; assert_status 0; assert_contains "Pushed"
  assert_matches_origin "$A" s1 s2 s3
  assert_eq "$(git log --format=%s s2..s3)" "s3" "s3 sits on s2, so on Y, after sync"
  [ -f y.txt ] || { echo "y.txt missing from s3 after sync"; return 1; }
}

test_unpushed_commit_is_replayed_then_synced() {
  fixture
  commit_on "$B" s1 11 "B on s1" "B s1"; sync_on "$B"
  commit_on "$A" s3 36 "A on s3" "A s3"
  cd "$A"; pull --rebase; assert_status 0
  assert_contains "1 local commit(s) kept"; assert_lacks "will be kept"; assert_lacks "CONFLICT"; assert_lacks "IMPORTANT"
  assert_matches_origin "$A" s1 s2
  assert_eq "$(git log --format=%s origin/s3..s3)" "A s3" "A's commit sits on the rewritten s3"
  run gh stack sync; assert_status 0; assert_contains "Pushed"
  assert_matches_origin "$A" s1 s2 s3
}

test_conflict_on_last_branch_then_continue() {
  fixture
  commit_on "$B" s3 30 "B version" "B s3"; sync_on "$B"
  commit_on "$A" s3 30 "A version" "A s3"
  cd "$A"; pull --rebase; assert_status 1
  assert_contains "CONFLICT: rebasing s3 onto origin/s3 stopped."
  assert_contains "gh stack-pull --continue"; assert_contains "git rebase --abort"
  rebasing "$A"; [ -f .git/gh-stack-pull ]
  pull --rebase; assert_status 1; assert_contains "resolve it and run gh stack-pull --continue"
  pull --continue; assert_status 1; assert_contains "hint"          # still unresolved
  edit_line 30 "resolved"; git add file.txt
  pull --continue; assert_status 0; assert_contains "Done."; assert_lacks "IMPORTANT"
  ! rebasing "$A"; [ ! -f .git/gh-stack-pull ]; on_branch "$A" s3
  assert_eq "$(git log --format=%s origin/s3..s3)" "A s3" "the resolved commit is on top"
}

test_conflict_mid_stack_keeps_per_branch_decision() {
  fixture
  add_file_on "$A" s2 y.txt "Y from A"; (cd "$A" && git push -q origin s2); local y; y=$(sha "$A" s2)
  commit_on "$A" s1 10 "A version" "A s1"                  # will conflict with B's edit of the same line
  commit_on "$B" s1 10 "B version" "B s1"; add_file_on "$B" s2 v.txt "V from B"; sync_on "$B"
  cd "$A"; pull --rebase; assert_status 1
  assert_contains "will be kept: ${y:0:7} Y from A"; assert_contains "CONFLICT: rebasing s1"
  grep -qx "replay_all=s2" .git/gh-stack-pull; grep -qx "pending=s2" .git/gh-stack-pull; grep -qx "pending=s3" .git/gh-stack-pull
  edit_line 10 "resolved"; git add file.txt
  pull --continue; assert_status 0; assert_contains "Kept 1 commit(s)"; assert_contains "Done."; assert_contains "$RESTACK"
  assert_eq "$(git log --format=%s origin/s2..s2)" "Y from A" "Y kept on s2 after --continue"
  assert_matches_origin "$A" s3; on_branch "$A" s3
}

test_aborted_parent_then_continue_leaves_sync_working() {
  fixture
  (cd "$B" && git switch -q s1 && edit_line 10 "amended by B" && git commit -qa --amend --no-edit && git switch -q s3)
  commit_on "$B" s3 31 "B on s3" "B s3"; sync_on "$B"       # s1's own commit rewritten; s2, s3 restacked on it
  cd "$A"; pull --rebase; assert_status 1
  assert_contains "will be kept"; assert_contains "CONFLICT: rebasing s1"
  git rebase --abort                                       # keep A's s1 as it was, as the CONFLICT message offers
  pull --continue; assert_status 0; assert_contains "Done."; assert_contains "$RESTACK"
  assert_eq "$(git log -1 --format=%s s1)" "s1" "s1 untouched by the abort"
  run gh stack sync; assert_status 0; assert_contains "Pushed"
  assert_eq "$(git log --format=%s s1..s3 | tr '\n' ' ')" "B s3 s3 s2 " "the cascade replays only the children onto A's s1"
  assert_eq "$(git show s3:file.txt | sed -n 10p)" "edited by s1" "A's version of s1 won"
  assert_matches_origin "$A" s1 s2 s3
}

test_skipped_parent_conflict_is_not_repeated_on_child() {
  fixture
  commit_on "$A" s1 11 "colour support" "add button colour"
  commit_on "$A" s2 21 "colourful button on page" "use colourful button"
  sync_on "$A"                                             # s2 and s3 carry both commits; everything pushed
  local c1 c2; c1=$(sha "$A" s1); c2=$(sha "$A" s2)
  commit_on "$B" s1 11 "B's own line 11" "B s1"; sync_on "$B"  # B never fetched: both commits gone from the remote
  git -C "$A" fetch -q origin
  assert_eq "$(git -C "$A" branch -r --contains "$c1" | wc -l)" 0 "colour support gone from the remote"
  cd "$A"; pull --rebase; assert_status 1
  assert_contains "will be kept: ${c1:0:7} add button colour"; assert_contains "will be kept: ${c2:0:7} use colourful button"
  assert_contains "CONFLICT: rebasing s1"
  git rebase --abort                                       # skip colour support on s1, as the message offers
  pull --continue; assert_status 0                         # the skipped conflict must not come back on s2
  assert_lacks "CONFLICT"
  assert_eq "$(git log --format=%s origin/s2..s2)" "use colourful button" "only s2's own commit replayed on s2"
  assert_matches_origin "$A" s3; assert_contains "$RESTACK"
}

test_refuses_dirty_tree() {
  fixture; cd "$A"; echo dirty >> file.txt
  pull; assert_status 1; assert_contains "uncommitted changes"
}

test_continue_guards() {
  fixture; cd "$A"
  pull --continue; assert_status 1; assert_contains "nothing to continue"
  pull --continue --rebase; assert_status 1; assert_contains "takes no other options"
}

test_remote_flag() {
  fixture
  (cd "$A" && git remote add mirror "$(git remote get-url origin)")
  commit_on "$B" s1 11 "B on s1" "B s1"; sync_on "$B"
  cd "$A"; pull --rebase --remote mirror; assert_status 0; assert_contains "Fetching mirror"
  assert_eq "$(sha "$A" s1)" "$(sha "$A" mirror/s1)" "s1 pulled from mirror"
}

test_expired_reflog_still_adopts_rewrite() {
  fixture
  commit_on "$B" s1 11 "B on s1" "B s1"; sync_on "$B"
  cd "$A"; git reflog expire --expire=now --all           # no fork point available: git falls back to patch matching
  pull --rebase; assert_status 0; assert_lacks "CONFLICT"
  assert_matches_origin "$A" s1 s2 s3
}

test_colour_only_on_a_terminal() {
  fixture
  commit_on "$B" s1 11 "B on s1" "B s1"; sync_on "$B"
  cd "$A"
  pull; assert_lacks $'\e['                                # captured output: no escapes
  local tty_out; tty_out=$(NO_COLOR= script -qec "$STACK_PULL" /dev/null 2>&1 || true)
  grep -qF $'\e[' <<<"$tty_out" || { echo "no colour on a tty"; return 1; }
  tty_out=$(NO_COLOR=1 script -qec "$STACK_PULL" /dev/null 2>&1 || true)
  grep -qF $'\e[' <<<"$tty_out" && { echo "colour despite NO_COLOR"; return 1; } || true
}

test_pull_requests_survive_pull_and_sync() {
  fixture
  (cd "$A" && gh stack submit --auto >/dev/null 2>&1) || { echo "gh stack submit failed"; return 1; }
  assert_eq "$(gh pr list -R "$REPO" --state open --json number --jq length)" 3 "three PRs opened"
  commit_on "$B" s1 11 "B on s1" "B s1"; sync_on "$B"
  cd "$A"; pull --rebase; assert_status 0; assert_matches_origin "$A" s1 s2 s3
  run gh stack sync; assert_status 0
  assert_eq "$(gh pr list -R "$REPO" --state open --json number --jq length)" 3 "PRs still open after pull + sync"
}

# ================================================================ runner
tests=$(declare -F | awk '{print $3}' | grep '^test_' | grep -- "$FILTER" || true)
[ -n "$tests" ] || { echo "no tests match '$FILTER'" >&2; exit 2; }
pass=0; fail=0; failed=()
for t in $tests; do
  start=$(date +%s); log=$(mktemp)
  set +e; ( set -e; "$t" ) >"$log" 2>&1; st=$?; set -e
  took=$(( $(date +%s) - start ))
  if [ $st -eq 0 ]; then
    echo "ok    $t (${took}s)"; pass=$((pass + 1))
    [ "$KEEP" = 1 ] || rm -rf "$(sed -n 's/^WORK=//p' "$log" | tail -1)" 2>/dev/null
  else
    echo "FAIL  $t (${took}s)"; { grep -v '^WORK=' "$log" || true; } | sed 's/^/      /'; echo "      work dir kept: $(sed -n 's/^WORK=//p' "$log" | tail -1)"; fail=$((fail + 1)); failed+=("$t")
  fi
  rm -f "$log"
done
echo; echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
