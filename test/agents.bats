#!/usr/bin/env bats
# The agent axis (docs/PLAN-010-agents.md pass 1): the per-repo-per-agent launch
# HOMEs, the two migrations off the pre-agent layout, and the per-agent egress
# allowlist file.
#
# The namespace arms drive --dump-sandbox rather than --dump-config: setup_namespace
# is on the launch path, and the dump seam is the only way to reach it without
# launching.

load helpers

NS_ROOT_REL=".csb/agents"
LEGACY_ROOT_REL=".csb/claudes"

# Echo the per-repo namespace dir csb created under the agents root, so a test
# never re-derives repo_key.
repo_ns_dir() {
  local d
  for d in "$HOME/$NS_ROOT_REL"/repo-*; do
    [[ -d "$d" ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# --- the default HOME is per repo AND agent ----------------------------------

# bats test_tags=dump-sandbox
@test "the default launch HOME is suffixed with the agent" {
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo"
  assert_success
  local ns; ns="$(repo_ns_dir)"
  [[ "$(basename "$ns")" == repo-*-claude ]]
}

# bats test_tags=dump-sandbox
@test "the namespace stamp records the agent" {
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo"
  assert_success
  run cat "$(repo_ns_dir)/.csb-ns"
  assert_line "kind=repo"
  assert_line "agent=claude"
}

# bats test_tags=dump-sandbox
@test "a shared namespace is NOT agent-suffixed" {
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" -N work
  assert_success
  [ -d "$HOME/$NS_ROOT_REL/@work" ]
  [ ! -d "$HOME/$NS_ROOT_REL/@work-claude" ]
}

# --- migration off the pre-agent layout --------------------------------------

# bats test_tags=dump-sandbox
@test "the pre-agent root is moved to ~/.csb/agents, entries intact" {
  local repo; repo="$(fake_repo)"
  mkdir -p "$HOME/$LEGACY_ROOT_REL/@shared"
  printf 'kind=shared\n' > "$HOME/$LEGACY_ROOT_REL/@shared/.csb-ns"
  echo keep-me > "$HOME/$LEGACY_ROOT_REL/@shared/marker"

  dump_sandbox "$repo"
  assert_success
  [ ! -e "$HOME/$LEGACY_ROOT_REL" ]
  run cat "$HOME/$NS_ROOT_REL/@shared/marker"
  assert_output "keep-me"
}

# bats test_tags=dump-sandbox
@test "the pre-agent root is left alone once the new one exists" {
  local repo; repo="$(fake_repo)"
  mkdir -p "$HOME/$NS_ROOT_REL" "$HOME/$LEGACY_ROOT_REL/@stale"
  dump_sandbox "$repo"
  assert_success
  [ -d "$HOME/$LEGACY_ROOT_REL/@stale" ]
}

# bats test_tags=dump-sandbox
@test "a pre-agent per-repo HOME is adopted, byte-identical" {
  local repo; repo="$(fake_repo)"
  # One launch to learn this repo's key, then put the HOME back in the
  # pre-agent shape so the next launch has to adopt it.
  dump_sandbox "$repo"
  assert_success
  local ns pre; ns="$(repo_ns_dir)"; pre="${ns%-claude}"
  echo keep-me > "$ns/marker"
  mv "$ns" "$pre"
  printf 'kind=repo\n' > "$pre/.csb-ns"

  dump_sandbox "$repo"
  assert_success
  [ ! -e "$pre" ]
  run cat "$ns/marker"
  assert_output "keep-me"
}

# bats test_tags=dump-sandbox
@test "an unstamped pre-agent dir is not adopted" {
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo"
  assert_success
  local ns pre; ns="$(repo_ns_dir)"; pre="${ns%-claude}"
  rm -rf "$ns"
  mkdir -p "$pre"          # no .csb-ns: indistinguishable from a dir mid-creation

  dump_sandbox "$repo"
  assert_success
  [ -d "$pre" ]
  [ -d "$ns" ]
}

# bats test_tags=dump-sandbox
@test "--list-ns flags the pre-agent per-repo dir for this repo" {
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo"
  assert_success
  local ns pre; ns="$(repo_ns_dir)"; pre="${ns%-claude}"
  mv "$ns" "$pre"
  printf 'kind=repo\n' > "$pre/.csb-ns"

  run bash -c 'cd "$1" || exit 1; shift; exec "$@"' _ "$repo" "$CSB" --list-ns
  assert_success
  assert_output --partial "PRE-AGENT layout"
}

# --- the deny floor covers every agent's HOST state --------------------------

# bats test_tags=dump-sandbox
@test "another agent's host state dir is read-denied" {
  local repo; repo="$(fake_repo)"
  mkdir -p "$HOME/.codex" "$HOME/.local/share/opencode"
  dump_sandbox_snapshot "$repo"
  assert_success
  local rhome; rhome="$(realpath "$HOME")"
  assert_output --partial "$rhome/.codex"
  assert_output --partial "$rhome/.local/share/opencode"
}

# --- the egress allowlist file is keyed by agent -----------------------------

@test "allowed-hosts.claude is preferred over the unsuffixed file" {
  write_config allowed-hosts "shared.example.com"
  write_config allowed-hosts.claude "per-agent.example.com"
  dump_config --here
  assert_success
  assert_line "allow_host=per-agent.example.com"
}

@test "the unsuffixed allowed-hosts applies when the agent has no file" {
  write_config allowed-hosts "shared.example.com"
  dump_config --here
  assert_success
  assert_line "allow_host=shared.example.com"
}
