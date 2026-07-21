#!/usr/bin/env bats
# Tier 1: flag/profile/env precedence. The *_cli tracking is subtle and easy to
# break -- these assert the resolved decision via --dump-config.

load helpers

# --- paranoid ----------------------------------------------------------------

@test "CLI --paranoid beats profile paranoid=false" {
  write_profile p "paranoid=false"
  dump_config -p p --paranoid
  assert_success
  assert_line "paranoid=true"
}

@test "CLI --no-paranoid beats profile paranoid=true" {
  write_profile p "paranoid=true"
  dump_config -p p --no-paranoid
  assert_success
  assert_line "paranoid=false"
}

@test "profile paranoid=true applies with no CLI override" {
  write_profile p "paranoid=true"
  dump_config -p p
  assert_line "paranoid=true"
}

# --- latest (also CSB_LATEST env default) ------------------------------------

@test "CSB_LATEST defaults latest on" {
  export CSB_LATEST=1
  dump_config --here
  assert_line "latest=true"
}

@test "--no-latest overrides the CSB_LATEST default" {
  export CSB_LATEST=1
  dump_config --here --no-latest
  assert_line "latest=false"
}

@test "-L overrides a profile latest=false" {
  write_profile p "latest=false"
  dump_config -p p -L
  assert_line "latest=true"
}

# --- verbose (same shape as latest) ------------------------------------------

@test "CSB_VERBOSE defaults verbose on" {
  export CSB_VERBOSE=1
  dump_config --here
  assert_line "verbose=true"
}

@test "--no-verbose overrides the CSB_VERBOSE default" {
  export CSB_VERBOSE=1
  dump_config --here --no-verbose
  assert_line "verbose=false"
}

# --- namespace ---------------------------------------------------------------

@test "--ns NAME beats a profile ns=" {
  write_profile p "ns=fromprofile"
  dump_config -p p --ns fromcli
  assert_line "namespace=fromcli"
}

@test "--no-ns clears a profile ns=" {
  write_profile p "ns=fromprofile"
  dump_config -p p --no-ns
  assert_line "namespace="
}

# --- .local overlay ----------------------------------------------------------

@test "a scalar in .local wins over the base profile" {
  write_profile p "paranoid=false" "ns=base"
  printf 'paranoid=true\n' > "$CSB_PROFILES/p.local"
  dump_config -p p
  assert_line "paranoid=true"
  assert_line "namespace=base"
}

@test "list keys accumulate base + .local (base first)" {
  write_profile p "deny_read=/base/one"
  printf 'deny_read=/local/two\n' > "$CSB_PROFILES/p.local"
  dump_config -p p
  assert_line "deny_read=/base/one|/local/two"
}

# --- args --------------------------------------------------------------------

@test "-- ARGS on the CLI replaces a profile args=" {
  write_profile p "args=--model sonnet"
  dump_config -p p -- --model opus
  assert_line "claude_args=--model|opus"
}

@test "profile args= is used when no -- ARGS are given" {
  write_profile p "args=--model sonnet"
  dump_config -p p
  assert_line "claude_args=--model|sonnet"
}

# --- bare -p NAME implies --here ---------------------------------------------

@test "bare -p NAME (no BRANCH) resolves to --here" {
  write_profile p "ns=x"
  dump_config -p p
  assert_line "here=true"
  assert_line "namespace=x"
}

@test "a profile here=false suppresses the implied --here" {
  write_profile p "here=false"
  dump_config -p p
  assert_line "here=false"
}

@test "--no-here suppresses the implied --here" {
  write_profile p "ns=x"
  dump_config -p p --no-here
  assert_line "here=false"
}
