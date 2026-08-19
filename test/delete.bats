#!/usr/bin/env bats
# Tier 1: --delete. Real csb runs against a throwaway repo in the isolated
# harness HOME. No .worktreesetup.sh is present, so nothing here needs nix;
# the preflight (worktree_remove_blocker) fires before any teardown or removal,
# which is exactly the seam these tests pin: a worktree git would refuse to
# remove is refused up front, leaving it fully intact.

load helpers

# run csb ARGS... from inside REPO (delete mode resolves the repo from cwd).
csb_in() {
  local repo="$1"; shift
  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$repo" "$CSB" "$@"
}

# git worktree add under .worktrees/, as csb lays them out; echo its path,
# symlink-resolved to match what git (and so csb) prints for it.
add_worktree() {
  local repo="$1" branch="$2" path="$1/.worktrees/$2"
  git -C "$repo" worktree add -q -b "$branch" "$path" >/dev/null
  realpath "$path"
}

@test "-d removes a clean csb worktree" {
  repo=$(fake_repo)
  wt=$(add_worktree "$repo" wip)
  csb_in "$repo" -d wip
  assert_success
  assert_output --partial "removing worktree $wt"
  [ ! -d "$wt" ]
}

@test "-d refuses a worktree with untracked files, leaving it intact" {
  repo=$(fake_repo)
  wt=$(add_worktree "$repo" wip)
  touch "$wt/scratch.txt"
  csb_in "$repo" -d wip
  assert_failure
  assert_output --partial "has uncommitted or untracked files"
  refute_output --partial "removing worktree"
  [ -d "$wt" ]
  [ -f "$wt/scratch.txt" ]
  run git -C "$repo" worktree list
  assert_output --partial "$wt"
}

@test "-d refuses a dirty worktree, leaving it intact" {
  repo=$(fake_repo)
  echo tracked > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" -c user.email=test@example.com -c user.name=test \
    commit -q -m add-file
  wt=$(add_worktree "$repo" wip)
  echo change >> "$wt/file.txt"
  csb_in "$repo" -d wip
  assert_failure
  assert_output --partial "has uncommitted or untracked files"
  refute_output --partial "removing worktree"
  [ -d "$wt" ]
}

@test "-d refuses a locked worktree, leaving it intact" {
  repo=$(fake_repo)
  wt=$(add_worktree "$repo" wip)
  git -C "$repo" worktree lock "$wt"
  csb_in "$repo" -d wip
  assert_failure
  assert_output --partial "is locked"
  refute_output --partial "removing worktree"
  [ -d "$wt" ]
}

@test "-d refusal names the force escape hatch" {
  repo=$(fake_repo)
  wt=$(add_worktree "$repo" wip)
  touch "$wt/scratch.txt"
  csb_in "$repo" -d wip
  assert_failure
  assert_output --partial "worktree remove --force $wt"
}
