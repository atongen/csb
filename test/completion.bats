#!/usr/bin/env bats
# Shell completion: cmdliner's protocol, answered by csb-config. Every arm
# drives the --__complete marker and asserts on the directive stream; nothing
# launches.
#
# needs-bin-csb marks the arms that depend on bin/csb's dispatch: the git
# candidates it passes in, and the stderr it discards.

load helpers

# complete ARGS... -- the protocol call a shell makes; the last ARG is the
# partial word, which becomes --__complete=WORD.
complete() {
  local word="${*: -1}"
  local args=("${@:1:$#-1}")
  run --separate-stderr "$CSB" --__complete "${args[@]}" "--__complete=$word"
}

# The item values in the output, one per line.
items() {
  awk 'prev == "item" { print } { prev = $0 }' <<<"$output"
}

# The items of the Values group only.
values() {
  awk '$0 == "group" { name = 1; next }
       name { grp = $0; name = 0; next }
       prev == "item" && grp == "Values" { print }
       { prev = $0 }' <<<"$output"
}

# The group names in the output, one per line.
groups() {
  awk 'prev == "group" { print } { prev = $0 }' <<<"$output"
}

# --- the protocol survives csb's pre-pass ----------------------------------------

@test "completing after -- returns directives, not an assertion failure" {
  complete --here -- cla
  assert_success
  [[ "${lines[0]}" == "1" ]]
}

@test "a half-typed -E= completes instead of dying" {
  complete -E= --par
  assert_success
  [[ "$(items)" == *--paranoid* ]]
}

@test "an unknown flag earlier on the line still completes" {
  complete --bogus --par
  assert_success
  [[ "$(items)" == *--paranoid* ]]
}

@test "an invalid --agent earlier on the line still completes" {
  complete --agent bogus --par
  assert_success
  [[ "$(items)" == *--paranoid* ]]
}

@test "a refused --paranoid --no-paranoid pair still completes" {
  complete --paranoid --no-paranoid --fil
  assert_success
  [[ "$(items)" == *--filter-egress* ]]
}

# --- protocol shape ------------------------------------------------------------

@test "the stream opens with protocol version 1 and closes every item" {
  complete --par
  assert_success
  [[ "${lines[0]}" == "1" ]]
  local opened closed
  opened="$(grep -cx item <<<"$output")"
  closed="$(grep -cx item-end <<<"$output")"
  [[ "$opened" -gt 0 && "$opened" -eq "$closed" ]]
}

@test "option names filter by prefix" {
  complete --par
  assert_success
  [[ "$(items)" == $'--paranoid\n--paranoid-deny-read\n--paranoid-allow-read' ]]
}

# --- value positions -----------------------------------------------------------

@test "--agent completes the adapter's agents, in the Values group" {
  complete --agent ''
  assert_success
  [[ "$(groups)" == "Values" ]]
  [[ "$(items)" == $'claude\nopencode' ]]
}

@test "value candidates filter by prefix" {
  complete --agent op
  assert_success
  [[ "$(items)" == "opencode" ]]
}

@test "--accent completes the color names" {
  complete --accent bright-r
  assert_success
  [[ "$(items)" == "bright-red" ]]
}

@test "-p completes profile files and [profile] blocks, never a .local overlay" {
  write_profile work "verbose=true"
  write_profile work.local "verbose=false"
  write_config config "[profile solo]" "verbose=true"
  complete -p ''
  assert_success
  [[ "$(items)" == $'solo\nwork' ]]
}

@test "-N completes the shared namespaces, spelled as the token is" {
  mkdir -p "$HOME/.csb/agents/@work" "$HOME/.csb/agents/repo-x-claude"
  complete -N w
  assert_success
  [[ "$(items)" == "work" ]]
  complete -N @
  assert_success
  [[ "$(items)" == "@work" ]]
}

@test "a list path completes files only once it is absolute or ~/" {
  complete --deny-read /tm
  assert_success
  [[ "${lines[1]}" == "files" ]]
  complete --deny-read foo
  assert_success
  [[ "${lines[1]}" == "message" ]]
  [[ "$output" != *files* ]]
}

@test "--keep completes environment variable names" {
  export CSB_COMPLETION_PROBE=1
  complete --keep CSB_COMPLETION_PR
  assert_success
  [[ "$(items)" == "CSB_COMPLETION_PROBE" ]]
}

# --- after -- --------------------------------------------------------------------

@test "a shell run restarts completion after --" {
  complete -s -- gi
  assert_success
  [[ "$output" == $'1\nrestart' ]]
}

@test "an agent run offers the agent's own flags, outside the Values group" {
  complete -- --mo
  assert_success
  [[ "$(groups)" == "claude options" ]]
  [[ "$(items)" == "--model" ]]
}

@test "the yolo flag is in the agent's row" {
  complete -- --dangerously
  assert_success
  [[ "$(items)" == "--dangerously-skip-permissions" ]]
}

@test "a non-flag agent argument completes files" {
  complete -- READ
  assert_success
  [[ "$output" == $'1\nfiles' ]]
}

@test "a shell=true profile restarts after -- (the context reads the resolved mode)" {
  write_profile sh "shell=true"
  complete -p sh -- gi
  assert_success
  [[ "$output" == $'1\nrestart' ]]
}

@test "a profile's agent picks the flag row" {
  write_config config "[profile oc]" "agent=opencode"
  complete -p oc -- --mo
  assert_success
  [[ "$(groups)" == "opencode options" ]]
}

@test "--no-shell overrides a shell=true profile after --" {
  write_profile sh "shell=true"
  complete -p sh --no-shell -- --mo
  assert_success
  [[ "$(groups)" == "claude options" ]]
}

@test "a missing profile falls back to the command line" {
  complete -p nope -s -- gi
  assert_success
  [[ "$output" == $'1\nrestart' ]]
}

# --- through bin/csb -------------------------------------------------------------

# A repo with a csb worktree for feature/x and an unrelated one for other.
repo_with_worktrees() {
  local repo; repo="$(fake_repo)"
  git -C "$repo" branch feature/x
  git -C "$repo" worktree add -q "$repo/.worktrees/feature%2Fx" feature/x
  git -C "$repo" worktree add -q -b other "$TEST_TMP/elsewhere"
  echo "$repo"
}

# bats test_tags=needs-bin-csb
@test "BRANCH completes the repository's branches" {
  local repo; repo="$(repo_with_worktrees)"
  cd "$repo"
  complete f
  assert_success
  [[ "$(values)" == "feature/x" ]]
}

# bats test_tags=needs-bin-csb
@test "-d completes only the branches of csb's own worktrees" {
  local repo; repo="$(repo_with_worktrees)"
  cd "$repo"
  complete -d ''
  assert_success
  [[ "$(values)" == "feature/x" ]]
}

# bats test_tags=needs-bin-csb
@test "completion prints nothing on stderr outside a repository" {
  write_config config "[*]" "verbose=true"
  cd "$TEST_TMP"
  complete -p ''
  assert_success
  [[ -z "$stderr" ]]
}
