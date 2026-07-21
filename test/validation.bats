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

@test "a paranoid-allow-read overlapping a deny root is refused" {
  local repo; repo="$(fake_repo)"
  mkdir -p "$TEST_TMP/deny/sub"
  dump_sandbox "$repo" --paranoid \
    --paranoid-deny-read "$TEST_TMP/deny" --paranoid-allow-read "$TEST_TMP/deny/sub"
  assert_failure
  assert_output --partial "overlaps deny root"
}

@test "a non-overlapping paranoid-allow-read is accepted" {
  local repo; repo="$(fake_repo)"
  mkdir -p "$TEST_TMP/allow"
  dump_sandbox "$repo" --paranoid --paranoid-allow-read "$TEST_TMP/allow"
  assert_success
}
