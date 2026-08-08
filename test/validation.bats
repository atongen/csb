#!/usr/bin/env bats
# Tier 1: validation / die paths. Each must exit non-zero with a specific
# message. Arg/profile validations surface through --dump-config; build-time
# validations (path quoting, overlap) surface through --dump-sandbox.

load helpers

# --- empty required values ---------------------------------------------------

@test "empty --ns dies" {
  dump_config --ns ""
  assert_failure
  assert_output --partial "requires a non-empty NAME"
}

@test "empty --seed-home dies" {
  dump_config --seed-home ""
  assert_failure
  assert_output --partial "requires a non-empty DIR"
}

@test "empty --accent dies" {
  dump_config --accent ""
  assert_failure
  assert_output --partial "requires a COLOR"
}

# --- mutually exclusive ------------------------------------------------------

@test "--ns + -E are mutually exclusive" {
  dump_config --ns foo -E
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "--here + BRANCH are mutually exclusive" {
  dump_config --here somebranch
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "profile ns= + ephemeral=true are mutually exclusive" {
  write_profile p "ns=foo" "ephemeral=true"
  dump_config -p p
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "--real-home + --ns are mutually exclusive" {
  dump_config --real-home --ns foo
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "--real-home + -E are mutually exclusive" {
  dump_config --real-home -E
  assert_failure
  assert_output --partial "mutually exclusive"
}

@test "profile real_home=true + ns= are mutually exclusive" {
  write_profile p "real_home=true" "ns=foo"
  dump_config -p p
  assert_failure
  assert_output --partial "mutually exclusive"
}

# --- --no-sandbox is shell-only ----------------------------------------------

@test "--no-sandbox without --shell dies (claude never runs unsandboxed)" {
  dump_config --here --no-sandbox
  assert_failure
  assert_output --partial "only allowed with -s/--shell"
}

@test "--no-sandbox with --shell is allowed" {
  dump_config --here -s --no-sandbox
  assert_success
  assert_line "sandbox=false"
}

# --- unknown keys / bad values -----------------------------------------------

@test "unknown CLI flag dies" {
  dump_config --bogus
  assert_failure
  assert_output --partial "unknown option"
}

@test "unknown profile key dies" {
  write_profile p "boguskey=1"
  dump_config -p p
  assert_failure
  assert_output --partial "unknown key"
}

@test "a profile bool key with a non-bool value dies" {
  write_profile p "paranoid=maybe"
  dump_config -p p
  assert_failure
  assert_output --partial "needs true or false"
}

@test "an invalid namespace name dies" {
  dump_config --ns "bad/name"
  assert_failure
  assert_output --partial "invalid namespace"
}

@test "an invalid --nix-target name dies" {
  dump_config --nix-target "bad#name"
  assert_failure
  assert_output --partial "invalid nix target"
}

@test "an invalid profile nix_target= dies" {
  write_profile p "nix_target=bad name"
  dump_config -p p
  assert_failure
  assert_output --partial "invalid nix target"
}

@test "--nix-target without a NAME dies" {
  dump_config --nix-target
  assert_failure
  assert_output --partial "--nix-target requires a NAME"
}

@test "--nix-target-claude without a NAME dies" {
  dump_config --nix-target-claude
  assert_failure
  assert_output --partial "--nix-target-claude requires a NAME"
}

@test "an invalid --accent dies" {
  dump_config --accent notacolor
  assert_failure
  assert_output --partial "invalid --accent"
}

# --- env / paths -------------------------------------------------------------

@test "CSB_TMPDIR pointing at a nonexistent dir dies" {
  export CSB_TMPDIR="$TEST_TMP/does-not-exist"
  dump_config --here
  assert_failure
  assert_output --partial "CSB_TMPDIR does not exist"
}

@test "a relative path to a list flag dies" {
  dump_config --here --deny-read rel/path
  assert_failure
  assert_output --partial "not an absolute or ~/ path"
}

# --- build-time validations (via --dump-sandbox) -----------------------------

# bats test_tags=dump-sandbox
@test "a path with a double quote is refused" {
  local repo qdir; repo="$(fake_repo)"
  # The path must exist on disk: build_deny_paths skips nonexistent paths before
  # the quote check, so the check only fires for a real path containing a quote.
  qdir="$TEST_TMP/we\"ird"
  mkdir -p "$qdir"
  dump_sandbox "$repo" --deny-read "$qdir"
  assert_failure
  assert_output --partial "double quote or backslash"
}

# bats test_tags=dump-sandbox
@test "a linked worktree's own .git file is write-denied" {
  # It sits inside the writable worktree and names the gitdir csb resolves the
  # main checkout from -- and with it the namespace HOME and the config sections
  # that grant capability. Repointing it would let the sandbox choose the policy
  # of its own next launch, the .git/hooks class of vector (PLAN-008 section 5).
  local repo wt; repo="$(fake_repo)"
  wt="$TEST_TMP/wt"
  git -C "$repo" worktree add -q -b wtbranch "$wt"
  [[ -f "$wt/.git" ]] || fail "expected a linked worktree with a .git file"
  local gitfile; gitfile="$(realpath "$wt")/.git"
  dump_sandbox "$wt"
  assert_success
  if [[ "$(uname -s)" == Darwin ]]; then
    assert_line "(deny file-write* (literal \"$gitfile\"))"
  else
    # bwrap argv, one token per line: the deny is a read-only bind over the file.
    assert_output --partial "--ro-bind"$'\n'"$gitfile"$'\n'"$gitfile"
  fi
}

# bats test_tags=dump-sandbox
@test "the main checkout's .git directory keeps its write allow" {
  # The control for the deny above: there .git is the writable common dir, and
  # a literal deny of it would break every commit.
  local repo gitdir; repo="$(fake_repo)"
  gitdir="$(realpath "$repo")/.git"
  dump_sandbox "$repo"
  assert_success
  if [[ "$(uname -s)" == Darwin ]]; then
    refute_line "(deny file-write* (literal \"$gitdir\"))"
    assert_line "(allow file-write* (subpath \"$gitdir\"))"
  else
    refute_output --partial "--ro-bind"$'\n'"$gitdir"$'\n'"$gitdir"
    assert_output --partial "--bind"$'\n'"$gitdir"$'\n'"$gitdir"
  fi
}

# bats test_tags=dump-sandbox
@test "a paranoid-allow-read overlapping a deny root is refused" {
  local repo; repo="$(fake_repo)"
  mkdir -p "$TEST_TMP/deny/sub"
  dump_sandbox "$repo" --paranoid \
    --paranoid-deny-read "$TEST_TMP/deny" --paranoid-allow-read "$TEST_TMP/deny/sub"
  assert_failure
  assert_output --partial "overlaps deny root"
}

# bats test_tags=dump-sandbox
@test "a non-overlapping paranoid-allow-read is accepted" {
  local repo; repo="$(fake_repo)"
  mkdir -p "$TEST_TMP/allow"
  dump_sandbox "$repo" --paranoid --paranoid-allow-read "$TEST_TMP/allow"
  assert_success
}

# --- the IPC broker paths may not be re-opened by any flag (PLAN-007 D9) -----

# bats test_tags=dump-sandbox
@test "an allow-write over an IPC broker path is refused" {
  # On Linux the write binds are emitted AFTER the --tmpfs that removes the
  # session bus, so without this check the flag would layer the host directory
  # back on top and reopen F4. Refused on both platforms so a shared profile
  # fails identically.
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" --allow-write "/run/user/$(id -u)"
  assert_failure
  assert_output --partial "overlaps the IPC broker path"
}

# bats test_tags=dump-sandbox
@test "an allow-socket over an IPC broker path is refused" {
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" --allow-socket /run/dbus/system_bus_socket
  assert_failure
  assert_output --partial "overlaps the IPC broker path"
}

# bats test_tags=dump-sandbox
@test "an allow-socket naming the nix daemon socket is refused by either spelling" {
  # The link and its target: on macOS /nix/var/nix/daemon-socket/socket resolves
  # OUT of the broker directory to /private/var/run/nix-daemon.socket, so
  # comparing only the resolved path would let the F3 socket back in.
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" --allow-socket /nix/var/nix/daemon-socket/socket
  assert_failure
  assert_output --partial "overlaps the IPC broker path"

  dump_sandbox "$repo" --allow-socket "$(realpath -m /nix/var/nix/daemon-socket/socket)"
  assert_failure
  assert_output --partial "overlaps the IPC broker path"
}

# bats test_tags=dump-sandbox
@test "an allow-socket naming a whole shared write root is refused" {
  # A subpath over /tmp makes HOST sockets reachable again, which is F3's shape
  # returning -- the measurement own_roots exists to encode.
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" --allow-socket /tmp
  assert_failure
  assert_output --partial "is a shared write root"
}

# bats test_tags=dump-sandbox
@test "an allow-socket under a shared write root is accepted" {
  # The positive control for the refusal above: one named socket is the point of
  # the flag, and only the whole tree is refused.
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" --allow-socket /tmp/.s.PGSQL.5432
  assert_success
}

# --- egress filtering (docs/PLAN-008-proxy.md P2) ---------------

@test "an invalid --allow-host is refused" {
  dump_config --allow-host 'bad host'
  assert_failure
  assert_output --partial "not a hostname or *.suffix pattern"
}

@test "an --allow-host with a quote is refused" {
  dump_config --allow-host 'a"b.com'
  assert_failure
  assert_output --partial "not a hostname or *.suffix pattern"
}

@test "an out-of-range --allow-port is refused" {
  dump_config --allow-port 99999
  assert_failure
  assert_output --partial "not a port from 1 to 65535"
}

@test "a non-numeric --allow-port is refused" {
  dump_config --allow-port abc
  assert_failure
  assert_output --partial "not a port from 1 to 65535"
}

@test "a bad host in the allowed-hosts file aborts the launch" {
  printf 'ok.example.com\nnot a host\n' >"$XDG_CONFIG_HOME/csb/allowed-hosts"
  dump_config
  assert_failure
  assert_output --partial "not a hostname or *.suffix pattern"
}

# bats test_tags=dump-sandbox
@test "--filter-egress pins egress to the proxy port and nothing else" {
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux --dump-sandbox emits bwrap argv, which has no network rules)"
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" --filter-egress --allow-host api.anthropic.com
  assert_success
  assert_line '(allow network-outbound (remote ip "localhost:<PROXY_PORT>"))'
  refute_line '(allow network-outbound (remote ip "*:*"))'
}

# bats test_tags=dump-sandbox
@test "without --filter-egress egress stays open" {
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux --dump-sandbox emits bwrap argv, which has no network rules)"
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo"
  assert_success
  assert_line '(allow network-outbound (remote ip "*:*"))'
  refute_line '(allow network-outbound (remote ip "localhost:<PROXY_PORT>"))'
}

# bats test_tags=dump-sandbox
@test "--allow-port emits a loopback rule only under --filter-egress" {
  [[ "$(uname -s)" == Darwin ]] || skip "macOS only (Linux --dump-sandbox emits bwrap argv, which has no network rules)"
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" --filter-egress --allow-host a.example.com --allow-port 5432
  assert_success
  assert_line '(allow network-outbound (remote ip "localhost:5432"))'
  dump_sandbox "$repo" --allow-port 5432
  assert_success
  refute_line '(allow network-outbound (remote ip "localhost:5432"))'
}

# bats test_tags=dump-sandbox
@test "--filter-egress on Linux warns and filters nothing" {
  [[ "$(uname -s)" == Linux ]] || skip "Linux only (macOS enforces via the seatbelt profile)"
  local repo; repo="$(fake_repo)"
  dump_sandbox "$repo" --filter-egress --allow-host api.anthropic.com
  assert_success
  assert_output --partial "--filter-egress is macOS-only for now"
  refute_output --partial "network-outbound"
}
