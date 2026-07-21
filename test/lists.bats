#!/usr/bin/env bats
# Tier 1: the four read/write lists accumulate from CLI flags, profile vars, and
# both together (CLI first, then profile); leading ~/ expands to $HOME.

load helpers

# --- accumulation sources (deny_read as the representative) ------------------

@test "deny_read from CLI only" {
  dump_config --here --deny-read /a --deny-read /b
  assert_line "deny_read=/a|/b"
}

@test "deny_read from profile only" {
  write_profile p "deny_read=/a" "deny_read=/b"
  dump_config -p p
  assert_line "deny_read=/a|/b"
}

@test "deny_read from CLI + profile (CLI first)" {
  write_profile p "deny_read=/from/profile"
  dump_config -p p --deny-read /from/cli
  assert_line "deny_read=/from/cli|/from/profile"
}

# --- each of the four lists accumulates CLI + profile ------------------------

@test "allow_write accumulates CLI + profile" {
  write_profile p "allow_write=/from/profile"
  dump_config -p p --allow-write /from/cli
  assert_line "allow_write=/from/cli|/from/profile"
}

@test "paranoid_deny_read accumulates CLI + profile" {
  write_profile p "paranoid_deny_read=/from/profile"
  dump_config -p p --paranoid --paranoid-deny-read /from/cli
  assert_line "paranoid_deny_read=/from/cli|/from/profile"
}

@test "paranoid_allow_read accumulates CLI + profile" {
  write_profile p "paranoid_allow_read=/from/profile"
  dump_config -p p --paranoid --paranoid-allow-read /from/cli
  assert_line "paranoid_allow_read=/from/cli|/from/profile"
}

# --- normalization -----------------------------------------------------------

@test "a leading ~/ expands to \$HOME (CLI)" {
  dump_config --here --deny-read '~/notes'
  assert_line "deny_read=$HOME/notes"
}

@test "a leading ~/ expands to \$HOME (profile)" {
  write_profile p 'allow_write=~/scratch'
  dump_config -p p
  assert_line "allow_write=$HOME/scratch"
}

@test "an absolute path is passed through unchanged" {
  dump_config --here --deny-read /etc/hosts
  assert_line "deny_read=/etc/hosts"
}
