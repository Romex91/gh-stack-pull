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

# A branch recorded in two local stacks. gh-stack v0.1.1 refuses to check out a
# stack whose composition overlaps one already tracked, but older versions and
# earlier flows left such records behind (popmenu has fix-scroll and virtuoso in
# stacks 36067 and 36002). The second record is written into .git/gh-stack the
# way those flows left it: a stale stack over s2 <- s3 next to the live one. `gh
# stack view` then refuses to pick one ("belongs to multiple stacks"), and the
# pull must still work.
test_branch_in_two_local_stacks() {
  fixture
  local pr
  (cd "$B" && gh stack submit --auto >/dev/null 2>&1) || { echo "gh stack submit failed on B"; return 1; }
  pr=$(gh pr list -R "$REPO" --state open --head s3 --json number --jq '.[0].number'); [ -n "$pr" ] || { echo "no PR for s3"; return 1; }
  cd "$A"; gh stack checkout "$pr" >/dev/null 2>&1 || { echo "gh stack checkout $pr failed on A"; return 1; }
  on_branch "$A" s3
  jq '.stacks += [(.stacks[0] | .number = 999999 | .branches |= map(select(.branch != "s1")))]' .git/gh-stack > .git/gh-stack.new \
    && mv .git/gh-stack.new .git/gh-stack
  assert_eq "$(jq '.stacks | length' .git/gh-stack)" 2 "local stacks recorded"
  run gh stack view --json; assert_status 6; assert_contains "belongs to multiple stacks"   # the precondition
  pull; assert_status 0; assert_contains "Already up to date."
  commit_on "$B" s3 35 "s3 tip moved on B" "more s3"; (cd "$B" && git push -q origin s3)
  pull; assert_status 0; assert_contains "Fast-forwarded s3"; assert_matches_origin "$A" s1 s2 s3
}

# A branch added to the stack on GitHub behind the local record's back: `gh
# stack link` never touches local tracking (that is how popmenu's insta-scroll
# got stuck), and `gh stack add` + submit on another machine leaves the same
# state, which is what B does here. gh stack sync would pull the branch down
# itself, but refuses when a local branch of that name exists ("Cannot pull s4
# from the remote stack: a local branch with that name already exists"). The
# pull records it (creating the local branch when there is none) so that sync
# works again.
test_adopts_branch_added_behind_the_record() {
  fixture
  local pr
  (cd "$B" && gh stack submit --auto >/dev/null 2>&1) || { echo "gh stack submit failed on B"; return 1; }
  pr=$(gh pr list -R "$REPO" --state open --head s3 --json number --jq '.[0].number'); [ -n "$pr" ] || { echo "no PR for s3"; return 1; }
  cd "$A"; gh stack checkout "$pr" >/dev/null 2>&1 || { echo "gh stack checkout $pr failed on A"; return 1; }
  (cd "$B" && gh stack add s4 >/dev/null 2>&1 && edit_line 36 "edited by s4" && git commit -qam s4 && gh stack submit --auto >/dev/null 2>&1) \
    || { echo "adding s4 on B failed"; return 1; }
  git fetch -q origin && git branch -q s4 origin/s4                     # the user already has the branch, as with insta-scroll
  jq '.repository = ""' .git/gh-stack > .git/gh-stack.new && mv .git/gh-stack.new .git/gh-stack   # as gh-stack left it in shaka-perf
  pull; assert_status 0; assert_contains "s4: added to the stack on origin, now tracked"
  assert_eq "$(jq -r '.stacks[0].branches[-1].branch' .git/gh-stack)" s4 "s4 recorded last"
  assert_eq "$(jq -r '.stacks[0].branches[-1].pullRequest.number' .git/gh-stack)" "$(gh pr list -R "$REPO" --state open --head s4 --json number --jq '.[0].number')" "s4 PR recorded"
  run gh stack view --json; assert_status 0; assert_contains '"name": "s4"'
  run gh stack sync; assert_status 0; assert_lacks "Cannot pull"
  (cd "$B" && gh stack add s5 >/dev/null 2>&1 && edit_line 37 "edited by s5" && git commit -qam s5 && gh stack submit --auto >/dev/null 2>&1) \
    || { echo "adding s5 on B failed"; return 1; }
  pull; assert_status 0; assert_contains "s5: added to the stack on origin, now tracked"   # no local s5: created from origin
  assert_matches_origin "$A" s4 s5
  run gh stack view --json; assert_status 0; assert_contains '"name": "s5"'
}

# A branch only this machine has (gh stack add, not pushed yet) while another
# machine added one to the stack on GitHub. The local branch and its commit
# stay, the remote one is appended after it, as gh stack sync would do.
test_local_extra_branch_survives_adoption() {
  fixture
  local pr
  (cd "$B" && gh stack submit --auto >/dev/null 2>&1) || { echo "gh stack submit failed on B"; return 1; }
  pr=$(gh pr list -R "$REPO" --state open --head s3 --json number --jq '.[0].number'); [ -n "$pr" ] || { echo "no PR for s3"; return 1; }
  cd "$A"; gh stack checkout "$pr" >/dev/null 2>&1 || { echo "gh stack checkout $pr failed on A"; return 1; }
  gh stack add s4 >/dev/null 2>&1 && edit_line 36 "edited by s4 on A" && git commit -qam "s4 on A" || { echo "gh stack add s4 failed on A"; return 1; }
  local s4_tip; s4_tip=$(sha "$A" s4)
  (cd "$B" && gh stack add s5 >/dev/null 2>&1 && edit_line 37 "edited by s5" && git commit -qam s5 && gh stack submit --auto >/dev/null 2>&1) \
    || { echo "adding s5 on B failed"; return 1; }
  pull; assert_status 0
  assert_contains "s4: not on origin, skipped"; assert_contains "s5: added to the stack on origin, now tracked"
  assert_eq "$(sha "$A" s4)" "$s4_tip" "s4 untouched"
  assert_eq "$(jq -r '[.stacks[0].branches[].branch] | join(" ")' .git/gh-stack)" "s1 s2 s3 s4 s5" "record order"
  assert_matches_origin "$A" s1 s2 s3 s5; on_branch "$A" s4
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

test_lost_commit_is_kept_without_replaying_its_rewritten_neighbours() {
  fixture
  commit_on "$A" s1 11 "button" "add button"; local bt; bt=$(sha "$A" s1)
  # Line 13, not 12: git conflicts on changes to adjacent lines, so a tooltip right
  # under the button could not be replayed over an improved button by anyone.
  commit_on "$A" s1 13 "tooltip" "add tooltip"; local tt; tt=$(sha "$A" s1)
  sync_on "$A"                                             # both pushed; s2 and s3 restacked on them
  # B rewrites s1 from the remote's state: rebased onto a moved trunk (line 9 sits in
  # the button's diff context), button kept then improved in place, the tooltip lost.
  (cd "$B" && git fetch -q origin && git switch -q "$DEFAULT" && edit_line 9 "trunk moved" && git commit -qam "trunk" \
    && git push -q origin "$DEFAULT" && git switch -qC s1 "$DEFAULT" && edit_line 10 "edited by s1" && git commit -qam "s1" \
    && edit_line 11 "button" && git commit -qam "add button" \
    && edit_line 11 "button improved" && git commit -qam "improve button" && git switch -q s3)
  sync_on "$B"
  git -C "$A" fetch -q origin
  assert_eq "$(git -C "$A" branch -r --contains "$tt" | wc -l)" 0 "tooltip gone from the remote"
  cd "$A"; pull --rebase; assert_status 0
  assert_contains "will be kept: ${tt:0:7} add tooltip"; assert_lacks "will be kept: ${bt:0:7} add button"
  assert_lacks "CONFLICT"; assert_contains "Kept 1 commit(s)"
  assert_eq "$(git log --format=%s origin/s1..s1)" "add tooltip" "only the tooltip replayed on s1"
  assert_eq "$(git show s1:file.txt | sed -n '9p;11p;13p' | tr '\n' '|')" "trunk moved|button improved|tooltip|" "s1 has the improved button and the tooltip"
  assert_matches_origin "$A" "$DEFAULT" s2 s3
}

# A lower branch of more than one commit, squash-merged on GitHub. Its content is
# on the remote, but as a single commit with a single patch id, so none of the
# originals matches any more. They must not be reported as lost and replayed:
# every branch above already carries that content through the merged trunk.
test_squash_merged_branch_is_not_replayed() {
  fixture
  # s1 becomes a three-commit PR: its own line, a paragraph inserted around it,
  # then a reword of that line, so no single commit's diff survives the squash.
  (cd "$A" && git switch -q s1 \
    && sed -i -e '10i\para above s1' -e '12i\para below s1' file.txt && git commit -qam "s1 paragraphs" \
    && edit_line 11 "reworded by s1" && git commit -qam "s1 reword" && git switch -q -)
  local tip; tip=$(sha "$A" s1)
  sync_on "$A"                                             # s2 and s3 restacked on them, everything pushed
  (cd "$A" && gh stack submit --auto >/dev/null 2>&1) || { echo "gh stack submit failed"; return 1; }
  rm -rf "$B"; cp -a "$A" "$B"                             # B starts from the same, up-to-date state
  local n; n=$(gh pr list -R "$REPO" --head s1 --state open --json number --jq '.[0].number')
  [ -n "$n" ] || { echo "no open PR for s1"; return 1; }
  gh pr ready -R "$REPO" "$n" >/dev/null 2>&1 || true      # in case submit made drafts
  (cd "$A" && gh stack merge "$n" --yes --squash >/dev/null 2>&1) || { echo "squash merge of s1 failed"; return 1; }
  # B adopts the merged trunk and restacks the rest of the stack on it.
  (cd "$B" && git fetch -q origin && git switch -q "$DEFAULT" && git merge -q --ff-only "origin/$DEFAULT" && git switch -q s3)
  sync_on "$B"
  # A never fetched: its s2 and s3 still carry s1's original commits.
  git -C "$A" merge-base --is-ancestor "$tip" s3 || { echo "fixture: s3 lost s1's commits"; return 1; }
  cd "$A"; pull --rebase; assert_status 0
  assert_lacks "will be kept"; assert_lacks "Kept"; assert_lacks "CONFLICT"
  assert_eq "$(git show s2:file.txt | grep -c 'para above s1')" 1 "s1's paragraph is on s2 exactly once"
  assert_eq "$(git show s2:file.txt | grep -c 'reworded by s1')" 1 "s1's reworded line is on s2 exactly once"
  assert_matches_origin "$A" "$DEFAULT" s2 s3
}

test_replay_preserves_commits_with_abbreviated_commands() {
  fixture
  add_file_on "$A" s3 tooltip.txt "add tooltip"
  (cd "$A" && git push -q origin s3)
  local tooltip; tooltip=$(sha "$A" s3)
  add_file_on "$A" s3 local.txt "unpushed local work"

  # B never fetched the tooltip. Its own commit on s3 keeps sync from adopting
  # the remote s3, and its commit on s2 makes the cascade rewrite s3, which
  # sync then force-pushes over the tooltip.
  commit_on "$B" s2 21 "B on s2" "B s2"; add_file_on "$B" s3 remote.txt "remote work"; sync_on "$B"
  git -C "$A" fetch -q origin
  assert_eq "$(git -C "$A" branch -r --contains "$tooltip" | wc -l)" 0 "tooltip overwritten remotely"

  cd "$A"
  git config --local rebase.abbreviateCommands true
  pull --rebase; assert_status 0

  # Check history and contents: the buggy version exits 0 and claims success.
  assert_eq "$(git log --reverse --format=%s origin/s3..s3)" $'add tooltip\nunpushed local work' "both local commits preserved"
  assert_eq "$(git show s3:tooltip.txt)" "tooltip.txt" "lost tooltip recovered"
  assert_eq "$(git show s3:local.txt)" "local.txt" "unpushed work preserved"
  assert_eq "$(git show s3:remote.txt)" "remote.txt" "remote work preserved"
  git merge-base --is-ancestor origin/s3 s3
  on_branch "$A" s3
  ! rebasing "$A"
}

test_replay_works_from_subdirectory() {
  fixture
  add_file_on "$A" s3 tooltip.txt "add tooltip"
  (cd "$A" && git push -q origin s3)
  local tooltip; tooltip=$(sha "$A" s3)
  commit_on "$B" s2 21 "B on s2" "B s2"; add_file_on "$B" s3 remote.txt "remote work"; sync_on "$B"   # as above
  git -C "$A" fetch -q origin
  assert_eq "$(git -C "$A" branch -r --contains "$tooltip" | wc -l)" 0 "tooltip overwritten remotely"

  # Isolate path handling from the abbreviated-command regression.
  git -C "$A" config --local rebase.abbreviateCommands false
  mkdir -p "$A/src/nested"
  cd "$A/src/nested"
  pull --rebase; assert_status 0

  assert_eq "$(git log --format=%s origin/s3..s3)" "add tooltip" "tooltip replayed from a subdirectory"
  assert_eq "$(git show s3:tooltip.txt)" "tooltip.txt" "lost tooltip recovered"
  assert_eq "$(git show s3:remote.txt)" "remote.txt" "remote work preserved"
  git merge-base --is-ancestor origin/s3 s3
  on_branch "$A" s3
  ! rebasing "$A"
}

test_replay_preserves_fixup_with_autosquash_enabled() {
  fixture
  add_file_on "$A" s3 tooltip.txt "add tooltip"
  (cd "$A" && git push -q origin s3)
  local tooltip; tooltip=$(sha "$A" s3)

  # Unpushed fixup to the commit that B will overwrite.
  (
    cd "$A"
    git switch -q s3
    echo "improved tooltip" > tooltip.txt
    git add tooltip.txt
    git commit -q --fixup="$tooltip"
  )

  # B never fetched the tooltip; a commit on s2 too, so the cascade force-pushes s3.
  commit_on "$B" s2 21 "B on s2" "B s2"; add_file_on "$B" s3 remote.txt "remote work"; sync_on "$B"
  git -C "$A" fetch -q origin
  assert_eq "$(git -C "$A" branch -r --contains "$tooltip" | wc -l)" 0 "tooltip overwritten remotely"

  cd "$A"
  git config --local rebase.autosquash true
  git config --local rebase.abbreviateCommands false
  pull --rebase; assert_status 0

  # Success alone is insufficient: the buggy filter silently drops the fixup.
  assert_eq "$(git show s3:tooltip.txt)" "improved tooltip" "unpushed fixup preserved"
  assert_eq "$(git show s3:remote.txt)" "remote.txt" "remote work preserved"
  git merge-base --is-ancestor origin/s3 s3
  on_branch "$A" s3
  ! rebasing "$A"
}

test_replay_works_with_spaces_in_repository_path() {
  fixture

  # Move the clone so the sequence editor's absolute path contains spaces.
  cd "$WORK"
  mv "$A" "$WORK/clone with spaces"
  A="$WORK/clone with spaces"

  add_file_on "$A" s3 tooltip.txt "add tooltip"
  (cd "$A" && git push -q origin s3)
  local tooltip; tooltip=$(sha "$A" s3)

  # B never fetched the tooltip; a commit on s2 too, so the cascade force-pushes s3.
  commit_on "$B" s2 21 "B on s2" "B s2"; add_file_on "$B" s3 remote.txt "remote work"; sync_on "$B"
  git -C "$A" fetch -q origin
  assert_eq "$(git -C "$A" branch -r --contains "$tooltip" | wc -l)" 0 "tooltip overwritten remotely"

  cd "$A"
  git config --local rebase.autosquash false
  git config --local rebase.abbreviateCommands false
  pull --rebase; assert_status 0

  assert_eq "$(git log --format=%s origin/s3..s3)" "add tooltip" "only the tooltip replayed"
  assert_eq "$(git show s3:tooltip.txt)" "tooltip.txt" "lost tooltip recovered"
  assert_eq "$(git show s3:remote.txt)" "remote.txt" "remote work preserved"
  git merge-base --is-ancestor origin/s3 s3
  on_branch "$A" s3
  ! rebasing "$A"
}

check_replay_with_forced_git_colour() {
  local setting=$1
  fixture
  add_file_on "$A" s3 tooltip.txt "add tooltip"
  (cd "$A" && git push -q origin s3)
  local tooltip; tooltip=$(sha "$A" s3)
  add_file_on "$A" s3 local.txt "unpushed local work"

  # B never fetched the tooltip; a commit on s2 too, so the cascade force-pushes s3.
  commit_on "$B" s2 21 "B on s2" "B s2"; add_file_on "$B" s3 remote.txt "remote work"; sync_on "$B"
  git -C "$A" fetch -q origin
  assert_eq "$(git -C "$A" branch -r --contains "$tooltip" | wc -l)" 0 "tooltip overwritten remotely"

  cd "$A"
  # Isolate each setting from inherited colour configuration.
  git config --local color.ui false
  git config --local color.diff auto
  git config --local "$setting" always

  pull --rebase; assert_status 0

  # The buggy version reports success but loses the tooltip.
  assert_eq "$(git show s3:tooltip.txt)" "tooltip.txt" "lost tooltip recovered"
  assert_eq "$(git show s3:local.txt)" "local.txt" "unpushed work preserved"
  assert_eq "$(git show s3:remote.txt)" "remote.txt" "remote work preserved"
  assert_eq "$(git log --no-color --reverse --format=%s origin/s3..s3)" \
    $'add tooltip\nunpushed local work' "both local commits preserved"
  git merge-base --is-ancestor origin/s3 s3
  on_branch "$A" s3
  ! rebasing "$A"
}

test_replay_preserves_lost_commit_with_color_ui_always() {
  check_replay_with_forced_git_colour color.ui
}

test_replay_preserves_lost_commit_with_color_diff_always() {
  check_replay_with_forced_git_colour color.diff
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
